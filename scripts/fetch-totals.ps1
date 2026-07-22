# True-population totals fetcher. WCL's rankings endpoints are silently
# capped (characterRankings: 2000 chars/spec; fightRankings: 1000 kills),
# so capped curves are top-slice samples. Report-level rankings expose the
# REAL population ("rank X of totalParses Y" per character, and
# speed.totalParses per fight), so this script samples a handful of ranked
# reports per bracket and harvests true totals for every capped entry
# found by dump-capped.lua. The engine rescales capped curves with them.
# NEVER run while another WCL crawl is active (single-active tokens).
#
# MoP:    lua dump-capped.lua Data\Percentiles_Mists.lua Data\Percentiles_Mists_25.lua Data\KillTimes_Mists.lua > capped.csv
#         powershell -File scripts\fetch-totals.ps1 -GameBase https://classic.warcraftlogs.com `
#             -ZoneId 1054 -BracketStyle classic -CappedCsv capped.csv -OutFile Totals_Mists.lua
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int]$ZoneId = 46,
    [ValidateSet("classic", "retail", "all")]
    [string]$BracketStyle = "retail",
    [Parameter(Mandatory = $true)][string]$CappedCsv,
    [string]$OutFile = "Totals.lua",
    [int]$MaxReports = 60,
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
                -Headers @{ Authorization = "Bearer $script:token" } `
                -ContentType "application/json" -Body $body
            if ($resp.errors) { throw ($resp.errors | ConvertTo-Json -Compress) }
            return $resp.data
        } catch {
            if ($attempt -eq 6) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
            if ($attempt -ge 3) { $script:token = Get-Token }
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

# specID -> rankings query names. Combat/Outlaw is the one per-era rename.
$rogue2 = if ($BracketStyle -eq "classic") { "Combat" } else { "Outlaw" }
$specById = @{
    62 = @("Mage", "Arcane"); 63 = @("Mage", "Fire"); 64 = @("Mage", "Frost")
    65 = @("Paladin", "Holy"); 66 = @("Paladin", "Protection"); 70 = @("Paladin", "Retribution")
    71 = @("Warrior", "Arms"); 72 = @("Warrior", "Fury"); 73 = @("Warrior", "Protection")
    102 = @("Druid", "Balance"); 103 = @("Druid", "Feral"); 104 = @("Druid", "Guardian"); 105 = @("Druid", "Restoration")
    250 = @("DeathKnight", "Blood"); 251 = @("DeathKnight", "Frost"); 252 = @("DeathKnight", "Unholy")
    253 = @("Hunter", "BeastMastery"); 254 = @("Hunter", "Marksmanship"); 255 = @("Hunter", "Survival")
    256 = @("Priest", "Discipline"); 257 = @("Priest", "Holy"); 258 = @("Priest", "Shadow")
    259 = @("Rogue", "Assassination"); 260 = @("Rogue", $rogue2); 261 = @("Rogue", "Subtlety")
    262 = @("Shaman", "Elemental"); 263 = @("Shaman", "Enhancement"); 264 = @("Shaman", "Restoration")
    265 = @("Warlock", "Affliction"); 266 = @("Warlock", "Demonology"); 267 = @("Warlock", "Destruction")
    268 = @("Monk", "Brewmaster"); 269 = @("Monk", "Windwalker"); 270 = @("Monk", "Mistweaver")
    577 = @("DemonHunter", "Havoc"); 581 = @("DemonHunter", "Vengeance")
    1467 = @("Evoker", "Devastation"); 1468 = @("Evoker", "Preservation"); 1473 = @("Evoker", "Augmentation")
}
$idBySpec = @{}
foreach ($sid in $specById.Keys) {
    $idBySpec[("{0}-{1}" -f $specById[$sid][0], $specById[$sid][1])] = $sid
}

# ---- parse the capped list ----
# needed[encName|bracket] = @{ kills; dps = set; hps = set; anchorKind; anchorSid }
$needed = @{}
function Need($boss, $bracket) {
    $k = "$boss|$bracket"
    if (-not $needed[$k]) {
        $needed[$k] = @{ boss = $boss; bracket = $bracket; kills = $false
            dps = @{}; hps = @{}; anchorKind = $null; anchorSid = 0; tries = 0 }
    }
    return $needed[$k]
}
foreach ($line in (Get-Content $CappedCsv)) {
    $p = $line.Split("|")
    switch ($p[0]) {
        "SPEC" { (Need $p[1] $p[2]).($p[3])[[int]$p[4]] = $true }
        "KT" { (Need $p[1] $p[2]).kills = $true }
        "ANCHOR" { $t = Need $p[1] $p[2]; $t.anchorKind = $p[3]; $t.anchorSid = [int]$p[4] }
    }
}
if ($needed.Count -eq 0) { Write-Host "Nothing capped; nothing to do."; exit 0 }

$zone = (Invoke-GQL "{ worldData { zone(id: $ZoneId) { name encounters { id name } } } }").worldData.zone
$encId = @{}
$encName = @{}
foreach ($e in $zone.encounters) { $encId[$e.name] = $e.id; $encName[[int]$e.id] = $e.name }
Write-Host ("Zone: {0}; {1} boss+bracket groups need totals" -f $zone.name, $needed.Count)

function BracketArgs($bracket) {
    if ($BracketStyle -eq "classic" -and $bracket -match "^(\d+)x(\d+)$") {
        return (", difficulty: {0}, size: {1}" -f [int]$Matches[1], [int]$Matches[2])
    } elseif ($BracketStyle -eq "retail" -and $bracket -match "^\d+$") {
        return (", difficulty: {0}" -f [int]$bracket)
    }
    return ""
}
function BracketKey($fight) {
    if ($BracketStyle -eq "classic") { return "{0}x{1}" -f $fight.difficulty, $fight.size }
    if ($BracketStyle -eq "retail") { return [string]$fight.difficulty }
    return "all"
}

# harvested[key] = @{ kills = N; dps = @{sid=M}; hps = @{sid=M} }
$harvested = @{}
function Harvest($key) {
    if (-not $harvested[$key]) { $harvested[$key] = @{ kills = 0; dps = @{}; hps = @{} } }
    return $harvested[$key]
}
$seenReports = @{} # "code|metric" -> $true

function Covered($t) {
    $h = $harvested["$($t.boss)|$($t.bracket)"]
    if (-not $h) { return $false }
    if ($t.kills -and $h.kills -eq 0) { return $false }
    foreach ($kind in @("dps", "hps")) {
        foreach ($sid in $t.$kind.Keys) {
            if (-not $h.$kind.ContainsKey($sid)) { return $false }
        }
    }
    return $true
}

function ProcessReport($code, $metric) {
    $seen = "$code|$metric"
    if ($seenReports[$seen]) { return }
    $seenReports[$seen] = $true
    Assert-Points
    $rank = $null
    try {
        $rank = (Invoke-GQL "{ reportData { report(code: `"$code`") { rankings(playerMetric: $metric) } } }").reportData.report.rankings
    } catch { Write-Host "  report $code ($metric): failed, skipping"; return }
    if ($rank -is [string]) { $rank = $rank | ConvertFrom-Json }
    if (-not ($rank -and $rank.data)) { return }
    foreach ($fr in $rank.data) {
        $boss = $encName[[int]$fr.encounter.id]
        if (-not $boss) { continue }
        $bk = BracketKey $fr
        $key = "$boss|$bk"
        if (-not $needed[$key]) { continue }
        $h = Harvest $key
        if ($fr.speed -and $fr.speed.totalParses -gt $h.kills) { $h.kills = [int]$fr.speed.totalParses }
        foreach ($roleName in @("tanks", "healers", "dps")) {
            $chars = $fr.roles.$roleName.characters
            if (-not $chars) { continue }
            foreach ($ch in $chars) {
                $skey = ("{0}-{1}" -f $ch.class, $ch.spec) -replace " ", ""
                $sid = $idBySpec[$skey]
                if (-not $sid) { continue }
                if ($null -eq $ch.totalParses) { continue }
                $cur = $h.$metric[$sid]
                if (-not $cur -or $ch.totalParses -gt $cur) { $h.$metric[$sid] = [int]$ch.totalParses }
            }
        }
    }
}

