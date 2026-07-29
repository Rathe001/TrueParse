# WCL tank active-mitigation uptime harvester (Josh 2026-07-26). Emits
# Data/TankAnchors.lua = per-spec { p25, p50, p75 } of active-mitigation
# UPTIME %, the WCL-relative baseline the Tanking metric scores against
# ("you held mitigation up 57%, the average Guardian holds 71%"). Replaces
# the arbitrary { 30, 55, 75 } guess.
#
# Method (probe-verified 2026-07-26): the Buffs table filtered to an
# abilityID returns one entry PER PLAYER who carried that buff, with the
# spec icon ("Druid-Guardian") and per-band start/end times. We union each
# player's bands across ALL of their spec's mitigation buffs (matching the
# addon's reference-counted union in Metrics/Mitigation.lua), divide by the
# fight duration (data.totalTime), and collect one uptime% per tank per
# fight. Per spec: p25/p50/p75 of the sample.
#
# NEVER run while another WCL crawl is active (single-active tokens).
#  MoP:    -GameBase https://classic.warcraftlogs.com -ZoneId 1054 -Brackets "3x10,3x25" -MitIds mists
#  Retail: -GameBase https://www.warcraftlogs.com     -ZoneId 46   -Brackets "5,4"       -MitIds retail
param(
    [string]$GameBase = "https://classic.warcraftlogs.com",
    [int]$ZoneId = 1054,
    [string]$Brackets = "3x10,3x25",
    [int]$MaxReports = 200,
    [int]$MinSamples = 20,   # specs with fewer tank-fights stay on the default
    [string]$MitIds = "mists", # "mists" | "retail" | comma-separated ids
    [string]$OutFile = "TankAnchors.lua",
    [string]$OutDamageFile = "TankDamage.lua",
    [string]$ClientFile = "$PSScriptRoot\wcl-v2-client.local.txt"
)
$ErrorActionPreference = "Stop"

# mitigation-buff id sets mirror Data/Mitigation*.lua (buff ids, not casts)
$mitSets = @{
    mists  = @(115307, 132404, 112048, 132403, 132402, 77535, 115295, 123402, 115308, 65148)
    retail = @(132404, 132403, 192081, 77535, 203819, 215479)
}
if ($mitSets.ContainsKey($MitIds)) { $mitList = $mitSets[$MitIds] }
else { $mitList = @($MitIds -split "," | ForEach-Object { [int]$_.Trim() }) }

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

$specByIcon = @{
    "Paladin-Protection" = 66; "Warrior-Protection" = 73; "Druid-Guardian" = 104
    "DeathKnight-Blood" = 250; "Monk-Brewmaster" = 268; "DemonHunter-Vengeance" = 581
}
$tankRanks = @(
    @{ class = "DeathKnight"; spec = "Blood" }
    @{ class = "Warrior"; spec = "Protection" }
    @{ class = "Paladin"; spec = "Protection" }
    @{ class = "Druid"; spec = "Guardian" }
    @{ class = "Monk"; spec = "Brewmaster" }
    @{ class = "DemonHunter"; spec = "Vengeance" }
)

$bracketList = @()
foreach ($b in ($Brackets -split ",")) {
    $b = $b.Trim()
    if ($b -match "^(\d+)x(\d+)$") { $bracketList += (", difficulty: {0}, size: {1}" -f [int]$Matches[1], [int]$Matches[2]) }
    elseif ($b -ne "") { $bracketList += (", difficulty: {0}" -f [int]$b) }
}
if ($bracketList.Count -eq 0) { $bracketList = @("") }

$zone = (Invoke-GQL "{ worldData { zone(id: $ZoneId) { name encounters { id name } } } }").worldData.zone
Write-Host ("Zone: {0} ({1} encounters)" -f $zone.name, $zone.encounters.Count)

