# Per-spec healer INTAKE COVERAGE baselines, crawled from FIVE-MAN content.
# Emits Data/HealerCoverage.lua.
#
# Supersedes the raid-crawled version. That one was justified by a portability
# check - raw coverage x healerN read 0.652/0.723 in two- and three-healer
# raids against 0.680 for a solo M+ healer - but the metric's DENOMINATOR then
# changed twice (healer-count normalisation, then removing self-healing) and
# portability was never re-validated. It does not hold: Josh's five-man healers
# median 0.78 against the raid anchor's 0.97, so they scored a median of 22.
# Crawl the population you actually score against.
#
# Why (Josh 2026-08-01, found by field-testing a heroic dungeon). A healer's
# damage metric was scored against WCL's ranked RAID healers, who barely DPS:
# the reference for a Resto Druid is 955/s while a real dungeon healer does
# 16-31k. 37% of all healer damage scores came out above 90, on a metric
# carrying 21% of the healing family's weight - roughly ten free points.
# Same shape as the M+ healer HPS problem: a reference drawn from a population
# playing different content.
#
# MULTIPLE OF THE GROUP'S PER-PLAYER MEAN, not a rate, for the same reason the
# tank damage anchors use it: it is invariant to key level and group size, so
# one number per spec covers every dungeon and every key instead of needing a
# curve per band. A healer at 0.40 did 40% of what the average party member
# did.
#
# NEVER run while another WCL crawl is active (single-active tokens).
#   Retail M+: -GameBase https://www.warcraftlogs.com -ZoneId 47
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int]$ZoneId = 47,
    [string]$Bands = "2,5,8,11,14",   # keystone bands to sample separately
    [int]$MaxReports = 160,
    [int]$MinSamples = 20,            # specs thinner than this stay on the default
    [string]$OutFile = "HealerCoverage.lua",
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