# ---- main loop: pick an uncovered target, mine reports from its rankings ----
$reportBudget = $MaxReports
while ($reportBudget -gt 0) {
    $target = $null
    $wantKind = $null
    $wantSid = 0
    foreach ($t in ($needed.Values | Sort-Object { $_.boss }, { $_.bracket })) {
        if ($t.tries -ge 4 -or (Covered $t)) { continue }
        # first spec still missing decides which rankings page we pull
        foreach ($kind in @("dps", "hps")) {
            foreach ($sid in ($t.$kind.Keys | Sort-Object)) {
                if (-not (Harvest "$($t.boss)|$($t.bracket)").$kind.ContainsKey($sid)) {
                    $target = $t; $wantKind = $kind; $wantSid = $sid; break
                }
            }
            if ($target) { break }
        }
        if (-not $target -and $t.kills) { $target = $t; $wantKind = $t.anchorKind; $wantSid = $t.anchorSid }
        if ($target) { break }
    }
    if (-not $target) { break }
    $target.tries++
    $cls = $specById[$wantSid]
    if (-not $cls) { Write-Host "  no class map for spec $wantSid"; continue }
    $metric = if ($wantKind -eq "hps") { "hps" } else { "dps" }
    Assert-Points
    $q = "{ worldData { encounter(id: $($encId[$target.boss])) { characterRankings(metric: $metric, page: 1, className: `"$($cls[0])`", specName: `"$($cls[1])`"$(BracketArgs $target.bracket)) } } }"
    $cr = $null
    try { $cr = (Invoke-GQL $q).worldData.encounter.characterRankings } catch {
        Write-Host ("  rankings page failed for {0} {1} spec {2}" -f $target.boss, $target.bracket, $wantSid); continue
    }
    if ($cr -is [string]) { $cr = $cr | ConvertFrom-Json }
    if (-not ($cr -and $cr.rankings) -or $cr.rankings.Count -eq 0) { continue }
    $codes = @()
    $step = [math]::Max(1, [int]($cr.rankings.Count / 4))
    for ($i = 0; $i -lt $cr.rankings.Count -and $codes.Count -lt 4; $i += $step) {
        $r = $cr.rankings[$i]
        if ($r.report -and $r.report.code -and ($codes -notcontains $r.report.code)) { $codes += $r.report.code }
    }
    foreach ($code in $codes) {
        if ($reportBudget -le 0) { break }
        # one report answers both metrics; only spend queries on kinds still open
        foreach ($m in @("dps", "hps")) {
            $anyOpen = $false
            foreach ($t in $needed.Values) {
                foreach ($sid in $t.$m.Keys) {
                    if (-not (Harvest "$($t.boss)|$($t.bracket)").$m.ContainsKey($sid)) { $anyOpen = $true; break }
                }
                if ($anyOpen) { break }
            }
            if ($m -eq "dps") { $anyOpen = $true } # dps call also carries speed totals
            if ($anyOpen) { ProcessReport $code $m }
        }
        $reportBudget--
    }
    $done = @($needed.Values | Where-Object { Covered $_ }).Count
    Write-Host ("  progress: {0}/{1} groups covered; {2} reports left in budget" -f $done, $needed.Count, $reportBudget)
}

