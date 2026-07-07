# Generates Data\Benchmarks.lua from Warcraft Logs V1 rankings.
# Per-encounter spec medians for every current raid boss and M+ dungeon, so
# grading can use fight-specific expectations ("handicap curves") — a spec
# that underperforms on a movement fight is measured against what that spec
# actually does on that fight. Global factors remain as the fallback.
# Usage: powershell -File scripts\fetch-benchmarks.ps1 [-RaidZone 46] [-DungeonZone 47] [-Pages 1]
# Reads the API key from scripts\wcl-key.local.txt (gitignored).
# Retail (defaults):  powershell -File scripts\fetch-benchmarks.ps1
# MoP Classic:        powershell -File scripts\fetch-benchmarks.ps1 `
#                       -GameBase https://classic.warcraftlogs.com `
#                       -RaidZoneIds 1054 -DungeonZone 1039 -OutFile Benchmarks_Mists.lua
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int[]]$RaidZoneIds = @(46),
    [int]$DungeonZone = 47,
    [int]$Pages = 1,
    [int]$MinSamples = 20, # lower for Classic where per-spec parses are sparse
    [string]$OutFile = "Benchmarks.lua",
    [string]$KeyFile = "$PSScriptRoot\wcl-key.local.txt"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $KeyFile)) {
    Write-Error "Missing $KeyFile - put your WCL V1 API key in it."
    exit 1
}
$key = (Get-Content $KeyFile -TotalCount 1).Trim()
$base = "$GameBase/v1"

# WCL class/spec name -> stable in-game global spec ID (locale-proof key)
$specIDs = @{
    "Death Knight:Blood" = 250; "Death Knight:Frost" = 251; "Death Knight:Unholy" = 252
    "Demon Hunter:Havoc" = 577; "Demon Hunter:Vengeance" = 581
    "Druid:Balance" = 102; "Druid:Feral" = 103; "Druid:Guardian" = 104; "Druid:Restoration" = 105
    "Evoker:Devastation" = 1467; "Evoker:Preservation" = 1468; "Evoker:Augmentation" = 1473
    "Hunter:Beast Mastery" = 253; "Hunter:Marksmanship" = 254; "Hunter:Survival" = 255
    "Mage:Arcane" = 62; "Mage:Fire" = 63; "Mage:Frost" = 64
    "Monk:Brewmaster" = 268; "Monk:Mistweaver" = 270; "Monk:Windwalker" = 269
    "Paladin:Holy" = 65; "Paladin:Protection" = 66; "Paladin:Retribution" = 70
    "Priest:Discipline" = 256; "Priest:Holy" = 257; "Priest:Shadow" = 258
    "Rogue:Assassination" = 259; "Rogue:Outlaw" = 260; "Rogue:Combat" = 260; "Rogue:Subtlety" = 261
    "Shaman:Elemental" = 262; "Shaman:Enhancement" = 263; "Shaman:Restoration" = 264
    "Warlock:Affliction" = 265; "Warlock:Demonology" = 266; "Warlock:Destruction" = 267
    "Warrior:Arms" = 71; "Warrior:Fury" = 72; "Warrior:Protection" = 73
}
$healerSpecs = @("Druid:Restoration", "Evoker:Preservation", "Monk:Mistweaver",
    "Paladin:Holy", "Priest:Discipline", "Priest:Holy", "Shaman:Restoration")
# WCL aug "dps" includes support-attributed damage invisible to C_DamageMeter;
# the addon scores aug via its SUPPORT role instead, so skip its factor.
$skipDamage = @("Evoker:Augmentation")

$zones = Invoke-RestMethod -Uri "$base/zones?api_key=$key" -TimeoutSec 30
$classes = Invoke-RestMethod -Uri "$base/classes?api_key=$key" -TimeoutSec 30

function Get-Median($values) {
    $sorted = $values | Sort-Object
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return $sorted[[math]::Floor($n / 2)] }
    return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2
}

# ilvl/log(dps) pairs kept per encounter: pooling across encounters
# confounds gear with encounter difficulty and inflates the slope.
$ilvlPairsByEncounter = @{}

