# Consolidated WCL report-table harvester (Josh 2026-07-25). The three
# report-table crawlers (spellprofiles=Casts, overheal=Healing,
# damageprofiles=DamageTaken) all did the SAME expensive work: discover
# ranked reports, then pull ONE table per report. WCL returns multiple
# aliased tables in a single query (verified), so this discovers reports
# ONCE (walking every boss - damage-taken is per-boss, unlike the old
# 3-boss cast sample) and harvests all three tables per report at once,
# emitting SpellProfiles + Overheal + DamageProfiles together. Supersedes
# fetch-spellprofiles.ps1 + fetch-overheal.ps1: one crawl, one token
# session, one CI slice.
# NEVER run while another WCL crawl is active (single-active tokens).
#  MoP:    -GameBase https://classic.warcraftlogs.com -ZoneId 1054 -Brackets "3x10,3x25" -Suffix _Mists
#  Retail: -GameBase https://www.warcraftlogs.com     -ZoneId 46   -Brackets "5,4"       -Suffix ""
param(
    [string]$GameBase = "https://classic.warcraftlogs.com",
    [int]$ZoneId = 1054,
    [string]$Brackets = "3x10,3x25",
    [int]$MaxTables = 150,     # report fetches per run (points budget)
    [int]$MinPlayers = 8,      # spell-profile: specs with fewer samples omitted
    [int]$MinSamples = 40,     # overheal: specs with fewer samples omitted
    [int]$MinDmgPlayers = 30,  # damage-profile: encounters with fewer player-fights omitted
    [int]$MinTakers = 5,       # damage-profile: drop abilities this few players took (noise)
    [int]$MaxSpells = 6,
    # Output paths. CI passes rooted absolute paths; a bare name lands in
    # the repo Data dir. Suffix builds the default trio (_Mists / "").
    [string]$Suffix = "_Mists",
    [string]$OutSpell = "",
    [string]$OutOverheal = "",
    [string]$OutDamage = "",
    [string]$OutActivity = "",
    [int]$MinActPlayers = 12,  # activity-profile: encounters with fewer player-fights omitted
    [string]$ClientFile = "$PSScriptRoot\wcl-v2-client.local.txt"
)
$ErrorActionPreference = "Stop"
if ($OutSpell -eq "") { $OutSpell = "SpellProfiles$Suffix.lua" }
if ($OutOverheal -eq "") { $OutOverheal = "Overheal$Suffix.lua" }
if ($OutDamage -eq "") { $OutDamage = "DamageProfiles$Suffix.lua" }
if ($OutActivity -eq "") { $OutActivity = "ActivityProfiles$Suffix.lua" }

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
            if ($resp.errors) { throw ("GraphQL: " + ($resp.errors | ConvertTo-Json -Compress)) }
            Start-Sleep -Milliseconds 350
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

# icon "Class-Spec" -> global specID. Full set (classic + retail): the
# Casts table serves the whole raid, so every spec profiles for free.
$specByIcon = @{
    "Mage-Arcane" = 62; "Mage-Fire" = 63; "Mage-Frost" = 64
    "Paladin-Holy" = 65; "Paladin-Protection" = 66; "Paladin-Retribution" = 70
    "Warrior-Arms" = 71; "Warrior-Fury" = 72; "Warrior-Protection" = 73
    "Druid-Balance" = 102; "Druid-Feral" = 103; "Druid-Guardian" = 104; "Druid-Restoration" = 105
    "DeathKnight-Blood" = 250; "DeathKnight-Frost" = 251; "DeathKnight-Unholy" = 252
    "Hunter-BeastMastery" = 253; "Hunter-Marksmanship" = 254; "Hunter-Survival" = 255
    "Priest-Discipline" = 256; "Priest-Holy" = 257; "Priest-Shadow" = 258
    "Rogue-Assassination" = 259; "Rogue-Combat" = 260; "Rogue-Outlaw" = 260; "Rogue-Subtlety" = 261
    "Shaman-Elemental" = 262; "Shaman-Enhancement" = 263; "Shaman-Restoration" = 264
    "Warlock-Affliction" = 265; "Warlock-Demonology" = 266; "Warlock-Destruction" = 267
    "Monk-Brewmaster" = 268; "Monk-Windwalker" = 269; "Monk-Mistweaver" = 270
    "DemonHunter-Havoc" = 577; "DemonHunter-Vengeance" = 581
    "Evoker-Devastation" = 1467; "Evoker-Preservation" = 1468; "Evoker-Augmentation" = 1473
}
# healer specs (overheal harvest only)
$healerSpecs = @{ 105 = $true; 270 = $true; 65 = $true; 256 = $true; 257 = $true; 264 = $true; 1468 = $true }
# tank specs (damage-profile tankOnly detection)
$tankSpecs = @{ 250 = $true; 73 = $true; 66 = $true; 104 = $true; 268 = $true; 581 = $true }