# ---- phase 1: discover report refs via tank rankings, all bosses ----
$refs = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($enc in $zone.encounters) {
    Assert-Points
    foreach ($extra in $bracketList) {
        foreach ($rs in $tankRanks) {
            foreach ($page in @(1, 3, 6)) {
                if ($refs.Count -ge $MaxReports * 2) { break }
                $q = "{ worldData { encounter(id: $($enc.id)) { characterRankings(metric: dps, page: $page, className: `"$($rs.class)`", specName: `"$($rs.spec)`"$extra) } } }"
                $cr = $null
                try { $cr = (Invoke-GQL $q).worldData.encounter.characterRankings } catch { continue }
                if ($cr -is [string]) { $cr = $cr | ConvertFrom-Json }
                if (-not ($cr -and $cr.rankings)) { continue }
                foreach ($r in ($cr.rankings | Select-Object -First 4)) {
                    if (-not ($r.report -and $r.report.code)) { continue }
                    $key = "$($r.report.code)#$($r.report.fightID)"
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        [void]$refs.Add(@{ code = $r.report.code; fight = [int]$r.report.fightID })
                    }
                }
            }
        }
    }
    Write-Host ("  {0}: {1} refs so far" -f $enc.name, $refs.Count)
}
Write-Host ("Discovered {0} report refs" -f $refs.Count)

# ---- phase 2: one aliased Buffs query per report; union bands per tank ----
function Merge-Uptime($bands) {
    if ($bands.Count -eq 0) { return 0 }
    $sorted = $bands | Sort-Object { $_[0] }
    $total = 0.0; $curS = $sorted[0][0]; $curE = $sorted[0][1]
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $s = $sorted[$i][0]; $e = $sorted[$i][1]
        if ($s -le $curE) { if ($e -gt $curE) { $curE = $e } }
        else { $total += ($curE - $curS); $curS = $s; $curE = $e }
    }
    $total += ($curE - $curS)
    return $total
}

$aliases = @()
for ($i = 0; $i -lt $mitList.Count; $i++) { $aliases += "m${i}: table(fightIDs: [FIGHT], dataType: Buffs, abilityID: $($mitList[$i]))" }
# DamageDone rides along in the same query (WCL returns aliased tables in
# one response): tank damage as a SHARE of the raid's total for that fight.
# Share, not DPS, because it pools across encounters, brackets and gear.
$aliases += "dd: table(fightIDs: [FIGHT], dataType: DamageDone)"
$samples = @{}  # specID -> ArrayList of uptime%
$dmgSamples = @{}  # specID -> ArrayList of raid-damage share %
$done = 0
foreach ($ref in $refs) {
    if ($done -ge $MaxReports) { break }
    Assert-Points
    # case-SENSITIVE: a plain -replace also rewrites the "fight" in
    # "fightIDs" (PowerShell -replace is case-insensitive)
    $body = ($aliases -join " ") -creplace "FIGHT", "$($ref.fight)"
    $q = "{ reportData { report(code: `"$($ref.code)`") { $body } } }"
    $rep = $null
    try { $rep = (Invoke-GQL $q).reportData.report } catch { continue }
    if (-not $rep) { continue }
    $done++
    $byPlayer = @{}   # guid -> @{ specID; bands = ArrayList }
    $totalTime = 0
    for ($i = 0; $i -lt $mitList.Count; $i++) {
        $t = $rep."m$i"
        if ($t -is [string]) { $t = $t | ConvertFrom-Json }
        if (-not ($t -and $t.data)) { continue }
        if ($t.data.totalTime -gt $totalTime) { $totalTime = [double]$t.data.totalTime }
        foreach ($a in $t.data.auras) {
            $spec = $specByIcon[$a.icon]
            if (-not $spec) { continue }
            if (-not $byPlayer.ContainsKey($a.guid)) { $byPlayer[$a.guid] = @{ specID = $spec; bands = (New-Object System.Collections.ArrayList) } }
            foreach ($b in $a.bands) { [void]$byPlayer[$a.guid].bands.Add(@([double]$b.startTime, [double]$b.endTime)) }
        }
    }
    if ($totalTime -le 0) { continue }
    foreach ($guid in $byPlayer.Keys) {
        $pl = $byPlayer[$guid]
        $up = (Merge-Uptime $pl.bands) / $totalTime * 100.0
        if ($up -le 0 -or $up -gt 100) { continue }
        if (-not $samples.ContainsKey($pl.specID)) { $samples[$pl.specID] = New-Object System.Collections.ArrayList }
        [void]$samples[$pl.specID].Add($up)
    }

    # --- tank share of raid damage, same fight, same query ---
    $dd = $rep.dd
    if ($dd -is [string]) { $dd = $dd | ConvertFrom-Json }
    if ($dd -and $dd.data -and $dd.data.entries) {
        $raidTotal = 0.0
        foreach ($e in $dd.data.entries) { $raidTotal += [double]$e.total }
        if ($raidTotal -gt 0) {
            foreach ($e in $dd.data.entries) {
                $spec = $specByIcon[$e.icon]
                if (-not $spec) { continue }
                $share = [double]$e.total / $raidTotal * 100.0
                if ($share -le 0 -or $share -gt 100) { continue }
                if (-not $dmgSamples.ContainsKey($spec)) { $dmgSamples[$spec] = New-Object System.Collections.ArrayList }
                [void]$dmgSamples[$spec].Add($share)
            }
        }
    }
    if ($done % 25 -eq 0) { Write-Host ("  processed $done/$MaxReports reports") }
}

function Quantile($sorted, $q) {
    $n = $sorted.Count
    if ($n -eq 0) { return 0 }
    $idx = [math]::Min($n - 1, [math]::Max(0, [int][math]::Floor($q * ($n - 1) + 0.5)))
    return $sorted[$idx]
}

$specNames = @{ 66 = "Prot Paladin"; 73 = "Prot Warrior"; 104 = "Guardian Druid"; 250 = "Blood DK"; 268 = "Brewmaster"; 581 = "Vengeance DH" }
$lines = New-Object System.Collections.ArrayList
$crawled25 = New-Object System.Collections.ArrayList
$crawled50 = New-Object System.Collections.ArrayList
$crawled75 = New-Object System.Collections.ArrayList
foreach ($spec in ($samples.Keys | Sort-Object)) {
    $arr = @($samples[$spec] | Sort-Object)
    if ($arr.Count -lt $MinSamples) { Write-Host ("  spec ${spec}: only $($arr.Count) samples (< $MinSamples), skipped"); continue }
    $p25 = [math]::Round((Quantile $arr 0.25), 1)
    $p50 = [math]::Round((Quantile $arr 0.50), 1)
    $p75 = [math]::Round((Quantile $arr 0.75), 1)
    Write-Host ("  spec $spec ($($specNames[$spec])): n=$($arr.Count) p25=$p25 p50=$p50 p75=$p75")
    [void]$lines.Add(("`t[{0}] = {{ {1}, {2}, {3} }}, -- {4} (n={5})" -f $spec, $p25, $p50, $p75, $specNames[$spec], $arr.Count))
    [void]$crawled25.Add($p25); [void]$crawled50.Add($p50); [void]$crawled75.Add($p75)
}