# Returns @{ damage = @{specKey=median}; healing = @{specKey=median} }
function Fetch-EncounterMedians($encounterId, $collectIlvl) {
    $damage = @{}; $healing = @{}
    foreach ($class in $script:classes) {
        foreach ($spec in $class.specs) {
            $specKey = "$($class.name):$($spec.name)"
            if (-not $script:specIDs.ContainsKey($specKey)) { continue }
            $metric = "dps"
            if ($script:healerSpecs -contains $specKey) { $metric = "hps" }
            elseif ($script:skipDamage -contains $specKey) { continue }

            $totals = New-Object System.Collections.ArrayList
            for ($page = 1; $page -le $script:Pages; $page++) {
                $uri = "$script:base/rankings/encounter/$encounterId" +
                    "?metric=$metric&class=$($class.id)&spec=$($spec.id)&page=$page&api_key=$script:key"
                try {
                    $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 30
                } catch {
                    Write-Warning "FAILED enc $encounterId $specKey : $_"
                    break
                }
                foreach ($r in $resp.rankings) {
                    [void]$totals.Add([double]$r.total)
                    if ($collectIlvl -and $r.itemLevel -gt 0 -and $r.total -gt 0) {
                        if (-not $script:ilvlPairsByEncounter.ContainsKey($encounterId)) {
                            $script:ilvlPairsByEncounter[$encounterId] = New-Object System.Collections.ArrayList
                        }
                        [void]$script:ilvlPairsByEncounter[$encounterId].Add(@([double]$r.itemLevel, [math]::Log([double]$r.total)))
                    }
                }
                if (-not $resp.hasMorePages) { break }
                Start-Sleep -Milliseconds 100
            }
            $median = Get-Median $totals
            if ($null -ne $median -and $totals.Count -ge $script:MinSamples) {
                if ($metric -eq "dps") { $damage[$specKey] = $median }
                else { $healing[$specKey] = $median }
            }
            Start-Sleep -Milliseconds 100
        }
    }
    return @{ damage = $damage; healing = $healing }
}

# Median-normalized factors for one encounter's medians
function Get-Factors($medians) {
    if ($medians.Count -eq 0) { return @{} }
    $overall = Get-Median @($medians.Values)
    $factors = @{}
    foreach ($k in $medians.Keys) {
        $factors[$script:specIDs[$k]] = [math]::Round($medians[$k] / $overall, 3)
    }
    return $factors
}

$encounterFactors = @{}  # [encounterName] = @{ damage=@{}; healing=@{} }
$dungeonFactors = @{}

foreach ($raidZoneId in $RaidZoneIds) {
    $raidZoneObj = $zones | Where-Object { $_.id -eq $raidZoneId }
    if (-not $raidZoneObj) {
        Write-Warning "Raid zone $raidZoneId not found"
        continue
    }
    foreach ($enc in $raidZoneObj.encounters) {
        Write-Host ("=== raid encounter {0}: {1}" -f $enc.id, $enc.name)
        $medians = Fetch-EncounterMedians $enc.id $true
        $encounterFactors[$enc.name] = @{
            damage = Get-Factors $medians.damage
            healing = Get-Factors $medians.healing
        }
        Write-Host ("    specs: {0} dps, {1} hps" -f $medians.damage.Count, $medians.healing.Count)
    }
}

$dungeonZoneObj = $zones | Where-Object { $_.id -eq $DungeonZone }
foreach ($enc in $dungeonZoneObj.encounters) {
    Write-Host ("=== dungeon {0}: {1}" -f $enc.id, $enc.name)
    $medians = Fetch-EncounterMedians $enc.id $false
    $dungeonFactors[$enc.name] = @{
        damage = Get-Factors $medians.damage
        healing = Get-Factors $medians.healing
    }
    Write-Host ("    specs: {0} dps, {1} hps" -f $medians.damage.Count, $medians.healing.Count)
}