# spread reports across DPS + healer top pages so every spec is well
# represented (casts) and the population is mixed (overheal/damage)
$rankSpecs = @(
    @{ class = "Druid"; spec = "Restoration"; metric = "hps" }
    @{ class = "Shaman"; spec = "Restoration"; metric = "hps" }
    @{ class = "Paladin"; spec = "Holy"; metric = "hps" }
    @{ class = "Priest"; spec = "Discipline"; metric = "hps" }
    @{ class = "Monk"; spec = "Mistweaver"; metric = "hps" }
    @{ class = "Mage"; spec = "Frost"; metric = "dps" }
    @{ class = "Hunter"; spec = "BeastMastery"; metric = "dps" }
    @{ class = "Warlock"; spec = "Demonology"; metric = "dps" }
    @{ class = "Rogue"; spec = "Assassination"; metric = "dps" }
    @{ class = "DeathKnight"; spec = "Unholy"; metric = "dps" }
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

# ---- phase 1: discover report refs per encounter (all bosses) ----
# refsByEnc[encName] = ArrayList of @{ code; fight; durMin; encId; encName }
$refsByEnc = @{}
$seen = @{}
$perEncCap = [int][math]::Ceiling($MaxTables / [math]::Max(1, $zone.encounters.Count) * 3)
foreach ($enc in $zone.encounters) {
    Assert-Points
    $bag = New-Object System.Collections.ArrayList
    $refsByEnc[$enc.name] = $bag
    foreach ($extra in $bracketList) {
        foreach ($rs in $rankSpecs) {
            if ($bag.Count -ge $perEncCap) { break }
            # pages 1/4/10 = top, upper-mid, mid-pack: page 1 anchors the
            # cast/damage "what competent raids do" signal, deeper pages
            # give overheal its population spread (thin specs 404 deeper -
            # skipped). Matches the old dedicated overheal crawler.
            foreach ($page in @(1, 4, 10)) {
                $q = "{ worldData { encounter(id: $($enc.id)) { characterRankings(metric: $($rs.metric), page: $page, className: `"$($rs.class)`", specName: `"$($rs.spec)`"$extra) } } }"
                $cr = $null
                try { $cr = (Invoke-GQL $q).worldData.encounter.characterRankings } catch { continue }
                if ($cr -is [string]) { $cr = $cr | ConvertFrom-Json }
                if (-not ($cr -and $cr.rankings)) { continue }
                foreach ($r in ($cr.rankings | Select-Object -First 3)) {
                    if (-not ($r.report -and $r.report.code -and $r.duration)) { continue }
                    $key = "$($r.report.code)#$($r.report.fightID)"
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        [void]$bag.Add(@{ code = $r.report.code; fight = [int]$r.report.fightID
                            durMin = [double]$r.duration / 60000.0; encId = [int]$enc.id; encName = $enc.name })
                    }
                }
            }
        }
    }
    Write-Host ("  {0}: {1} refs" -f $enc.name, $bag.Count)
}

