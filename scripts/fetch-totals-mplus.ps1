# Mythic+ true-population totals. Keystone reports are 5-man, so the raid
# totals crawler (fetch-totals.ps1) needs hundreds of reports to cover a
# zone - but a CHARACTER's zoneRankings answers every dungeon at once:
# each encounter row carries allStars.total = that spec's ranked population
# (validated 2026-07-22: Skyreach Ret allStars.total 257,418 == the same
# spec's report-rankings totalParses, exactly). So per capped spec+metric:
# one rankings page -> one report hop (for a character id) -> one
# zoneRankings call = totals for the whole zone.
# NEVER run while another WCL crawl is active (single-active tokens).
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int]$ZoneId = 47,
    [Parameter(Mandatory = $true)][string]$CappedCsv,
    [string]$OutFile = "Totals_Dungeons.lua",
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

$specById = @{
    62 = @("Mage", "Arcane"); 63 = @("Mage", "Fire"); 64 = @("Mage", "Frost")
    65 = @("Paladin", "Holy"); 66 = @("Paladin", "Protection"); 70 = @("Paladin", "Retribution")
    71 = @("Warrior", "Arms"); 72 = @("Warrior", "Fury"); 73 = @("Warrior", "Protection")
    102 = @("Druid", "Balance"); 103 = @("Druid", "Feral"); 104 = @("Druid", "Guardian"); 105 = @("Druid", "Restoration")
    250 = @("DeathKnight", "Blood"); 251 = @("DeathKnight", "Frost"); 252 = @("DeathKnight", "Unholy")
    253 = @("Hunter", "BeastMastery"); 254 = @("Hunter", "Marksmanship"); 255 = @("Hunter", "Survival")
    256 = @("Priest", "Discipline"); 257 = @("Priest", "Holy"); 258 = @("Priest", "Shadow")
    259 = @("Rogue", "Assassination"); 260 = @("Rogue", "Outlaw"); 261 = @("Rogue", "Subtlety")
    262 = @("Shaman", "Elemental"); 263 = @("Shaman", "Enhancement"); 264 = @("Shaman", "Restoration")
    265 = @("Warlock", "Affliction"); 266 = @("Warlock", "Demonology"); 267 = @("Warlock", "Destruction")
    268 = @("Monk", "Brewmaster"); 269 = @("Monk", "Windwalker"); 270 = @("Monk", "Mistweaver")
    577 = @("DemonHunter", "Havoc"); 581 = @("DemonHunter", "Vengeance")
    1467 = @("Evoker", "Devastation"); 1468 = @("Evoker", "Preservation"); 1473 = @("Evoker", "Augmentation")
}

# needed[dungeon] = @{ dps = set; hps = set }; combos = distinct (kind, sid)
$needed = @{}
$combos = @{}
foreach ($line in (Get-Content $CappedCsv)) {
    $p = $line.Split("|")
    if ($p[0] -ne "SPEC") { continue }
    $boss = $p[1]; $kind = $p[3]; $sid = [int]$p[4]
    if (-not $needed[$boss]) { $needed[$boss] = @{ dps = @{}; hps = @{} } }
    $needed[$boss][$kind][$sid] = $true
    $combos["$kind|$sid"] = $true
}
if ($combos.Count -eq 0) { Write-Host "Nothing capped; nothing to do."; exit 0 }

$zone = (Invoke-GQL "{ worldData { zone(id: $ZoneId) { name encounters { id name } } } }").worldData.zone
$encByName = @{}
foreach ($e in $zone.encounters) { $encByName[$e.name] = $e.id }
Write-Host ("Zone: {0}; {1} spec+metric combos to resolve across {2} dungeons" -f $zone.name, $combos.Count, $needed.Count)

# harvested[dungeon][kind][sid] = total
$harvested = @{}
function Store($dungeon, $kind, $sid, $total) {
    # a zero total means "not ranked in this metric", not a population
    if (-not $total -or $total -le 0) { return }
    if (-not $harvested[$dungeon]) { $harvested[$dungeon] = @{ dps = @{}; hps = @{} } }
    $cur = $harvested[$dungeon][$kind][$sid]
    if (-not $cur -or $total -gt $cur) { $harvested[$dungeon][$kind][$sid] = [int]$total }
}
$reportCache = @{}

