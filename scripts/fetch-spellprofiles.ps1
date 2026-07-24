# Per-spec "what the best do" profiles from WCL Casts tables. One
# unfiltered Casts table per top-ranked fight returns EVERY player's
# per-spell cast counts + activeTime, so a few dozen tables profile all
# specs at once. Emits, per spec: median casts-per-minute of the spec's
# signature spells among top players, and median activity% - the raw
# material for "top Resto Druids cast Rejuvenation 13x/min, you 6"
# coaching (Josh 2026-07-24). Casts are a deliberate v1 proxy for
# uptime (Lifebloom CPM tracks refresh cadence); true target-aura
# uptime needs per-player filtered queries and can come later.
# NEVER run while another WCL crawl is active (single-active tokens).
param(
    [string]$GameBase = "https://classic.warcraftlogs.com",
    [int]$ZoneId = 1054,
    [string]$Brackets = "3x10,3x25",
    [int]$MaxTables = 60,
    [int]$MinPlayers = 8,    # specs with fewer sampled players are omitted
    [int]$MaxSpells = 6,
    [string]$OutFile = "SpellProfiles_Mists.lua",
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

# icon "Class-Spec" -> global specID (all specs: the Casts table serves
# the whole raid, so every spec profiles for free)
$specByIcon = @{
    "Mage-Arcane" = 62; "Mage-Fire" = 63; "Mage-Frost" = 64
    "Paladin-Holy" = 65; "Paladin-Protection" = 66; "Paladin-Retribution" = 70
    "Warrior-Arms" = 71; "Warrior-Fury" = 72; "Warrior-Protection" = 73
    "Druid-Balance" = 102; "Druid-Feral" = 103; "Druid-Guardian" = 104; "Druid-Restoration" = 105
    "DeathKnight-Blood" = 250; "DeathKnight-Frost" = 251; "DeathKnight-Unholy" = 252
    "Hunter-BeastMastery" = 253; "Hunter-Marksmanship" = 254; "Hunter-Survival" = 255
    "Priest-Discipline" = 256; "Priest-Holy" = 257; "Priest-Shadow" = 258
    "Rogue-Assassination" = 259; "Rogue-Combat" = 260; "Rogue-Subtlety" = 261
    "Shaman-Elemental" = 262; "Shaman-Enhancement" = 263; "Shaman-Restoration" = 264
    "Warlock-Affliction" = 265; "Warlock-Demonology" = 266; "Warlock-Destruction" = 267
    "Monk-Brewmaster" = 268; "Monk-Windwalker" = 269; "Monk-Mistweaver" = 270
}
# spread the sampled reports across several specs' TOP pages so every
# spec's true top players are represented (a top resto raid's mage is
# good, but the mage page's top raids are better mages)
$rankSpecs = @(
    @{ class = "Druid"; spec = "Restoration"; metric = "hps" }
    @{ class = "Shaman"; spec = "Restoration"; metric = "hps" }
    @{ class = "Monk"; spec = "Mistweaver"; metric = "hps" }
    @{ class = "Paladin"; spec = "Holy"; metric = "hps" }
    @{ class = "Priest"; spec = "Discipline"; metric = "hps" }
    @{ class = "Mage"; spec = "Frost"; metric = "dps" }
    @{ class = "Hunter"; spec = "BeastMastery"; metric = "dps" }
    @{ class = "Warlock"; spec = "Demonology"; metric = "dps" }
    @{ class = "Rogue"; spec = "Assassination"; metric = "dps" }
    @{ class = "DeathKnight"; spec = "Unholy"; metric = "dps" }
)

$bracketArgsList = @()
foreach ($b in ($Brackets -split ",")) {
    $b = $b.Trim()
    if ($b -match "^(\d+)x(\d+)$") {
        $bracketArgsList += (", difficulty: {0}, size: {1}" -f [int]$Matches[1], [int]$Matches[2])
    } elseif ($b -ne "") {
        $bracketArgsList += (", difficulty: {0}" -f [int]$b)
    }
}
if ($bracketArgsList.Count -eq 0) { $bracketArgsList = @("") }

$zone = (Invoke-GQL "{ worldData { zone(id: $ZoneId) { name encounters { id name } } } }").worldData.zone
Write-Host ("Zone: {0} ({1} encounters)" -f $zone.name, $zone.encounters.Count)
# 3 spread-out bosses are enough: cast profiles are spec-level habits
$bosses = @($zone.encounters[1], $zone.encounters[[int]($zone.encounters.Count / 2)], $zone.encounters[$zone.encounters.Count - 2])

# phase 1: top report refs (page 1 = the best), with their durations
$refs = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($enc in $bosses) {
    Assert-Points
    foreach ($extra in $bracketArgsList) {
        foreach ($rs in $rankSpecs) {
            $q = "{ worldData { encounter(id: $($enc.id)) { characterRankings(metric: $($rs.metric), page: 1, className: `"$($rs.class)`", specName: `"$($rs.spec)`"$extra) } } }"
            $cr = $null
            try { $cr = (Invoke-GQL $q).worldData.encounter.characterRankings } catch { continue }
            if ($cr -is [string]) { $cr = $cr | ConvertFrom-Json }
            if (-not ($cr -and $cr.rankings)) { continue }
            foreach ($r in ($cr.rankings | Select-Object -First 4)) {
                if (-not ($r.report -and $r.report.code -and $r.duration)) { continue }
                $key = "$($r.report.code)#$($r.report.fightID)"
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    [void]$refs.Add(@{ code = $r.report.code; fight = [int]$r.report.fightID; durMin = [double]$r.duration / 60000.0 })
                }
            }
        }
    }
    Write-Host ("  {0}: {1} refs so far" -f $enc.name, $refs.Count)
}