# DEFAULT, derived from the specs we DID crawl (Josh 2026-07-28). It used to
# be a hardcoded { 30, 55, 75 } seeded from Classic, and on retail that is
# wildly low - a MEDIAN Prot Warrior holds 90% uptime and was scoring 94
# against it, on the metric worth 55% of a tank's grade. A spec too rare to
# crawl is far better served by the middle of its peers than by a guess from
# another expansion.
# Median per quantile, not mean: Guardian Druid sits ~40 points below the
# other tanks and would drag an average down. Falls back to the old constant
# only when nothing at all was crawled.
$defLine = "{ 30, 55, 75 }, -- provisional: nothing crawled yet"
if ($crawled50.Count -ge 2) {
    $d25 = [math]::Round((Quantile (@($crawled25 | Sort-Object)) 0.50), 1)
    $d50 = [math]::Round((Quantile (@($crawled50 | Sort-Object)) 0.50), 1)
    $d75 = [math]::Round((Quantile (@($crawled75 | Sort-Object)) 0.50), 1)
    # quantiles must still ascend after taking each one's median independently
    if ($d25 -le $d50 -and $d50 -le $d75) {
        $defLine = "{ $d25, $d50, $d75 }, -- DERIVED: median of the $($crawled50.Count) crawled specs"
        Write-Host ("  default derived from crawled specs: $d25 / $d50 / $d75")
    } else {
        Write-Host "  derived default not monotone, keeping the constant"
    }
}

