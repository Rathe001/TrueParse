# Per-spec overheal distribution fetcher. The rankings API has no overheal
# metric, so this samples REPORT TABLES instead: characterRankings pages
# (spread across the ranked population) supply report codes; each report's
# Healing table yields every healer's effective/overheal split. Emits
# per-spec overheal%% quantiles (p25/p75/p90) that replace the engine's
# fixed 20/45/60 thresholds — a Disc priest's normal overheal is nothing
# like a Resto druid's.
# NEVER run while another WCL crawl is active (single-active tokens).
# MoP:  powershell -File scripts\fetch-overheal.ps1 -GameBase https://classic.warcraftlogs.com `
#           -ZoneId 1054 -Brackets "3x10,3x25" -OutFile Overheal_Mists.lua
param(
    [string]$GameBase = "https://classic.warcraftlogs.com",
    [int]$ZoneId = 1054,
    [string]$Brackets = "3x10,3x25",
    [int]$MaxTables = 120,   # report-table fetches per run (points budget)
    [int]$MinSamples = 40,   # specs with fewer samples are omitted
    [string]$OutFile = "Overheal_Mists.lua",
    [string]$ClientFile = "$PSScriptRoot\wcl-v2-client.local.txt"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $ClientFile)) {
    Write-Error "Missing $ClientFile (line 1 = client id, line 2 = secret)."
}
$creds = Get-Content $ClientFile
$clientId = $creds[0].Trim()
$clientSecret = $creds[1].Trim()

function Get-Token {
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$clientId`:$clientSecret"))
    $resp = Invoke-RestMethod -Method Post -Uri "$GameBase/oauth/token" `
        -Headers @{ Authorization = "Basic $pair" } -Body @{ grant_type = "client_credentials" }
    return $resp.access_token
}
$script:token = Get-Token
Write-Host "OAuth OK; endpoint $GameBase/api/v2/client"

$script:requestCount = 0
function Invoke-GQL($query) {
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $script:requestCount++
            $body = @{ query = $query } | ConvertTo-Json -Compress
            $resp = Invoke-RestMethod -Method Post -Uri "$GameBase/api/v2/client" `
                -Headers @{ Authorization = "Bearer $script:token"; "Content-Type" = "application/json" } `
                -Body $body -TimeoutSec 180
            if ($resp.errors) {
                throw ("GraphQL: " + ($resp.errors | ConvertTo-Json -Compress))
            }
            Start-Sleep -Milliseconds 400
            return $resp.data
        } catch {
            $msg = $_.Exception.Message
            if ($attempt -eq 6) { throw }
            $wait = @(5, 15, 60, 180, 600)[$attempt - 1]
            if ($msg -match "429|point") { $wait = 900 }
            Write-Warning "retry $attempt in ${wait}s: $msg"
            Start-Sleep -Seconds $wait
            if ($attempt -ge 2) { $script:token = Get-Token }
        }
    }
}

function Assert-Points {
    $d = Invoke-GQL "{ rateLimitData { pointsSpentThisHour pointsResetIn } }"
    $spent = [double]$d.rateLimitData.pointsSpentThisHour
    if ($spent -gt 3300) {
        $nap = [int]$d.rateLimitData.pointsResetIn + 30
        Write-Warning "Near point limit ($spent/3600); sleeping ${nap}s"
        Start-Sleep -Seconds $nap
        $script:token = Get-Token
    }
}

# WCL table icon "Class-Spec" -> global specID (healers only; matches
# fetch-percentiles-v2's Class:Spec map)
$specByIcon = @{
    "Druid-Restoration" = 105; "Evoker-Preservation" = 1468
    "Monk-Mistweaver" = 270; "Paladin-Holy" = 65
    "Priest-Discipline" = 256; "Priest-Holy" = 257
    "Shaman-Restoration" = 264
}
# ranking queries need one class/spec pair per call; healer set per game
# version falls out of the zone's population (absent specs just 404 pages)
$rankSpecs = @(
    @{ class = "Druid"; spec = "Restoration" }, @{ class = "Monk"; spec = "Mistweaver" },
    @{ class = "Paladin"; spec = "Holy" }, @{ class = "Priest"; spec = "Discipline" },
    @{ class = "Priest"; spec = "Holy" }, @{ class = "Shaman"; spec = "Restoration" },
    @{ class = "Evoker"; spec = "Preservation" }
)

$bracketList = New-Object System.Collections.ArrayList
foreach ($b in ($Brackets -split ",")) {
    $b = $b.Trim()
    if ($b -match "^(\d+)x(\d+)$") {
        [void]$bracketList.Add(("difficulty: {0}, size: {1}" -f [int]$Matches[1], [int]$Matches[2]))
    } elseif ($b -ne "") {
        [void]$bracketList.Add(("difficulty: {0}" -f [int]$b))
    }
}
if ($bracketList.Count -eq 0) { [void]$bracketList.Add("") }

$zone = (Invoke-GQL "{ worldData { zone(id: $ZoneId) { name encounters { id name } } } }").worldData.zone
Write-Host ("Zone: {0} ({1} encounters)" -f $zone.name, $zone.encounters.Count)