# ---- phase 2: healer damage as a multiple of the party's per-player mean ----
$healerByIcon = @{
    "Paladin-Holy" = 65; "Priest-Discipline" = 256; "Priest-Holy" = 257
    "Shaman-Restoration" = 264; "Druid-Restoration" = 105; "Monk-Mistweaver" = 270
    "Evoker-Preservation" = 1468
}
$samples = @{}
$done = 0
foreach ($ref in $refs) {
    if ($done -ge $MaxReports) { break }
    Assert-Points
    $q = "{ reportData { report(code: `"$($ref.code)`") { hd: table(fightIDs: [$($ref.fight)], dataType: Healing) dt: table(fightIDs: [$($ref.fight)], dataType: DamageTaken) } } }"
    $r = $null
    try { $r = (Invoke-GQL $q).reportData.report } catch { continue }
    if (-not $r) { continue }
    $hd = $r.hd; if ($hd -is [string]) { $hd = $hd | ConvertFrom-Json }
    $dt = $r.dt; if ($dt -is [string]) { $dt = $dt | ConvertFrom-Json }
    if (-not ($hd -and $hd.data -and $hd.data.entries -and $dt -and $dt.data -and $dt.data.entries)) { continue }
    $done++
    # WCL's DamageTaken already INCLUDES absorbed damage (probe-verified:
    # healing/damageTaken = 0.996 on a reference report), so it is the same
    # "damage that had to be handled" the addon computes as damageTaken+absorbs
    $intake = 0.0
    foreach ($e in $dt.data.entries) { $intake += [double]$e.total }
    $healerN = 0
    $selfHeal = 0.0
    foreach ($e in $hd.data.entries) {
        if ($healerByIcon[$e.icon]) { $healerN++ } else { $selfHeal += [double]$e.total }
    }
    # only what nobody else covered is the healer's to cover
    $healable = $intake - $selfHeal
    if ($healable -lt $intake * 0.15) { $healable = $intake * 0.15 }
    if ($healable -le 0 -or $healerN -le 0) { continue }
    foreach ($e in $hd.data.entries) {
        $spec = $healerByIcon[$e.icon]
        if (-not $spec) { continue }
        $cov = [double]$e.total / $healable * $healerN
        if ($cov -le 0 -or $cov -gt 4) { continue }
        if (-not $samples.ContainsKey($spec)) { $samples[$spec] = New-Object System.Collections.ArrayList }
        [void]$samples[$spec].Add($cov)
    }
    if ($done % 20 -eq 0) { Write-Host ("  processed $done/$MaxReports reports") }
}

function Quantile($sorted, $q) {
    $n = $sorted.Count
    if ($n -eq 0) { return 0 }
    $idx = [math]::Min($n - 1, [math]::Max(0, [int][math]::Floor($q * ($n - 1) + 0.5)))
    return $sorted[$idx]
}
$names = @{ 65 = "Holy Paladin"; 105 = "Resto Druid"; 256 = "Disc Priest"; 257 = "Holy Priest";
    264 = "Resto Shaman"; 270 = "Mistweaver"; 1468 = "Preservation" }
$lines = New-Object System.Collections.ArrayList
$a25 = New-Object System.Collections.ArrayList
$a50 = New-Object System.Collections.ArrayList
$a75 = New-Object System.Collections.ArrayList
foreach ($spec in ($samples.Keys | Sort-Object)) {
    $arr = @($samples[$spec] | Sort-Object)
    if ($arr.Count -lt $MinSamples) { Write-Host ("  spec ${spec}: only $($arr.Count) samples, skipped"); continue }
    $p25 = [math]::Round((Quantile $arr 0.25), 3)
    $p50 = [math]::Round((Quantile $arr 0.50), 3)
    $p75 = [math]::Round((Quantile $arr 0.75), 3)
    Write-Host ("  spec $spec ($($names[$spec])): n=$($arr.Count) p25=$p25 p50=$p50 p75=$p75")
    [void]$lines.Add(("`t[{0}] = {{ {1}, {2}, {3} }}, -- {4} (n={5})" -f $spec, $p25, $p50, $p75, $names[$spec], $arr.Count))
    [void]$a25.Add($p25); [void]$a50.Add($p50); [void]$a75.Add($p75)
}
$defLine = "nil, -- nothing crawled yet"
if ($a50.Count -ge 2) {
    $x25 = [math]::Round((Quantile (@($a25 | Sort-Object)) 0.50), 3)
    $x50 = [math]::Round((Quantile (@($a50 | Sort-Object)) 0.50), 3)
    $x75 = [math]::Round((Quantile (@($a75 | Sort-Object)) 0.50), 3)
    if ($x25 -le $x50 -and $x50 -le $x75) { $defLine = "{ $x25, $x50, $x75 }, -- DERIVED: median of the $($a50.Count) crawled specs" }
}
$body = @"
-- Per-spec healer COVERAGE baselines, crawled from FIVE-MAN content:
-- { p25, p50, p75 } of a healer's healing divided by the intake that was
-- actually THEIRS TO HEAL - damage taken less what the group healed itself -
-- times the healer count. Read 0.99 as "covered 99% of a fair share of the
-- damage nobody else picked up".
--
-- CRAWLED FROM MYTHIC+, not raids, and that distinction cost a day. Scoring a
-- five-man healer on HPS pays them for their group standing in things
-- (correlation +0.44 with group intake), so coverage replaced it - but the
-- first crawl took its anchors from raid logs, justified by a portability
-- check made BEFORE the denominator changed twice. It did not hold: Josh's
-- five-man healers median 0.78 against a raid anchor of 0.97 and scored a
-- median of 22. Crawl the population you score against.
local _, TP = ...

TP.HEALER_COVERAGE_UNIT = "healable-share-x-healers"

TP.HEALER_COVERAGE_ANCHORS = {
	default = $defLine
$($lines -join "`n")
}
"@
$out = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutFile" }
[System.IO.File]::WriteAllText($out, $body, (New-Object System.Text.UTF8Encoding($true)))
Write-Host ("Wrote {0} ({1} specs)" -f $out, $lines.Count)
