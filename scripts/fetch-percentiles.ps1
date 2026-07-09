# Generates Data\Percentiles*.lua from Warcraft Logs V1 rankings.
# For each raid encounter x spec, finds the size of the ranked population
# (exponential + binary probe on hasMorePages), then samples the ranking
# pages at fixed quantiles (p99..p10). The addon's Raw mode interpolates a
# player's per-second output into these curves, producing a real WCL-style
# PERCENTILE instead of a linear %-of-median (which reads far too generous
# in the middle of the pack — logged populations bunch high).
# Slow by design: ~1s between requests to respect the 3600/hr limit.
# MoP Classic: powershell -File scripts\fetch-percentiles.ps1 `
#                -GameBase https://classic.warcraftlogs.com `
#                -ZoneId 1054 -OutFile Percentiles_Mists.lua
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int]$ZoneId = 46,
    [int]$MinParses = 300,   # thinner populations give junk curves; skip them
    [int]$ThrottleMs = 1050,
    [int]$MaxProbePages = 512,
    [string]$OutFile = "Percentiles.lua",
    [string]$KeyFile = "$PSScriptRoot\wcl-key.local.txt"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $KeyFile)) {
    Write-Error "Missing $KeyFile - put your WCL V1 API key in it."
    exit 1
}
$key = (Get-Content $KeyFile -TotalCount 1).Trim()
$base = "$GameBase/v1"

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
$skipDamage = @("Evoker:Augmentation")
$quantiles = @(99, 95, 90, 75, 50, 25, 10)

$script:requestCount = 0
function Invoke-WCL($uri) {
    Start-Sleep -Milliseconds $script:ThrottleMs
    $script:requestCount++
    try {
        return Invoke-RestMethod -Uri $uri -TimeoutSec 30
    } catch {
        if ("$_" -match "429") {
            Write-Warning "Rate limited; sleeping 120s..."
            Start-Sleep -Seconds 120
            return Invoke-RestMethod -Uri $uri -TimeoutSec 30
        }
        throw
    }
}

$zones = Invoke-WCL "$base/zones?api_key=$key"
$classes = Invoke-WCL "$base/classes?api_key=$key"
$zoneObj = $zones | Where-Object { $_.id -eq $ZoneId }
if (-not $zoneObj) {
    Write-Error "Zone $ZoneId not found"
    exit 1
}
Write-Host ("Zone: {0} ({1} encounters)" -f $zoneObj.name, $zoneObj.encounters.Count)

# Returns @{ n = populationSize; curve = @( @(pct, value), ... ) } or $null
function Fetch-Curve($encounterId, $classId, $specId) {
    $cache = @{}
    function Get-Page($page) {
        if ($cache.ContainsKey($page)) { return $cache[$page] }
        $uri = "$script:base/rankings/encounter/$encounterId" +
            "?metric=$script:metric&class=$classId&spec=$specId&page=$page&api_key=$script:key"
        $resp = Invoke-WCL $uri
        $cache[$page] = $resp
        return $resp
    }

    $p1 = Get-Page 1
    if (-not $p1.rankings -or $p1.rankings.Count -eq 0) { return $null }

    # Find the last non-empty page: exponential probe, then binary search
    $lastPage = 1
    if ($p1.hasMorePages) {
        $lo = 1; $hi = 2
        while ($hi -le $script:MaxProbePages) {
            $r = Get-Page $hi
            if ($r.rankings.Count -gt 0 -and $r.hasMorePages) { $lo = $hi; $hi = $hi * 2 }
            else { break }
        }
        if ($hi -gt $script:MaxProbePages) { $hi = $script:MaxProbePages }
        # invariant: lo is non-empty-with-more; hi may be end or beyond
        while ($lo + 1 -lt $hi) {
            $mid = [math]::Floor(($lo + $hi) / 2)
            $r = Get-Page $mid
            if ($r.rankings.Count -gt 0 -and $r.hasMorePages) { $lo = $mid } else { $hi = $mid }
        }
        $rHi = Get-Page $hi
        if ($rHi.rankings.Count -gt 0) { $lastPage = $hi } else { $lastPage = $lo }
    }
    $lastCount = (Get-Page $lastPage).rankings.Count
    $n = ($lastPage - 1) * 100 + $lastCount
    if ($n -lt $script:MinParses) { return $null }

    $curve = New-Object System.Collections.ArrayList
    foreach ($pct in $script:quantiles) {
        $rank = [math]::Max(1, [math]::Ceiling((100 - $pct) / 100 * $n))
        if ($rank -gt $n) { $rank = $n }
        $page = [math]::Floor(($rank - 1) / 100) + 1
        $idx = ($rank - 1) % 100
        $r = Get-Page $page
        if ($r.rankings.Count -gt $idx) {
            [void]$curve.Add(@($pct, [math]::Round([double]$r.rankings[$idx].total, 0)))
        }
    }
    if ($curve.Count -lt 4) { return $null }
    return @{ n = $n; curve = $curve }
}