# ---- phase 1: collect report/fight refs spread across the population ----
# pages 1/4/10 per spec+boss+bracket: top, upper-mid, and mid-pack ranks.
# (Deeper pages often don't exist for thin specs; empties are skipped.)
$refs = New-Object System.Collections.ArrayList
$seenRef = @{}
foreach ($enc in $zone.encounters) {
    Assert-Points
    foreach ($bracketArgs in $bracketList) {
        $extra = ""
        if ($bracketArgs -ne "") { $extra = ", $bracketArgs" }
        foreach ($rs in $rankSpecs) {
            foreach ($page in @(1, 4, 10)) {
                $q = "{ worldData { encounter(id: $($enc.id)) { characterRankings(metric: hps, page: $page, className: `"$($rs.class)`", specName: `"$($rs.spec)`"$extra) } } }"
                $cr = $null
                try { $cr = (Invoke-GQL $q).worldData.encounter.characterRankings } catch { continue }
                if (-not ($cr -and $cr.rankings) -or $cr.rankings.Count -eq 0) { continue }
                # stride-sample a few entries per page
                $step = [math]::Max(1, [int]($cr.rankings.Count / 3))
                for ($i = 0; $i -lt $cr.rankings.Count; $i += $step) {
                    $r = $cr.rankings[$i]
                    if (-not ($r.report -and $r.report.code)) { continue }
                    $key = "$($r.report.code)#$($r.report.fightID)"
                    if (-not $seenRef.ContainsKey($key)) {
                        $seenRef[$key] = $true
                        [void]$refs.Add(@{ code = $r.report.code; fight = [int]$r.report.fightID })
                    }
                }
                # rankings pages are expensive; two pages usually suffice
                if ($refs.Count -ge $MaxTables * 3) { break }
            }
        }
    }
    Write-Host ("  {0}: {1} report refs so far" -f $enc.name, $refs.Count)
}

# ---- phase 2: fetch Healing tables, harvest EVERY healer's split ----
# one table = every healer in that fight, so samples accumulate across
# specs far faster than the ranked entry alone
$samples = @{} # specID -> ArrayList of overheal percentages
$shuffled = $refs | Sort-Object { $_.code } # deterministic order, mixed guilds
$fetched = 0
foreach ($ref in $shuffled) {
    if ($fetched -ge $MaxTables) { break }
    Assert-Points
    $q = "{ reportData { report(code: `"$($ref.code)`") { table(fightIDs: [$($ref.fight)], dataType: Healing) } } }"
    $tbl = $null
    try { $tbl = (Invoke-GQL $q).reportData.report.table } catch { continue }
    $fetched++
    $entries = $null
    if ($tbl -and $tbl.data -and $tbl.data.entries) { $entries = $tbl.data.entries }
    elseif ($tbl -and $tbl.entries) { $entries = $tbl.entries }
    if (-not $entries) { continue }
    foreach ($e in $entries) {
        $specID = $e.icon -and $specByIcon[[string]$e.icon]
        if (-not $specID) { continue }
        $eff = [double]($e.total)
        $over = 0.0
        if ($null -ne $e.overheal) { $over = [double]$e.overheal }
        $raw = $eff + $over
        if ($raw -lt 100000) { continue } # trivial participation: skip
        if (-not $samples.ContainsKey($specID)) { $samples[$specID] = New-Object System.Collections.ArrayList }
        [void]$samples[$specID].Add([math]::Round($over / $raw * 100, 1))
    }
}
Write-Host ("Tables fetched: {0}; total HTTP requests: {1}" -f $fetched, $script:requestCount)

# ---- emit: per-spec overheal quantiles ----
function Quantile($sorted, $q) {
    $idx = [math]::Min($sorted.Count - 1, [math]::Max(0, [int]([math]::Round(($sorted.Count - 1) * $q))))
    return $sorted[$idx]
}
$lines = New-Object System.Collections.ArrayList
function Emit($s) { [void]$script:lines.Add($s) }
Emit "-- GENERATED by scripts\fetch-overheal.ps1 - do not edit by hand."
Emit "-- Per-spec overheal%% quantiles sampled from WCL report Healing"
Emit "-- tables (the rankings API has no overheal metric). The engine's"
Emit "-- overheal adjustment uses these instead of fixed thresholds:"
Emit "-- above p90 = -2, above p75 = -1, below p25 = +1."
Emit ("-- Generated {0} - {1}, {2} tables sampled." -f (Get-Date -Format "yyyy-MM-dd"), $zone.name, $fetched)
Emit "local _, TP = ..."
Emit ""
Emit "TP.OverhealCurves = TP.OverhealCurves or {}"
foreach ($specID in ($samples.Keys | Sort-Object)) {
    $list = $samples[$specID]
    if ($list.Count -lt $MinSamples) {
        Write-Host ("  spec {0}: only {1} samples; omitted" -f $specID, $list.Count)
        continue
    }
    $sorted = @($list | Sort-Object)
    $p25 = Quantile $sorted 0.25
    $p75 = Quantile $sorted 0.75
    $p90 = Quantile $sorted 0.90
    Emit ("TP.OverhealCurves[{0}] = {{ p25 = {1}, p75 = {2}, p90 = {3}, n = {4} }}" -f `
        $specID, $p25, $p75, $p90, $list.Count)
    Write-Host ("  spec {0}: n={1} p25={2} p75={3} p90={4}" -f $specID, $list.Count, $p25, $p75, $p90)
}

# Rooted -OutFile is used as-is (CI passes absolute paths); a bare name
# lands in the repo Data dir (same contract as the other fetchers).
$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile }
    else { Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path "Data" $OutFile) }
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath"