# ---- phase 2: round-robin per encounter so every boss gets tables;
# ONE multi-table query per ref harvests Casts + Healing + DamageTaken ----
$spellSamples = @{}  # specID -> list of @{ durMin; activePct; casts; names }
$overSamples = @{}   # specID -> ArrayList of overheal %
$dmg = @{}           # encName -> @{ id; playerN; ab = @{ name -> @{ takers; total; tankT; nonTankT; guid } } }
$actByEnc = @{}      # encName -> ArrayList of activity %
$actAll = New-Object System.Collections.ArrayList  # every activity sample, for the reference median
$cursor = @{}
foreach ($k in $refsByEnc.Keys) { $cursor[$k] = 0 }
$encOrder = @($zone.encounters | ForEach-Object { $_.name })
$fetched = 0
$round = 0
while ($fetched -lt $MaxTables) {
    $any = $false
    foreach ($encName in $encOrder) {
        if ($fetched -ge $MaxTables) { break }
        $bag = $refsByEnc[$encName]
        $idx = $cursor[$encName]
        if ($idx -ge $bag.Count) { continue }
        $cursor[$encName] = $idx + 1
        $any = $true
        $ref = $bag[$idx]
        Assert-Points
        $q = "{ reportData { report(code: `"$($ref.code)`") { casts: table(fightIDs: [$($ref.fight)], dataType: Casts) healing: table(fightIDs: [$($ref.fight)], dataType: Healing) damageTaken: table(fightIDs: [$($ref.fight)], dataType: DamageTaken) } } }"
        $rep = $null
        try { $rep = (Invoke-GQL $q).reportData.report } catch { continue }
        $fetched++

        # --- Casts -> spell profiles ---
        $ce = $null
        if ($rep.casts -and $rep.casts.data -and $rep.casts.data.entries) { $ce = $rep.casts.data.entries }
        elseif ($rep.casts -and $rep.casts.entries) { $ce = $rep.casts.entries }
        foreach ($e in ($ce | Where-Object { $_.icon })) {
            $sid = $specByIcon[[string]$e.icon]
            if (-not $sid) { continue }
            $casts = @{}; $names = @{}
            foreach ($ab in ($e.abilities | Where-Object { $_.guid -gt 1 -and $_.guid -ne 75 -and $_.guid -ne 5019 -and $_.name -notmatch "!" })) {
                $casts[[int]$ab.guid] = [int]$ab.total; $names[[int]$ab.guid] = [string]$ab.name
            }
            if ($casts.Count -eq 0) { continue }
            $activePct = $null
            if ($e.activeTime -and $ref.durMin -gt 0) {
                $activePct = [math]::Round(($e.activeTime / 1000.0) / ($ref.durMin * 60.0) * 100.0, 1)
                if ($activePct -gt 100) { $activePct = 100 }
            }
            if (-not $spellSamples.ContainsKey($sid)) { $spellSamples[$sid] = New-Object System.Collections.ArrayList }
            [void]$spellSamples[$sid].Add(@{ durMin = $ref.durMin; activePct = $activePct; casts = $casts; names = $names })
            # Per-ENCOUNTER activity: the per-spec pool above averages every
            # boss together, so a fight with forced downtime (Immerseus
            # submerging, Galakras towers) is judged against a pooled
            # anchor it can never reach. Bucket the same samples by boss.
            if ($null -ne $activePct) {
                if (-not $actByEnc.ContainsKey($encName)) { $actByEnc[$encName] = New-Object System.Collections.ArrayList }
                [void]$actByEnc[$encName].Add([double]$activePct)
                [void]$actAll.Add([double]$activePct)
            }
        }

        # --- Healing -> overheal ---
        $he = $null
        if ($rep.healing -and $rep.healing.data -and $rep.healing.data.entries) { $he = $rep.healing.data.entries }
        elseif ($rep.healing -and $rep.healing.entries) { $he = $rep.healing.entries }
        foreach ($e in ($he | Where-Object { $_.icon })) {
            $sid = $specByIcon[[string]$e.icon]
            if (-not ($sid -and $healerSpecs[$sid])) { continue }
            $eff = [double]($e.total); $over = 0.0
            if ($null -ne $e.overheal) { $over = [double]$e.overheal }
            $raw = $eff + $over
            if ($raw -lt 100000) { continue }
            if (-not $overSamples.ContainsKey($sid)) { $overSamples[$sid] = New-Object System.Collections.ArrayList }
            [void]$overSamples[$sid].Add([math]::Round($over / $raw * 100, 1))
        }

        # --- DamageTaken -> per-encounter ability profiles ---
        $de = $null
        if ($rep.damageTaken -and $rep.damageTaken.data -and $rep.damageTaken.data.entries) { $de = $rep.damageTaken.data.entries }
        elseif ($rep.damageTaken -and $rep.damageTaken.entries) { $de = $rep.damageTaken.entries }
        if ($de) {
            if (-not $dmg.ContainsKey($encName)) { $dmg[$encName] = @{ id = $ref.encId; playerN = 0; ab = @{} } }
            $D = $dmg[$encName]
            foreach ($e in $de) {
                $D.playerN += 1
                $isTank = $false
                if ($e.icon) { $sid = $specByIcon[[string]$e.icon]; if ($sid -and $tankSpecs[$sid]) { $isTank = $true } }
                # count each ability at most ONCE per player-fight for the
                # taker/tank counters (WCL can split one ability across rows
                # by damage type - that inflated hitRate past 1.0); total
                # still sums every row.
                $seenAb = @{}
                foreach ($ab in $e.abilities) {
                    $nm = [string]$ab.name
                    if (-not $D.ab.ContainsKey($nm)) { $D.ab[$nm] = @{ takers = 0; total = 0.0; tankT = 0; nonTankT = 0; guid = [int]$ab.guid } }
                    $A = $D.ab[$nm]
                    $A.total += [double]$ab.total
                    if (-not $seenAb.ContainsKey($nm)) {
                        $seenAb[$nm] = $true
                        $A.takers += 1
                        if ($isTank) { $A.tankT += 1 } else { $A.nonTankT += 1 }
                    }
                }
            }
        }
    }
    $round++
    if (-not $any) { break }
}
Write-Host ("Tables fetched: {0}; total HTTP requests: {1}" -f $fetched, $script:requestCount)

function Median($list) {
    $s = @($list | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    return $s[[int][math]::Floor(($s.Count - 1) / 2)]
}
function Quantile($sorted, $q) {
    $idx = [math]::Min($sorted.Count - 1, [math]::Max(0, [int]([math]::Round(($sorted.Count - 1) * $q))))
    return $sorted[$idx]
}
function Write-Lua($outFile, $lines) {
    $outPath = if ([System.IO.Path]::IsPathRooted($outFile)) { $outFile }
        else { Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path "Data" $outFile) }
    [System.IO.File]::WriteAllLines($outPath, $lines)
    Write-Host "Wrote $outPath"
}
$today = Get-Date -Format "yyyy-MM-dd"

# ---- emit 1: SpellProfiles ----
$L = New-Object System.Collections.ArrayList
function E1($s) { [void]$script:L.Add($s) }
E1 "-- GENERATED by scripts\fetch-report-tables.ps1 - do not edit by hand."
E1 "-- Per-spec top-player habits from WCL Casts tables: median casts-per-"
E1 "-- minute of each spec's signature spells, and median activity%."
E1 ("-- Generated {0} - {1}." -f $today, $zone.name)
E1 "local _, TP = ..."
E1 ""
E1 "TP.SpellProfiles = TP.SpellProfiles or {}"
foreach ($sid in ($spellSamples.Keys | Sort-Object)) {
    $list = $spellSamples[$sid]
    if ($list.Count -lt $MinPlayers) { Write-Host ("  spell spec {0}: only {1}; omitted" -f $sid, $list.Count); continue }
    $byName = @{}
    foreach ($smp in $list) {
        $perName = @{}
        foreach ($spellID in $smp.casts.Keys) {
            $nm = $smp.names[$spellID]
            if (-not $perName.ContainsKey($nm)) { $perName[$nm] = @{ n = 0; ids = @{} } }
            $perName[$nm].n += $smp.casts[$spellID]; $perName[$nm].ids[$spellID] = $true
        }
        foreach ($nm in $perName.Keys) {
            if (-not $byName.ContainsKey($nm)) { $byName[$nm] = @{ cpms = (New-Object System.Collections.ArrayList); ids = @{} } }
            [void]$byName[$nm].cpms.Add($perName[$nm].n / $smp.durMin)
            foreach ($spellID in $perName[$nm].ids.Keys) { $byName[$nm].ids[$spellID] = $true }
        }
    }
    $sigs = @()
    foreach ($nm in $byName.Keys) {
        $rec = $byName[$nm]; $usage = $rec.cpms.Count / $list.Count; $med = Median $rec.cpms
        if ($usage -ge 0.6 -and $med -ge 0.5) { $sigs += @{ name = $nm; ids = @($rec.ids.Keys | Sort-Object); cpm = [math]::Round($med, 1) } }
    }
    $sigs = @($sigs | Sort-Object -Property cpm -Descending | Select-Object -First $MaxSpells)
    $actMed = Median @($list | Where-Object { $null -ne $_.activePct } | ForEach-Object { $_.activePct })
    $parts = @()
    foreach ($sg in $sigs) {
        $idList = ($sg.ids | ForEach-Object { "$_" }) -join ", "
        $parts += ("{{ ids = {{ {0} }}, name = `"{1}`", cpm = {2} }}" -f $idList, ($sg.name -replace '"', '\"'), $sg.cpm)
    }
    E1 ("TP.SpellProfiles[{0}] = {{ n = {1}, activity = {2}, spells = {{ {3} }} }}" -f `
        $sid, $list.Count, ($(if ($null -ne $actMed) { $actMed } else { "nil" })), ($parts -join ", "))
}
Write-Lua $OutSpell $L

# ---- emit 2: Overheal ----
$L = New-Object System.Collections.ArrayList
E1 "-- GENERATED by scripts\fetch-report-tables.ps1 - do not edit by hand."
E1 "-- Per-spec overheal%% quantiles from WCL Healing tables. The engine's"
E1 "-- overheal adjustment: above p90 = -2, above p75 = -1, below p25 = +1."
E1 ("-- Generated {0} - {1}." -f $today, $zone.name)
E1 "local _, TP = ..."
E1 ""
E1 "TP.OverhealCurves = TP.OverhealCurves or {}"
foreach ($sid in ($overSamples.Keys | Sort-Object)) {
    $list = $overSamples[$sid]
    if ($list.Count -lt $MinSamples) { Write-Host ("  overheal spec {0}: only {1}; omitted" -f $sid, $list.Count); continue }
    $sorted = @($list | Sort-Object)
    E1 ("TP.OverhealCurves[{0}] = {{ p25 = {1}, p75 = {2}, p90 = {3}, n = {4} }}" -f `
        $sid, (Quantile $sorted 0.25), (Quantile $sorted 0.75), (Quantile $sorted 0.90), $list.Count)
}
Write-Lua $OutOverheal $L