# ---- emit ----
$lines = New-Object System.Collections.ArrayList
function Emit($s) { [void]$script:lines.Add($s) }
Emit "-- GENERATED by scripts\fetch-totals.ps1 - do not edit by hand."
Emit "-- True population sizes for curve entries that hit WCL's rankings"
Emit "-- caps (2000 chars/spec, 1000 kills). The engine rescales a capped"
Emit "-- curve's sample percentile into the real population: without this,"
Emit "-- mid-pack players of POPULAR specs read 10-30 points low and the"
Emit "-- kill-speed field is overestimated ~3x (validated 2026-07-22"
Emit "-- against report ByCMpAjX9HnYDkQr's official rankPercents)."
Emit ("-- Generated {0} - {1}." -f (Get-Date -Format "yyyy-MM-dd"), $zone.name)
Emit "local _, TP = ..."
Emit ""
Emit "local E = TP.Percentiles and TP.Percentiles.encounters"
Emit "if not E then return end"
Emit "local function put(name, bracket, kills, dps, hps)"
Emit "`tlocal b = E[name] and E[name][bracket]"
Emit "`tif not b then return end"
Emit "`tif kills and kills > 0 and b.killTime and kills > (b.killTime.n or 0) then"
Emit "`t`tb.killTime.total = kills"
Emit "`tend"
Emit "`tlocal function mark(kind, map)"
Emit "`t`tfor sid, m in pairs(map) do"
Emit "`t`t`tlocal e = b[kind] and b[kind][sid]"
Emit "`t`t`tif e and m > (e.n or 0) then e.total = m end"
Emit "`t`tend"
Emit "`tend"
Emit "`tmark(`"dps`", dps or {})"
Emit "`tmark(`"hps`", hps or {})"
Emit "end"
Emit ""
$uncoveredNote = New-Object System.Collections.ArrayList
foreach ($k in ($needed.Keys | Sort-Object)) {
    $t = $needed[$k]
    $h = $harvested[$k]
    if (-not $h) { [void]$uncoveredNote.Add($k); continue }
    $maps = @{}
    foreach ($kind in @("dps", "hps")) {
        $parts = @()
        foreach ($sid in ($t.$kind.Keys | Sort-Object)) {
            if ($h.$kind.ContainsKey($sid)) { $parts += ("[{0}] = {1}" -f $sid, $h.$kind[$sid]) }
            else { [void]$uncoveredNote.Add("$k $kind spec $sid") }
        }
        $maps[$kind] = if ($parts.Count) { "{ " + ($parts -join ", ") + " }" } else { "nil" }
    }
    $kills = if ($t.kills -and $h.kills -gt 0) { $h.kills } else { "nil" }
    if ($t.kills -and $h.kills -eq 0) { [void]$uncoveredNote.Add("$k kills") }
    Emit ("put(`"{0}`", `"{1}`", {2}, {3}, {4})" -f $t.boss, $t.bracket, $kills, $maps.dps, $maps.hps)
}
$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile }
    else { Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path "Data" $OutFile) }
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath; total HTTP requests: $script:requestCount"
if ($uncoveredNote.Count -gt 0) {
    Write-Host ("UNCOVERED ({0}): {1}" -f $uncoveredNote.Count, (($uncoveredNote | Select-Object -First 12) -join "; "))
}