foreach ($combo in ($combos.Keys | Sort-Object)) {
    $kind, $sidStr = $combo.Split("|")
    $sid = [int]$sidStr
    $cls = $specById[$sid]
    if (-not $cls) { Write-Host "  no class map for spec $sid"; continue }
    # any dungeon that needs this combo supplies the rankings page
    $encName = ($needed.Keys | Where-Object { $needed[$_][$kind][$sid] } | Sort-Object | Select-Object -First 1)
    if (-not $encName -or -not $encByName[$encName]) { continue }
    Assert-Points
    $q = "{ worldData { encounter(id: $($encByName[$encName])) { characterRankings(metric: $kind, page: 1, className: `"$($cls[0])`", specName: `"$($cls[1])`") } } }"
    $cr = $null
    try { $cr = (Invoke-GQL $q).worldData.encounter.characterRankings } catch {
        Write-Host "  $combo`: rankings page failed"; continue
    }
    if ($cr -is [string]) { $cr = $cr | ConvertFrom-Json }
    if (-not ($cr -and $cr.rankings) -or $cr.rankings.Count -eq 0) {
        Write-Host "  $combo`: no ranked characters"; continue
    }
    $done = $false
    foreach ($entry in ($cr.rankings | Select-Object -First 3)) {
        if (-not ($entry.report -and $entry.report.code)) { continue }
        # report hop: rankings characters carry the character id we need
        $cacheKey = "$($entry.report.code)|$kind"
        $rank = $reportCache[$cacheKey]
        if (-not $rank) {
            Assert-Points
            try { $rank = (Invoke-GQL "{ reportData { report(code: `"$($entry.report.code)`") { rankings(playerMetric: $kind) } } }").reportData.report.rankings } catch { continue }
            if ($rank -is [string]) { $rank = $rank | ConvertFrom-Json }
            $reportCache[$cacheKey] = $rank
        }
        $charId = $null
        foreach ($fr in $rank.data) {
            foreach ($roleName in @("tanks", "healers", "dps")) {
                $chars = $fr.roles.$roleName.characters
                if (-not $chars) { continue }
                foreach ($ch in $chars) {
                    # free extra coverage: every character in the report has a
                    # totalParses for THIS dungeon
                    $skey = ("{0}-{1}" -f $ch.class, $ch.spec) -replace " ", ""
                    $dungeon = $null
                    foreach ($n in $encByName.Keys) { if ($encByName[$n] -eq [int]$fr.encounter.id) { $dungeon = $n; break } }
                    if ($dungeon -and $null -ne $ch.totalParses) {
                        foreach ($osid in $specById.Keys) {
                            if (("{0}-{1}" -f $specById[$osid][0], $specById[$osid][1]) -eq $skey) {
                                if ($needed[$dungeon] -and $needed[$dungeon][$kind][$osid]) { Store $dungeon $kind $osid $ch.totalParses }
                                break
                            }
                        }
                    }
                    if (-not $charId -and $ch.name -eq $entry.name) { $charId = $ch.id }
                }
            }
        }
        if (-not $charId) { continue }
        # the payoff: one zoneRankings call = this spec's totals for EVERY dungeon
        Assert-Points
        $zr = $null
        try { $zr = (Invoke-GQL "{ characterData { character(id: $charId) { zoneRankings(zoneID: $ZoneId, metric: $kind) } } }").characterData.character.zoneRankings } catch { continue }
        if ($zr -is [string]) { $zr = $zr | ConvertFrom-Json }
        if (-not ($zr -and $zr.rankings)) { continue }
        $stored = 0
        foreach ($row in $zr.rankings) {
            $rowSpec = ("{0}" -f $row.spec) -replace " ", ""
            if ($rowSpec -ne $cls[1]) { continue } # off-spec rows aren't this population
            if ($row.allStars -and $null -ne $row.allStars.total -and $row.allStars.total -gt 0) {
                $dungeon = $row.encounter.name
                if ($needed[$dungeon] -and $needed[$dungeon][$kind][$sid]) {
                    Store $dungeon $kind $sid $row.allStars.total
                    $stored++
                }
            }
        }
        if ($stored -gt 0) { Write-Host ("  {0}: {1} dungeons via zoneRankings" -f $combo, $stored); $done = $true; break }
    }
    if (-not $done) { Write-Host "  $combo`: unresolved" }
}

# ---- emit (same guarded merge shape as fetch-totals.ps1) ----
$lines = New-Object System.Collections.ArrayList
function Emit($s) { [void]$script:lines.Add($s) }
Emit "-- GENERATED by scripts\fetch-totals-mplus.ps1 - do not edit by hand."
Emit "-- True per-spec populations for the Mythic+ percentile curves, from"
Emit "-- character zoneRankings allStars.total (== report totalParses,"
Emit "-- validated exactly 2026-07-22). M+ populations dwarf the 2000-char"
Emit "-- rankings cap (250k+ per spec), so uncorrected curves sampled only"
Emit "-- the top ~1% and mid-pack keystone runners read absurdly low."
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
$uncovered = New-Object System.Collections.ArrayList
foreach ($dungeon in ($needed.Keys | Sort-Object)) {
    $h = $harvested[$dungeon]
    if (-not $h) { [void]$uncovered.Add($dungeon); continue }
    $maps = @{}
    foreach ($kind in @("dps", "hps")) {
        $parts = @()
        foreach ($sid in ($needed[$dungeon][$kind].Keys | Sort-Object)) {
            if ($h[$kind].ContainsKey($sid)) { $parts += ("[{0}] = {1}" -f $sid, $h[$kind][$sid]) }
            else { [void]$uncovered.Add("$dungeon $kind $sid") }
        }
        $maps[$kind] = if ($parts.Count) { "{ " + ($parts -join ", ") + " }" } else { "nil" }
    }
    Emit ("put(`"{0}`", `"all`", nil, {1}, {2})" -f ($dungeon -replace '"', '\"'), $maps.dps, $maps.hps)
}
$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile }
    else { Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path "Data" $OutFile) }
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath; total HTTP requests: $script:requestCount"
if ($uncovered.Count -gt 0) {
    Write-Host ("UNCOVERED ({0}): {1}" -f $uncovered.Count, (($uncovered | Select-Object -First 10) -join "; "))
}
