# Generates Data\Benchmarks.lua from Warcraft Logs V1 rankings.
# Usage: powershell -File scripts\fetch-benchmarks.ps1 [-RaidEncounter 3176] [-Pages 2]
# Reads the API key from scripts\wcl-key.local.txt (gitignored).
param(
    [int]$RaidEncounter = 3176, # Imperator Averzian (current tier, most parses)
    [int]$Pages = 2,
    [string]$KeyFile = "$PSScriptRoot\wcl-key.local.txt"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $KeyFile)) {
    Write-Error "Missing $KeyFile - put your WCL V1 API key in it."
    exit 1
}
$key = (Get-Content $KeyFile -TotalCount 1).Trim()
$base = "https://www.warcraftlogs.com/v1"

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
    "Rogue:Assassination" = 259; "Rogue:Outlaw" = 260; "Rogue:Subtlety" = 261
    "Shaman:Elemental" = 262; "Shaman:Enhancement" = 263; "Shaman:Restoration" = 264
    "Warlock:Affliction" = 265; "Warlock:Demonology" = 266; "Warlock:Destruction" = 267
    "Warrior:Arms" = 71; "Warrior:Fury" = 72; "Warrior:Protection" = 73
}
$healerSpecs = @("Druid:Restoration", "Evoker:Preservation", "Monk:Mistweaver",
    "Paladin:Holy", "Priest:Discipline", "Priest:Holy", "Shaman:Restoration")
# WCL aug "dps" includes support-attributed damage invisible to C_DamageMeter;
# the addon scores aug via its SUPPORT role instead, so skip its factor.
$skipDamage = @("Evoker:Augmentation")

$classes = Invoke-RestMethod -Uri "$base/classes?api_key=$key" -TimeoutSec 30

function Get-Median($values) {
    $sorted = $values | Sort-Object
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return $sorted[[math]::Floor($n / 2)] }
    return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2
}

$damageMedians = @{}
$healingMedians = @{}
$ilvlPairs = New-Object System.Collections.ArrayList

foreach ($class in $classes) {
    foreach ($spec in $class.specs) {
        $specKey = "$($class.name):$($spec.name)"
        if (-not $specIDs.ContainsKey($specKey)) { continue }

        $metrics = @("dps")
        if ($healerSpecs -contains $specKey) { $metrics = @("hps") }

        foreach ($metric in $metrics) {
            if ($metric -eq "dps" -and $skipDamage -contains $specKey) { continue }
            $totals = New-Object System.Collections.ArrayList
            for ($page = 1; $page -le $Pages; $page++) {
                $uri = "$base/rankings/encounter/$RaidEncounter" +
                    "?metric=$metric&class=$($class.id)&spec=$($spec.id)&page=$page&api_key=$key"
                try {
                    $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 30
                } catch {
                    Write-Warning "FAILED $specKey $metric page $page : $_"
                    break
                }
                foreach ($r in $resp.rankings) {
                    [void]$totals.Add([double]$r.total)
                    if ($r.itemLevel -gt 0 -and $r.total -gt 0) {
                        [void]$ilvlPairs.Add(@([double]$r.itemLevel, [math]::Log([double]$r.total)))
                    }
                }
                if (-not $resp.hasMorePages) { break }
                Start-Sleep -Milliseconds 250
            }
            $median = Get-Median $totals
            if ($null -ne $median) {
                if ($metric -eq "dps") { $damageMedians[$specKey] = $median }
                else { $healingMedians[$specKey] = $median }
                Write-Host ("{0,-28} {1}: median {2:n0} (n={3})" -f $specKey, $metric, $median, $totals.Count)
            }
        }
    }
}

# Log-linear fit: percent output change per item level
$slopePct = 0
if ($ilvlPairs.Count -gt 100) {
    $mx = ($ilvlPairs | ForEach-Object { $_[0] } | Measure-Object -Average).Average
    $my = ($ilvlPairs | ForEach-Object { $_[1] } | Measure-Object -Average).Average
    $cov = 0.0; $var = 0.0
    foreach ($p in $ilvlPairs) {
        $cov += ($p[0] - $mx) * ($p[1] - $my)
        $var += ($p[0] - $mx) * ($p[0] - $mx)
    }
    if ($var -gt 0) { $slopePct = [math]::Round(([math]::Exp($cov / $var) - 1) * 100, 3) }
}
Write-Host ("ilvl slope: {0}% output per item level (n={1})" -f $slopePct, $ilvlPairs.Count)

# Normalize medians to factors around the overall median
function Get-Factors($medians) {
    $overall = Get-Median @($medians.Values)
    $factors = @{}
    foreach ($k in $medians.Keys) {
        $factors[$specIDs[$k]] = [math]::Round($medians[$k] / $overall, 3)
    }
    return $factors
}
$damageFactors = Get-Factors $damageMedians
$healingFactors = Get-Factors $healingMedians

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("-- GENERATED by scripts\fetch-benchmarks.ps1 - do not edit by hand.")
[void]$lines.Add("-- Source: Warcraft Logs V1 rankings, encounter $RaidEncounter, $Pages page(s)/spec.")
[void]$lines.Add("-- Factors are spec median output / overall median (1.0 = average spec).")
[void]$lines.Add("-- Keys are global specialization IDs (stable across locales).")
[void]$lines.Add("local _, TP = ...")
[void]$lines.Add("")
[void]$lines.Add("TP.Benchmarks = {")
[void]$lines.Add(("	generated = `"{0}`"," -f (Get-Date -Format "yyyy-MM-dd")))
[void]$lines.Add(("	encounter = {0}," -f $RaidEncounter))
[void]$lines.Add(("	ilvlSlopePct = {0}, -- %% output per item level (log-linear fit)" -f $slopePct))
[void]$lines.Add("	damageFactor = {")
foreach ($k in ($damageFactors.Keys | Sort-Object)) {
    [void]$lines.Add(("		[{0}] = {1}," -f $k, $damageFactors[$k]))
}
[void]$lines.Add("	},")
[void]$lines.Add("	healingFactor = {")
foreach ($k in ($healingFactors.Keys | Sort-Object)) {
    [void]$lines.Add(("		[{0}] = {1}," -f $k, $healingFactors[$k]))
}
[void]$lines.Add("	},")
[void]$lines.Add("}")

$outPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Data\Benchmarks.lua"
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath"