$header = @"
-- Per-spec active-mitigation UPTIME baselines: { p25, p50, p75 } of the
-- fraction of a fight tanks of this spec hold active mitigation up,
-- crawled from Warcraft Logs (scripts/fetch-tank-mitigation.ps1). The
-- Tanking metric scores a tank's own uptime as a percentile against its
-- spec's field, so "equally skilled tanks parse similarly" holds the same
-- way damage parses do. WCL-relative, never hand-tuned (Josh 2026-07-26).
-- Regenerated by CI. A spec without enough samples falls back to `default`,
-- which is itself DERIVED from the crawled specs (median per quantile) so a
-- rare spec is judged against the middle of its peers rather than a guess.
local _, TP = ...

TP.TANK_ANCHORS = {
	default = $defLine
$($lines -join "`n")
}
"@
$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutFile" }
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($outPath, $header, $utf8Bom)
Write-Host ("Wrote {0} ({1} specs, {2} reports processed)" -f $outPath, $lines.Count, $done)

# ---- tank damage share ----------------------------------------------------
$dLines = New-Object System.Collections.ArrayList
$d25s = New-Object System.Collections.ArrayList
$d50s = New-Object System.Collections.ArrayList
$d75s = New-Object System.Collections.ArrayList
foreach ($spec in ($dmgSamples.Keys | Sort-Object)) {
    $arr = @($dmgSamples[$spec] | Sort-Object)
    if ($arr.Count -lt $MinSamples) { Write-Host ("  dmg spec ${spec}: only $($arr.Count) samples (< $MinSamples), skipped"); continue }
    $p25 = [math]::Round((Quantile $arr 0.25), 2)
    $p50 = [math]::Round((Quantile $arr 0.50), 2)
    $p75 = [math]::Round((Quantile $arr 0.75), 2)
    Write-Host ("  dmg spec $spec ($($specNames[$spec])): n=$($arr.Count) p25=$p25 p50=$p50 p75=$p75")
    [void]$dLines.Add(("`t[{0}] = {{ {1}, {2}, {3} }}, -- {4} (n={5})" -f $spec, $p25, $p50, $p75, $specNames[$spec], $arr.Count))
    [void]$d25s.Add($p25); [void]$d50s.Add($p50); [void]$d75s.Add($p75)
}
$dDefLine = "nil, -- nothing crawled yet"
if ($d50s.Count -ge 2) {
    $x25 = [math]::Round((Quantile (@($d25s | Sort-Object)) 0.50), 2)
    $x50 = [math]::Round((Quantile (@($d50s | Sort-Object)) 0.50), 2)
    $x75 = [math]::Round((Quantile (@($d75s | Sort-Object)) 0.50), 2)
    if ($x25 -le $x50 -and $x50 -le $x75) {
        $dDefLine = "{ $x25, $x50, $x75 }, -- DERIVED: median of the $($d50s.Count) crawled specs"
    }
}
$dHeader = @"
-- Per-spec tank DAMAGE baselines: { p25, p50, p75 } of a tank's share of
-- the raid's total damage for a fight, crawled from Warcraft Logs
-- (scripts/fetch-tank-mitigation.ps1, same query as the mitigation pass).
--
-- Why this exists (Josh 2026-07-28, measured on 219 real MoP fights): on
-- the SAME fights, the damage metric's median was 59.5 for DPS and 59.8
-- for healers - and 26.0 for tanks. Healers score fine against a damage
-- curve; only tanks collapse. That is the reference population, not the
-- players. The ranked curves are built from tanks who show up in damage
-- rankings, which is a self-selected, damage-pushing slice of the tanks
-- actually playing. Scored against the field of every tank in a log, a
-- median tank lands on a median score, which is what the number means.
--
-- SHARE of raid damage rather than DPS: it pools across encounters,
-- brackets and gear, so one anchor per spec holds everywhere instead of
-- needing a curve per boss. A spec too rare to crawl falls back to
-- `default`, itself the median of the crawled specs.
local _, TP = ...

TP.TANK_DAMAGE_ANCHORS = {
	default = $dDefLine
$($dLines -join "`n")
}
"@
$dOut = if ([System.IO.Path]::IsPathRooted($OutDamageFile)) { $OutDamageFile } else { Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutDamageFile" }
[System.IO.File]::WriteAllText($dOut, $dHeader, $utf8Bom)
Write-Host ("Wrote {0} ({1} specs)" -f $dOut, $dLines.Count)