# phase 2: Casts tables - every player in every table is a sample
# samples[specID] = list of @{ durMin; activePct; casts = @{spellID -> n}; names = @{spellID -> name} }
$samples = @{}
$fetched = 0
foreach ($ref in ($refs | Sort-Object { $_.code })) {
    if ($fetched -ge $MaxTables) { break }
    Assert-Points
    $t = $null
    try { $t = (Invoke-GQL "{ reportData { report(code: `"$($ref.code)`") { table(fightIDs: [$($ref.fight)], dataType: Casts) } } }").reportData.report.table } catch { continue }
    $fetched++
    if ($t -is [string]) { $t = $t | ConvertFrom-Json }
    $entries = if ($t -and $t.data -and $t.data.entries) { $t.data.entries } elseif ($t) { $t.entries } else { $null }
    if (-not $entries) { continue }
    foreach ($e in $entries) {
        if (-not $e.icon) { continue }
        $sid = $specByIcon[[string]$e.icon]
        if (-not $sid) { continue }
        $casts = @{}
        $names = @{}
        # junk filter: melee (1), Auto Shot (75), wand Shoot (5019) are not
        # buttons; "!"-styled entries (Hot Streak!) are proc auras WCL lists
        # among casts but CLEU never fires SPELL_CAST_SUCCESS for - keeping
        # them would coach players toward un-pressable false gaps
        foreach ($ab in ($e.abilities | Where-Object { $_.guid -gt 1 -and $_.guid -ne 75 -and $_.guid -ne 5019 -and $_.name -notmatch "!" })) {
            $casts[[int]$ab.guid] = [int]$ab.total
            $names[[int]$ab.guid] = [string]$ab.name
        }
        if ($casts.Count -eq 0) { continue }
        $activePct = $null
        if ($e.activeTime -and $ref.durMin -gt 0) {
            $activePct = [math]::Round(($e.activeTime / 1000.0) / ($ref.durMin * 60.0) * 100.0, 1)
            if ($activePct -gt 100) { $activePct = 100 }
        }
        if (-not $samples.ContainsKey($sid)) { $samples[$sid] = New-Object System.Collections.ArrayList }
        [void]$samples[$sid].Add(@{ durMin = $ref.durMin; activePct = $activePct; casts = $casts; names = $names })
    }
}
Write-Host ("Tables fetched: {0}; total HTTP requests: {1}" -f $fetched, $script:requestCount)

function Median($list) {
    $s = @($list | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    return $s[[int][math]::Floor(($s.Count - 1) / 2)]
}

# phase 3: per spec, pick signature spells (used by >=60% of top players,
# median CPM >= 0.5) and emit their median casts-per-minute
$lines = New-Object System.Collections.ArrayList
function Emit($s) { [void]$script:lines.Add($s) }
Emit "-- GENERATED by scripts\fetch-spellprofiles.ps1 - do not edit by hand."
Emit "-- Per-spec top-player habits from WCL Casts tables: median casts-"
Emit "-- per-minute of each spec's signature spells among top parses, and"
Emit "-- median activity%. Feeds the parse coach: the single biggest gap"
Emit "-- between a player's fight and this profile becomes one targeted"
Emit "-- line ('top Resto Druids cast Rejuvenation 13x/min - you 6')."
Emit ("-- Generated {0} - {1}." -f (Get-Date -Format "yyyy-MM-dd"), $zone.name)
Emit "local _, TP = ..."
Emit ""
Emit "TP.SpellProfiles = TP.SpellProfiles or {}"
foreach ($sid in ($samples.Keys | Sort-Object)) {
    $list = $samples[$sid]
    if ($list.Count -lt $MinPlayers) {
        Write-Host ("  spec {0}: only {1} samples; omitted" -f $sid, $list.Count)
        continue
    }
    # aggregate by NAME: spell morphs/ranks split one button across several
    # ids (Fury's Raging Blow showed 3x under different guids) - per player,
    # sum a name's ids, and remember every id so the in-game counter can
    # match whichever one the player's client fires
    $byName = @{}
    foreach ($smp in $list) {
        $perName = @{}
        foreach ($spellID in $smp.casts.Keys) {
            $nm = $smp.names[$spellID]
            if (-not $perName.ContainsKey($nm)) { $perName[$nm] = @{ n = 0; ids = @{} } }
            $perName[$nm].n += $smp.casts[$spellID]
            $perName[$nm].ids[$spellID] = $true
        }
        foreach ($nm in $perName.Keys) {
            if (-not $byName.ContainsKey($nm)) { $byName[$nm] = @{ cpms = (New-Object System.Collections.ArrayList); ids = @{} } }
            [void]$byName[$nm].cpms.Add($perName[$nm].n / $smp.durMin)
            foreach ($spellID in $perName[$nm].ids.Keys) { $byName[$nm].ids[$spellID] = $true }
        }
    }
    $sigs = @()
    foreach ($nm in $byName.Keys) {
        $rec = $byName[$nm]
        $usage = $rec.cpms.Count / $list.Count
        $med = Median $rec.cpms
        if ($usage -ge 0.6 -and $med -ge 0.5) {
            $sigs += @{ name = $nm; ids = @($rec.ids.Keys | Sort-Object); cpm = [math]::Round($med, 1) }
        }
    }
    $sigs = @($sigs | Sort-Object -Property cpm -Descending | Select-Object -First $MaxSpells)
    $actMed = Median @($list | Where-Object { $null -ne $_.activePct } | ForEach-Object { $_.activePct })
    $parts = @()
    foreach ($sg in $sigs) {
        $idList = ($sg.ids | ForEach-Object { "$_" }) -join ", "
        $parts += ("{{ ids = {{ {0} }}, name = `"{1}`", cpm = {2} }}" -f $idList, ($sg.name -replace '"', '\"'), $sg.cpm)
    }
    Emit ("TP.SpellProfiles[{0}] = {{ n = {1}, activity = {2}, spells = {{ {3} }} }}" -f `
        $sid, $list.Count, ($(if ($null -ne $actMed) { $actMed } else { "nil" })), ($parts -join ", "))
    Write-Host ("  spec {0}: n={1} activity={2} spells={3}" -f $sid, $list.Count, $actMed, (($sigs | ForEach-Object { "$($_.name)@$($_.cpm)" }) -join " "))
}
$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile }
    else { Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path "Data" $OutFile) }
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath"
