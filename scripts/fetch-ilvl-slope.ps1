# Measures how much a player's OUTPUT actually rises with item level, which is
# the number every gear-normalised score depends on. Emits Data/IlvlSlope.lua.
#
# Why this exists (Josh 2026-08-01). Scores in Mythic+ correlate +0.46 with
# item level and 21% of their variance is gear alone: across his 195-270
# spread that is ~32 points of score before anyone plays a keystroke, so an
# undergeared player cannot escape grey and an overgeared one cannot fall out
# of gold. Normalising fixes that ONLY if the slope is right - the shipped
# retail 1.489%/ilvl looked ~1.7x too steep against a thin local estimate, and
# MoP's 2.244 measured 1.254. Over-correcting swaps one bias for its mirror,
# which is worse because the complaints stop.
#
# METHOD, and the part that matters: regress log(rate) on item level WITHIN
# each (spec, keystone band). Higher keys carry both better gear AND higher
# output, so pooling bands measures the key level and calls it gear. Slopes are
# then pooled across groups weighted by sample count.
#
# M+ rankings do NOT expose itemLevel (probe-verified 2026-08-01: the fields
# are name/class/spec/amount/hardModeLevel/duration/report/bracketData/...).
# The TABLE api does carry it per player, so rankings are used only to discover
# reports and every measurement comes from DamageDone tables.
#
# NEVER run while another WCL crawl is active (single-active tokens).
#   Retail M+: -GameBase https://www.warcraftlogs.com -ZoneId 47
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int]$ZoneId = 47,
    [string]$Bands = "2,5,8,11,14",   # keystone bands to sample separately
    [int]$MaxReports = 160,
    [int]$MinGroup = 6,               # (spec,band) groups thinner than this are noise
    [string]$OutFile = "IlvlSlope.lua",
    [string]$ClientFile = "$PSScriptRoot\wcl-v2-client.local.txt"
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ClientFile)) { Write-Error "Missing $ClientFile (line 1 = client id, line 2 = secret)." }
$creds = Get-Content $ClientFile
$clientId = $creds[0].Trim(); $clientSecret = $creds[1].Trim()
function Get-Token {
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$clientId`:$clientSecret"))
    (Invoke-RestMethod -Method Post -Uri "$GameBase/oauth/token" -Headers @{ Authorization = "Basic $pair" } -Body @{ grant_type = "client_credentials" }).access_token
}
$script:token = Get-Token
Write-Host "OAuth OK; endpoint $GameBase/api/v2/client"

function Invoke-GQL($query) {
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $body = @{ query = $query } | ConvertTo-Json -Compress
            $resp = Invoke-RestMethod -Method Post -Uri "$GameBase/api/v2/client" `
                -Headers @{ Authorization = "Bearer $script:token"; "Content-Type" = "application/json" } `
                -Body $body -TimeoutSec 180
            if ($resp.errors) { throw ("GraphQL: " + ($resp.errors | ConvertTo-Json -Compress)) }
            Start-Sleep -Milliseconds 350
            return $resp.data
        } catch {
            if ($attempt -eq 6) { throw }
            $wait = @(5, 15, 60, 180, 600)[$attempt - 1]
            if ($_.Exception.Message -match "429|point") { $wait = 900 }
            Write-Warning "retry $attempt in ${wait}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $wait
            if ($attempt -ge 2) { $script:token = Get-Token }
        }
    }
}
function Assert-Points {
    $d = Invoke-GQL "{ rateLimitData { pointsSpentThisHour pointsResetIn } }"
    if ([double]$d.rateLimitData.pointsSpentThisHour -gt 3300) {
        $nap = [int]$d.rateLimitData.pointsResetIn + 30
        Write-Warning "Near point limit; sleeping ${nap}s"; Start-Sleep -Seconds $nap; $script:token = Get-Token
    }
}

$bandList = @($Bands -split "," | ForEach-Object { [int]$_.Trim() })
$zone = (Invoke-GQL "{ worldData { zone(id: $ZoneId) { name encounters { id name } } } }").worldData.zone
Write-Host ("Zone: {0} ({1} dungeons)" -f $zone.name, $zone.encounters.Count)

# ---- phase 1: discover reports, tagged with the key band they came from ----
$refs = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($enc in $zone.encounters) {
    Assert-Points
    foreach ($band in $bandList) {
        if ($refs.Count -ge $MaxReports * 2) { break }
        $q = "{ worldData { encounter(id: $($enc.id)) { characterRankings(metric: dps, page: 1, bracket: $band) } } }"
        $cr = $null
        try { $cr = (Invoke-GQL $q).worldData.encounter.characterRankings } catch { continue }
        if ($cr -is [string]) { $cr = $cr | ConvertFrom-Json }
        if (-not ($cr -and $cr.rankings)) { continue }
        foreach ($r in ($cr.rankings | Select-Object -First 6)) {
            if (-not ($r.report -and $r.report.code)) { continue }
            $key = "$($r.report.code)#$($r.report.fightID)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            # bracketData is the ACTUAL keystone level of that run; trust it
            # over the bracket we asked for
            $lvl = if ($null -ne $r.bracketData) { [int]$r.bracketData } else { $band }
            [void]$refs.Add(@{ code = $r.report.code; fight = [int]$r.report.fightID; band = $band; lvl = $lvl })
        }
    }
    Write-Host ("  {0}: {1} refs so far" -f $enc.name, $refs.Count)
}
Write-Host ("Discovered {0} report refs" -f $refs.Count)

# ---- phase 2: one DamageDone table per report; itemLevel rides along ----
$groups = @{}   # "spec|band" -> ArrayList of @{ il; lr }
$done = 0
foreach ($ref in $refs) {
    if ($done -ge $MaxReports) { break }
    Assert-Points
    $q = "{ reportData { report(code: `"$($ref.code)`") { table(fightIDs: [$($ref.fight)], dataType: DamageDone) } } }"
    $t = $null
    try { $t = (Invoke-GQL $q).reportData.report.table } catch { continue }
    if ($t -is [string]) { $t = $t | ConvertFrom-Json }
    if (-not ($t -and $t.data -and $t.data.entries)) { continue }
    $done++
    $secs = [double]$t.data.totalTime / 1000.0
    if ($secs -le 10) { continue }
    foreach ($e in $t.data.entries) {
        $il = [double]$e.itemLevel
        $amt = [double]$e.total
        # itemLevel is 0 for pets and for players WCL could not resolve
        if ($il -le 1 -or $amt -le 0) { continue }
        $spec = "$($e.icon)"
        if (-not $spec) { continue }
        $k = "$spec|$($ref.band)"
        if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.ArrayList }
        [void]$groups[$k].Add([pscustomobject]@{ il = $il; lr = [math]::Log($amt / $secs) })
    }
    if ($done % 20 -eq 0) { Write-Host ("  processed $done/$MaxReports reports") }
}