# Global fallback factors: mean of each spec's per-encounter factor
function Get-GlobalFactors($allFactorSets, $kind) {
    $sums = @{}; $counts = @{}
    foreach ($set in $allFactorSets.Values) {
        foreach ($specID in $set[$kind].Keys) {
            $sums[$specID] = ($sums[$specID] + $set[$kind][$specID])
            $counts[$specID] = ($counts[$specID] + 1)
        }
    }
    $global = @{}
    foreach ($specID in $sums.Keys) {
        $global[$specID] = [math]::Round($sums[$specID] / $counts[$specID], 3)
    }
    return $global
}
$allSets = @{}
foreach ($k in $encounterFactors.Keys) { $allSets["r:$k"] = $encounterFactors[$k] }
foreach ($k in $dungeonFactors.Keys) { $allSets["d:$k"] = $dungeonFactors[$k] }
$globalDamage = Get-GlobalFactors $allSets "damage"
$globalHealing = Get-GlobalFactors $allSets "healing"

# Log-linear fit PER ENCOUNTER, then the MEDIAN slope: late-tier bosses
# carry heavy gear/skill selection bias, so the median resists them.
$encSlopes = New-Object System.Collections.ArrayList
$pairTotal = 0
foreach ($encId in $ilvlPairsByEncounter.Keys) {
    $pairs = $ilvlPairsByEncounter[$encId]
    if ($pairs.Count -lt 100) { continue }
    $mx = ($pairs | ForEach-Object { $_[0] } | Measure-Object -Average).Average
    $my = ($pairs | ForEach-Object { $_[1] } | Measure-Object -Average).Average
    $cov = 0.0; $var = 0.0
    foreach ($p in $pairs) {
        $cov += ($p[0] - $mx) * ($p[1] - $my)
        $var += ($p[0] - $mx) * ($p[0] - $mx)
    }
    if ($var -gt 0) {
        $encSlope = [math]::Exp($cov / $var) - 1
        [void]$encSlopes.Add($encSlope)
        $pairTotal += $pairs.Count
        Write-Host ("    enc {0}: slope {1:n3}% (n={2})" -f $encId, ($encSlope * 100), $pairs.Count)
    }
}
$slopePct = 0
$medianSlope = Get-Median $encSlopes
if ($null -ne $medianSlope) { $slopePct = [math]::Round($medianSlope * 100, 3) }
Write-Host ("ilvl slope: {0}% per item level (median of per-encounter fits, n={1})" -f $slopePct, $pairTotal)

# ---- emit Lua ----
$lines = New-Object System.Collections.ArrayList
function Emit($s) { [void]$script:lines.Add($s) }
function Emit-FactorTable($indent, $name, $factors) {
    Emit ("$indent$name = {")
    foreach ($k in ($factors.Keys | Sort-Object)) {
        Emit ("$indent`t[{0}] = {1}," -f $k, $factors[$k])
    }
    Emit ("$indent},")
}
function Emit-EncounterSet($name, $set) {
    $safe = $set -eq $null
    Emit ("`t`t[`"{0}`"] = {{" -f ($name -replace '"', '\"'))
    Emit-FactorTable "`t`t`t" "damageFactor" $set.damage
    Emit-FactorTable "`t`t`t" "healingFactor" $set.healing
    Emit "`t`t},"
}

Emit "-- GENERATED by scripts\fetch-benchmarks.ps1 - do not edit by hand."
Emit "-- Per-encounter/per-dungeon spec medians from Warcraft Logs V1 rankings,"
Emit "-- so grading uses fight-specific expectations. Keys: global spec IDs;"
Emit "-- encounter/dungeon tables keyed by their in-game names."
Emit "-- STALENESS: these are point-in-time statistics. Regenerate after every"
Emit "-- balance patch and at each new season/raid tier; the addon nags in-game"
Emit "-- once the data is 60+ days old."
Emit "local _, TP = ..."
Emit ""
Emit "TP.Benchmarks = {"
Emit ("`tgenerated = `"{0}`"," -f (Get-Date -Format "yyyy-MM-dd"))
Emit ("`tilvlSlopePct = {0}," -f $slopePct)
Emit-FactorTable "`t" "damageFactor" $globalDamage
Emit-FactorTable "`t" "healingFactor" $globalHealing
Emit "`tencounters = {"
foreach ($name in ($encounterFactors.Keys | Sort-Object)) {
    Emit-EncounterSet $name $encounterFactors[$name]
}
Emit "`t},"
Emit "`tdungeons = {"
foreach ($name in ($dungeonFactors.Keys | Sort-Object)) {
    Emit-EncounterSet $name $dungeonFactors[$name]
}
Emit "`t},"
Emit "}"

$outPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutFile"
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath"