# ---- emit 3: DamageProfiles (per encounter, per ability) ----
$L = New-Object System.Collections.ArrayList
E1 "-- GENERATED by scripts\fetch-report-tables.ps1 - do not edit by hand."
E1 "-- Per-encounter damage-taken ability profiles from WCL DamageTaken"
E1 "-- tables. hitRate = fraction of sampled player-fights that took the"
E1 "-- ability (LOW = avoidable, good players dodge it); tankOnly = only"
E1 "-- tanks took it; share = fraction of all damage taken; avgDmg = a"
E1 "-- taker's typical damage from it (per-taker, not per-hit - the table"
E1 "-- has no hit counts). Feeds DeathCause (why a player died) and mechanic"
E1 "-- coaching (names + impact of the avoidable ability a player ate)."
E1 ("-- Generated {0} - {1}." -f $today, $zone.name)
E1 "local _, TP = ..."
E1 ""
E1 "TP.DAMAGE_PROFILES = TP.DAMAGE_PROFILES or {}"
E1 "TP.DAMAGE_PROFILES.ids = TP.DAMAGE_PROFILES.ids or {}"
E1 "local E = TP.DAMAGE_PROFILES"
foreach ($encName in ($dmg.Keys | Sort-Object)) {
    $D = $dmg[$encName]
    if ($D.playerN -lt $MinDmgPlayers) { Write-Host ("  dmg {0}: only {1} player-fights; omitted" -f $encName, $D.playerN); continue }
    $enckey = ($encName -replace '"', '\"')
    $allTotal = 0.0
    foreach ($nm in $D.ab.Keys) { $allTotal += $D.ab[$nm].total }
    if ($allTotal -le 0) { continue }
    E1 ("E[`"{0}`"] = E[`"{0}`"] or {{}}" -f $enckey)
    foreach ($nm in ($D.ab.Keys | Sort-Object)) {
        $A = $D.ab[$nm]
        if ($A.takers -lt $MinTakers) { continue }
        $hitRate = [math]::Round($A.takers / $D.playerN, 3)
        $tankOnly = ($A.nonTankT -eq 0 -and $A.tankT -ge 2)
        $share = [math]::Round($A.total / $allTotal, 3)
        # avgDmg = a taker's typical damage from this ability (impact context
        # for mechanic coaching: "hit you for ~240k"). The table has no hit
        # counts, so it's per-TAKER, not per-hit.
        $avgDmg = [int][math]::Round($A.total / $A.takers)
        E1 ("E[`"{0}`"][`"{1}`"] = {{ hitRate = {2}, tankOnly = {3}, share = {4}, avgDmg = {5}, guid = {6}, n = {7} }}" -f `
            $enckey, ($nm -replace '"', '\"'), $hitRate, ($(if ($tankOnly) { "true" } else { "false" })), $share, $avgDmg, $A.guid, $D.playerN)
    }
    E1 ("E.ids[{0}] = `"{1}`"" -f $D.id, $enckey)
}
Write-Lua $OutDamage $L

# ---- emit 4: ActivityProfiles (per-encounter expected activity) ----
$L = New-Object System.Collections.ArrayList
$refMed = Median $actAll
E1 "-- GENERATED by scripts/fetch-report-tables.ps1 - do not edit by hand."
E1 "-- Per-ENCOUNTER activity% from WCL Casts tables (activeTime / fight"
E1 "-- duration), pooled across specs. The per-spec anchor in SpellProfiles"
E1 "-- averages every boss together, so fights with forced downtime score"
E1 "-- as bad play - this carries each boss's own expected activity so the"
E1 "-- anchor can shift to match what the fight actually allows."
E1 "-- factor = this encounter's median / the median across all encounters."
E1 ("-- Generated {0} - {1}. Reference median: {2}%." -f $today, $zone.name, $refMed)
E1 "local _, TP = ..."
E1 ""
E1 "TP.ActivityProfiles = TP.ActivityProfiles or {}"
if ($null -ne $refMed -and $refMed -gt 0) {
    E1 ("TP.ActivityProfiles.reference = {0}" -f $refMed)
    foreach ($encName in ($actByEnc.Keys | Sort-Object)) {
        $list = $actByEnc[$encName]
        if ($list.Count -lt $MinActPlayers) { Write-Host ("  activity {0}: only {1}; omitted" -f $encName, $list.Count); continue }
        $sorted = @($list | Sort-Object)
        $med = Median $list
        $factor = [math]::Round($med / $refMed, 3)
        $enckey = ($encName -replace '"', '\"')
        E1 ("TP.ActivityProfiles[`"{0}`"] = {{ n = {1}, p50 = {2}, factor = {3} }}" -f `
            $enckey, $list.Count, $med, $factor)
        Write-Host ("  activity {0}: n={1} p50={2} factor={3}" -f $encName, $list.Count, $med, $factor)
    }
} else {
    Write-Host "  activity: no samples; nothing emitted"
}
Write-Lua $OutActivity $L
Write-Host "Done."