$encounters = @{} # [name] = @{ dps = @{specID=entry}; hps = @{specID=entry} }
foreach ($enc in $zoneObj.encounters) {
    Write-Host ("=== {0} ({1})" -f $enc.name, $enc.id)
    $dps = @{}; $hps = @{}
    foreach ($class in $classes) {
        foreach ($spec in $class.specs) {
            $specKey = "$($class.name):$($spec.name)"
            if (-not $specIDs.ContainsKey($specKey)) { continue }
            $script:metric = "dps"
            if ($healerSpecs -contains $specKey) { $script:metric = "hps" }
            elseif ($skipDamage -contains $specKey) { continue }
            try {
                $entry = Fetch-Curve $enc.id $class.id $spec.id
            } catch {
                Write-Warning "FAILED $($enc.name) $specKey : $_"
                $entry = $null
            }
            if ($null -ne $entry) {
                if ($script:metric -eq "dps") { $dps[$specIDs[$specKey]] = $entry }
                else { $hps[$specIDs[$specKey]] = $entry }
                Write-Host ("    {0}: n={1} p50={2}" -f $specKey, $entry.n, $entry.curve[4][1])
            }
        }
    }
    $encounters[$enc.name] = @{ dps = $dps; hps = $hps }
}

Write-Host ("Total requests: {0}" -f $script:requestCount)

# ---- emit Lua ----
$lines = New-Object System.Collections.ArrayList
function Emit($s) { [void]$script:lines.Add($s) }
function Emit-CurveTable($indent, $name, $tbl) {
    Emit ("$indent$name = {")
    foreach ($specID in ($tbl.Keys | Sort-Object)) {
        $entry = $tbl[$specID]
        $points = ($entry.curve | ForEach-Object { "{ $($_[0]), $($_[1]) }" }) -join ", "
        Emit ("$indent`t[{0}] = {{ n = {1}, curve = {{ {2} }} }}," -f $specID, $entry.n, $points)
    }
    Emit ("$indent},")
}

Emit "-- GENERATED by scripts\fetch-percentiles.ps1 - do not edit by hand."
Emit "-- Per-encounter, per-spec percentile curves sampled from the full WCL"
Emit "-- ranked population (metric value at p99..p10). Raw mode interpolates a"
Emit "-- player's per-second output into these to produce a true WCL-style"
Emit "-- percentile. Same staleness rules as Benchmarks: regenerate per patch."
Emit "local _, TP = ..."
Emit ""
Emit "TP.Percentiles = {"
Emit ("`tgenerated = `"{0}`"," -f (Get-Date -Format "yyyy-MM-dd"))
Emit ("`tzone = `"{0}`"," -f $zoneObj.name)
Emit "`tencounters = {"
foreach ($name in ($encounters.Keys | Sort-Object)) {
    $set = $encounters[$name]
    if ($set.dps.Count -eq 0 -and $set.hps.Count -eq 0) { continue }
    Emit ("`t`t[`"{0}`"] = {{" -f ($name -replace '"', '\"'))
    Emit-CurveTable "`t`t`t" "dps" $set.dps
    Emit-CurveTable "`t`t`t" "hps" $set.hps
    Emit "`t`t},"
}
Emit "`t},"
Emit "}"

$outPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutFile"
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath"
