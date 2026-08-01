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
    [string]$OutCoverageFile = "HealerCoverage.lua",
    [string]$ClientFile = "$PSScriptRoot\wcl-v2-client.local.txt"
)
$ErrorActionPreference = "Stop"

# mitigation-buff id sets mirror Data/Mitigation*.lua (buff ids, not casts)
$mitSets = @{
    mists  = @(115307, 132404, 112048, 132403, 132402, 77535, 115295, 123402, 115308, 65148)
    # Brewmaster = 215479 SHUFFLE (2026-07-30), matching the generator casts
    # Data/Mitigation.lua now estimates it from (Keg Smash 5s, Blackout Kick
    # 3s - tooltip durations, ids verified against a real log). An anchor has
    # to measure the same button the collector estimates, and Celestial Brew
    # (322507) failed that both ways: ranked Brewmasters don't talent it, so
    # it crawled 1 sample from 66 real Brewmasters, and the few who did take
    # it read ~20% against a ~90% default. Shuffle sits near-permanently on a
    # good Brewmaster, which is exactly what a Shuffle-based collector will
    # report - the two scales agree, which is the whole requirement.
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
# Healer specs, for the coverage pass below. Retail ids; the Mists ids that
# differ are folded in by the same icon strings, which WCL keeps stable.
$healerByIcon = @{
    "Paladin-Holy" = 65; "Priest-Discipline" = 256; "Priest-Holy" = 257
    "Shaman-Restoration" = 264; "Druid-Restoration" = 105; "Monk-Mistweaver" = 270
    "Evoker-Preservation" = 1468
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
# Bands are [pscustomobject]{ s; e }, NOT @(s, e) pairs. With a pair, a
# one-element list flattens on the way through Sort-Object - PowerShell
# unrolls arrays in the pipeline, so $sorted[0][0] reads the START TIME
# instead of the first band and $curE lands on $null. The function then
# returns a NEGATIVE total, which the caller discards as "$up -le 0".
# That silently dropped every tank WCL reported as one continuous band -
# i.e. exactly the tanks with the best uptime. Prot Paladin kept 14 of ~49
# samples and Brewmaster 1 of ~71, both then falling back to a cross-spec
# default (Josh 2026-07-29: "tanks mitigation isnt showing up").
function Merge-Uptime($bands) {
    $sorted = @($bands | Sort-Object -Property s)
    if ($sorted.Count -eq 0) { return 0 }
    $total = 0.0; $curS = $sorted[0].s; $curE = $sorted[0].e
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $s = $sorted[$i].s; $e = $sorted[$i].e
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
# Healer INTAKE COVERAGE rides along too. Scoring a healer on HPS pays them
# for the group standing in things: measured on 21 real M+ fights,
# correlation(group intake/s, healer percentile) = +0.44, and intake above
# 65k/s lifted the median healer percentile from 68 to 87 (2026-07-31).
# Healing divided by the group's damage TAKEN is immune to that - double the
# intake and the healer heals double, so the ratio holds - and it still
# discriminates: 0.36 to 0.84 across those fights, a 2.3x spread.
# Aliases ride in one request, so these two tables cost no extra round trip.
$aliases += "hd: table(fightIDs: [FIGHT], dataType: Healing)"
$aliases += "dt: table(fightIDs: [FIGHT], dataType: DamageTaken)"
$samples = @{}  # specID -> ArrayList of uptime%
$dmgSamples = @{}  # specID -> ArrayList of tank damage as a multiple of group mean
$covSamples = @{}  # specID -> ArrayList of healer healing / group damage taken
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
            foreach ($b in $a.bands) { [void]$byPlayer[$a.guid].bands.Add([pscustomobject]@{ s = [double]$b.startTime; e = [double]$b.endTime }) }
        }
    }
    if ($totalTime -le 0) { continue }
    foreach ($guid in $byPlayer.Keys) {
        $pl = $byPlayer[$guid]
        $up = (Merge-Uptime $pl.bands) / $totalTime * 100.0
        if ($up -le 0) { continue }
        # a band may run a tick past the fight boundary; clamp rather than
        # discard, or the highest-uptime tanks drop out of their own anchor
        if ($up -gt 100) { $up = 100.0 }
        if (-not $samples.ContainsKey($pl.specID)) { $samples[$pl.specID] = New-Object System.Collections.ArrayList }
        [void]$samples[$pl.specID].Add($up)
    }

    # --- tank share of raid damage, same fight, same query ---
    $dd = $rep.dd
    if ($dd -is [string]) { $dd = $dd | ConvertFrom-Json }
    if ($dd -and $dd.data -and $dd.data.entries) {
        $raidTotal = 0.0
        foreach ($e in $dd.data.entries) { $raidTotal += [double]$e.total }
        # Sample the tank's damage as a MULTIPLE OF THE GROUP'S PER-PLAYER
        # MEAN, not as a share of the raid total. Share is arithmetically
        # inversely proportional to raid size, so a single anchor cannot hold
        # across sizes - and this crawl deliberately pools them (retail
        # brackets are flexible 10-30; MoP pools 3x10 and 3x25). Measured on
        # real captures 2026-07-31: 10-man tanks median 6.62% share vs 21-30
        # man 2.85%, a 2.3x gap that made 65 of 69 ten-man tank-fights exceed
        # their own p75 and auto-score 100, while 25-man tanks fell below p25.
        # Normalised, those two populations agree within 7% (0.662 vs 0.713).
        $groupN = $dd.data.entries.Count
        if ($raidTotal -gt 0 -and $groupN -ge 5) {
            $mean = $raidTotal / $groupN
            foreach ($e in $dd.data.entries) {
                $spec = $specByIcon[$e.icon]
                if (-not $spec) { continue }
                $mult = [double]$e.total / $mean
                # a tank at 0 did not participate; above 5x the group mean is
                # not a tank sample, it is a mislabelled row
                if ($mult -le 0 -or $mult -gt 5) { continue }
                if (-not $dmgSamples.ContainsKey($spec)) { $dmgSamples[$spec] = New-Object System.Collections.ArrayList }
                [void]$dmgSamples[$spec].Add($mult)
            }
        }
    }
    # --- healer intake coverage, same fight, same request ---
    $hd = $rep.hd
    $dt = $rep.dt
    if ($hd -is [string]) { $hd = $hd | ConvertFrom-Json }
    if ($dt -is [string]) { $dt = $dt | ConvertFrom-Json }
    if ($hd -and $hd.data -and $hd.data.entries -and $dt -and $dt.data -and $dt.data.entries) {
        $intake = 0.0
        foreach ($e in $dt.data.entries) { $intake += [double]$e.total }
        # Count the healers first: raw coverage is split among them, so it
        # falls as the roster adds healers - the SAME defect as scoring a tank
        # on share of raid damage. Measured on Josh's MoP raids, median
        # coverage was 0.326 with two healers and 0.241 with three; multiplying
        # by the count gives 0.652 and 0.723, and a solo M+ healer 0.680. A
        # 2.82x spread across those three collapses to 1.11x. So the quantity
        # is coverage x healerN: "your share of the group's intake, against a
        # fair share among the healers". That is what makes one anchor hold
        # for five-mans and raids alike instead of needing separate tables.
        $healerN = 0
        $selfHeal = 0.0
        foreach ($e in $hd.data.entries) {
            if ($healerByIcon[$e.icon]) { $healerN++ } else { $selfHeal += [double]$e.total }
        }
        # Take the SELF-HEALING out of the denominator (Josh 2026-07-31). A
        # healer only gets to cover what nobody else covered, so raw coverage
        # mostly measured the group: on 21 real M+ fights it correlated -0.76
        # with the non-healer healing share, i.e. 58% of its variance was
        # composition rather than the healer. A Blood DK tank alone can move
        # it. Dividing by the intake that was actually left to heal drops
        # that to +0.13 - 2% - while keeping a 1.70x spread of real signal.
        $healable = $intake - $selfHeal
        if ($healable -lt $intake * 0.15) { $healable = $intake * 0.15 } # guard
        if ($healable -gt 0 -and $healerN -gt 0) {
            foreach ($e in $hd.data.entries) {
                $spec = $healerByIcon[$e.icon]
                if (-not $spec) { continue }
                $cov = [double]$e.total / $healable * $healerN
                # 1.0 is a FAIR SHARE now, not the whole intake, so 2.0 is
                # just a healer carrying double - a real sample and the top of
                # the distribution this anchor exists to measure. Only clip
                # what cannot be a healer at all.
                if ($cov -le 0 -or $cov -gt 4) { continue }
                if (-not $covSamples.ContainsKey($spec)) { $covSamples[$spec] = New-Object System.Collections.ArrayList }
                [void]$covSamples[$spec].Add($cov)
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
-- Per-spec tank DAMAGE baselines: { p25, p50, p75 } of a tank's damage as a
-- MULTIPLE OF THE GROUP'S PER-PLAYER MEAN, crawled from Warcraft Logs
-- (scripts/fetch-tank-mitigation.ps1, same query as the mitigation pass).
-- Read 0.78 as "this tank did 0.78x what the average raider did".
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
-- MULTIPLE OF THE GROUP MEAN rather than DPS: it pools across encounters,
-- brackets and gear, so one anchor per spec holds everywhere instead of
-- needing a curve per boss. A spec too rare to crawl falls back to
-- `default`, itself the median of the crawled specs.
--
-- It used to be a SHARE of raid damage (%), and that was WRONG: share is
-- inversely proportional to raid size, so one anchor could not cover the
-- sizes this crawl deliberately pools. Measured on real captures
-- 2026-07-31, 10-man tanks sat at a 6.62% median share against 2.85% for
-- 21-30 man - so 65 of 69 ten-man tank-fights cleared their own p75 and
-- auto-scored 100, while 25-man tanks fell below p25 for median play.
-- Normalising by group size collapses that 2.3x gap to 7% (0.662 vs 0.713).
-- TANK_DAMAGE_ANCHOR_UNIT exists so the engine can refuse to score against
-- a stale share-based file rather than silently mixing the two.
local _, TP = ...

TP.TANK_DAMAGE_ANCHOR_UNIT = "mean-multiple"

TP.TANK_DAMAGE_ANCHORS = {
	default = $dDefLine
$($dLines -join "`n")
}
"@
$dOut = if ([System.IO.Path]::IsPathRooted($OutDamageFile)) { $OutDamageFile } else { Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutDamageFile" }
[System.IO.File]::WriteAllText($dOut, $dHeader, $utf8Bom)
Write-Host ("Wrote {0} ({1} specs)" -f $dOut, $dLines.Count)

# ---- healer intake coverage ------------------------------------------------
$cLines = New-Object System.Collections.ArrayList
$c25s = New-Object System.Collections.ArrayList
$c50s = New-Object System.Collections.ArrayList
$c75s = New-Object System.Collections.ArrayList
$healNames = @{ 65 = "Holy Paladin"; 105 = "Resto Druid"; 256 = "Disc Priest";
    257 = "Holy Priest"; 264 = "Resto Shaman"; 270 = "Mistweaver"; 1468 = "Preservation" }
foreach ($spec in ($covSamples.Keys | Sort-Object)) {
    $arr = @($covSamples[$spec] | Sort-Object)
    if ($arr.Count -lt $MinSamples) { Write-Host ("  cov spec ${spec}: only $($arr.Count) samples (< $MinSamples), skipped"); continue }
    $p25 = [math]::Round((Quantile $arr 0.25), 3)
    $p50 = [math]::Round((Quantile $arr 0.50), 3)
    $p75 = [math]::Round((Quantile $arr 0.75), 3)
    Write-Host ("  cov spec $spec ($($healNames[$spec])): n=$($arr.Count) p25=$p25 p50=$p50 p75=$p75")
    [void]$cLines.Add(("`t[{0}] = {{ {1}, {2}, {3} }}, -- {4} (n={5})" -f $spec, $p25, $p50, $p75, $healNames[$spec], $arr.Count))
    [void]$c25s.Add($p25); [void]$c50s.Add($p50); [void]$c75s.Add($p75)
}
$cDefLine = "nil, -- nothing crawled yet"
if ($c50s.Count -ge 2) {
    $y25 = [math]::Round((Quantile (@($c25s | Sort-Object)) 0.50), 3)
    $y50 = [math]::Round((Quantile (@($c50s | Sort-Object)) 0.50), 3)
    $y75 = [math]::Round((Quantile (@($c75s | Sort-Object)) 0.50), 3)
    if ($y25 -le $y50 -and $y50 -le $y75) {
        $cDefLine = "{ $y25, $y50, $y75 }, -- DERIVED: median of the $($c50s.Count) crawled specs"
    }
}
$cHeader = @"
-- Per-spec healer COVERAGE baselines: { p25, p50, p75 } of a healer's healing
-- divided by the intake that was actually THEIRS TO HEAL - the group's damage
-- taken, less whatever the group healed itself - times the number of healers.
-- Read 0.99 as "this healer covered 99% of a fair share of the damage nobody
-- else picked up".
--
-- Self-healing comes out of the denominator because a healer only gets to
-- cover what nobody else covered. Against raw intake, coverage correlated
-- -0.76 with the non-healer healing share on 21 real M+ fights: 58% of its
-- variance was group composition, not the healer, and a single Blood DK tank
-- could move it. Against healable intake that falls to +0.13, i.e. 2%, while
-- 1.70x of spread survives (Josh spotted this before the crawl ran).
--
-- Times the healer count because raw coverage is divided among the healers,
-- so it falls as the roster adds them: the same defect as scoring a tank on
-- share of raid damage. Josh's MoP raids median 0.326 coverage on two healers
-- and 0.241 on three; normalised those are 0.652 and 0.723, against 0.680 for
-- a solo Mythic+ healer. A 2.82x spread becomes 1.11x, which is why ONE table
-- covers five-mans and raids instead of needing separate ones.
--
-- Why not HPS (Josh 2026-07-31). Healing rate in a 5-man is mostly a function
-- of how much damage the group TAKES, which is mostly avoidable - so scoring a
-- healer on HPS pays them for their group standing in things. Measured on 21
-- real Mythic+ fights: correlation(group intake/s, healer percentile) = +0.44,
-- and intake above 65k/s lifted the median healer percentile from 68 to 87.
-- In the same runs healers medianed 87.9 while damagers medianed 12.3.
--
-- Coverage is immune to that: double the intake and the healer heals roughly
-- double, so the ratio holds. It still discriminates - 0.36 to 0.84 across
-- those same fights, a 2.3x spread - because what varies is how much of the
-- group's damage the HEALER covered rather than the group self-sustaining.
--
-- A spec too rare to crawl falls back to `default`, itself the median of the
-- crawled specs. HEALER_COVERAGE_UNIT lets the engine refuse a file whose
-- units it does not recognise instead of scoring against the wrong scale.
local _, TP = ...

TP.HEALER_COVERAGE_UNIT = "healable-share-x-healers"

TP.HEALER_COVERAGE_ANCHORS = {
	default = $cDefLine
$($cLines -join "`n")
}
"@
$cOut = if ([System.IO.Path]::IsPathRooted($OutCoverageFile)) { $OutCoverageFile } else { Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutCoverageFile" }
[System.IO.File]::WriteAllText($cOut, $cHeader, $utf8Bom)
Write-Host ("Wrote {0} ({1} specs)" -f $cOut, $cLines.Count)