# ---- phase 3: within-group regression, pooled by sample count ----
$slopeNum = 0.0; $slopeDen = 0.0; $used = 0; $perBand = @{}
foreach ($k in $groups.Keys) {
    $rows = $groups[$k]
    if ($rows.Count -lt $MinGroup) { continue }
    $n = $rows.Count
    $sx = 0.0; $sy = 0.0; $sxy = 0.0; $sxx = 0.0
    foreach ($r in $rows) { $sx += $r.il; $sy += $r.lr; $sxy += $r.il * $r.lr; $sxx += $r.il * $r.il }
    $den = $n * $sxx - $sx * $sx
    # a group where everyone wears the same gear says nothing about gear
    if ($den -le 0.0001) { continue }
    $b = ($n * $sxy - $sx * $sy) / $den
    # a NEGATIVE slope inside one band is noise, not a finding; keep it in the
    # pool anyway or the average is biased upward by construction
    $slopeNum += $b * $n; $slopeDen += $n; $used++
    $band = $k.Split("|")[1]
    if (-not $perBand.ContainsKey($band)) { $perBand[$band] = @{ num = 0.0; den = 0.0 } }
    $perBand[$band].num += $b * $n; $perBand[$band].den += $n
}
if ($slopeDen -le 0) { Write-Error "no usable (spec,band) groups - widen MinGroup or raise MaxReports" }
$slope = $slopeNum / $slopeDen
$pct = ([math]::Exp($slope) - 1) * 100
Write-Host ""
Write-Host ("pooled slope over {0} (spec,band) groups, {1} player-fights: {2:n4}%/ilvl" -f $used, [int]$slopeDen, $pct)
foreach ($b in ($perBand.Keys | Sort-Object { [int]$_ })) {
    $p = ([math]::Exp($perBand[$b].num / $perBand[$b].den) - 1) * 100
    Write-Host ("   +{0,-3} {1,6:n3}%/ilvl  (n={2})" -f $b, $p, [int]$perBand[$b].den)
}

$body = @"
-- MEASURED output-vs-item-level slope, from scripts/fetch-ilvl-slope.ps1.
-- $($pct.ToString("n3"))% more output per item level, pooled over $used (spec, keystone band)
-- groups and $([int]$slopeDen) ranked player-fights.
--
-- Regressed WITHIN each (spec, band): higher keys carry both better gear and
-- higher output, so pooling bands measures the key level and calls it gear.
--
-- This is what gear normalisation divides out. The shipped Benchmarks slope
-- was a different measurement and is kept for the paths that already use it;
-- anything normalising a TIER 1 score should use this number, because it is
-- the only one regressed against real ranked players at known key levels.
local _, TP = ...

TP.ILVL_SLOPE_MEASURED = $($pct.ToString("n4"))
TP.ILVL_SLOPE_SAMPLES = $([int]$slopeDen)
"@
$out = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutFile" }
[System.IO.File]::WriteAllText($out, $body, (New-Object System.Text.UTF8Encoding($true)))
Write-Host ("Wrote {0}" -f $out)
