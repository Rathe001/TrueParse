# Per-boss UTILITY casts per spec, from ranked WCL reports (Josh 2026-09-09:
# "scan the WCL data for the dungeons and see when lust is being cast ...
# find other spells that are typically cast as well, so we could further
# customize what we show each player based on their spec").
#
# What it harvests, per boss and spec, from the Casts table of ranked kills:
# how often each spell on a UTILITY whitelist is cast per player-fight
# (interrupts, dispels, purges, soothes, stuns, lust, personal defensives,
# healer cooldowns) and what share of that spec's players cast it at all.
# Rotation spells are deliberately absent - SpellProfiles covers those and
# they are not notes. Plus the lust timing: the first Bloodlust-family cast
# in each fight, from the events feed, as a fraction of the fight and (in a
# keystone) which boss it landed on or before.
#
# Feeds Notes\*: a boss with no hand-written line for a tool a spec plainly
# uses in ranked runs gets a "ranked runs cast X here" line, and
# `/tp notes check` reports where the hand-written lines and the data
# disagree. See Data/BossCasts.lua's header for the emitted shape.
#
# Two zone kinds:
#  -Kind raid     one fight per boss (zone 53 = current retail tier).
#  -Kind dungeon  one fight per keystone RUN; boss pulls are the fight's
#                 dungeonPulls with an encounterID, and each boss's Casts
#                 table is the run's table clipped to that pull's window
#                 (zone 55 = the current Mythic+ season).
# NEVER run while another WCL crawl is active (single-active tokens).
#  Retail M+:  -GameBase https://www.warcraftlogs.com -ZoneId 55 -Kind dungeon -OutFile BossCasts.lua
#  Retail raid: -GameBase https://www.warcraftlogs.com -ZoneId 53 -Kind raid -Brackets "4,3" -OutFile BossCasts_Raid.lua
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int]$ZoneId = 55,
    [ValidateSet("dungeon", "raid")][string]$Kind = "dungeon",
    [string]$Brackets = "",
    [int]$MaxTables = 60,      # reports fetched per run (points budget)
    [int]$MinPlayers = 5,      # per boss+spec: fewer player-fights than this are omitted
    [string]$OutFile = "BossCasts.lua",
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

# icon "Class-Spec" -> global specID (same table as fetch-report-tables.ps1)
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

# The UTILITY whitelist, by spell NAME (WCL names are English and stable
# across id churn; ids are listed where the addon already tracks them).
# kind: kick dispel purge soothe stun lust defensive healercd utility
$kindByName = @{
    # interrupts
    "Pummel" = "kick"; "Rebuke" = "kick"; "Counter Shot" = "kick"; "Muzzle" = "kick"; "Kick" = "kick"
    "Silence" = "kick"; "Mind Freeze" = "kick"; "Wind Shear" = "kick"; "Counterspell" = "kick"
    "Spell Lock" = "kick"; "Axe Toss" = "kick"; "Spear Hand Strike" = "kick"; "Skull Bash" = "kick"
    "Solar Beam" = "kick"; "Disrupt" = "kick"; "Quell" = "kick"
    # friendly dispels
    "Cleanse" = "dispel"; "Cleanse Toxins" = "dispel"; "Purify" = "dispel"; "Purify Disease" = "dispel"
    "Mass Dispel" = "dispel"; "Purify Spirit" = "dispel"; "Cleanse Spirit" = "dispel"
    "Poison Cleansing Totem" = "dispel"; "Remove Curse" = "dispel"; "Singe Magic" = "dispel"
    "Detox" = "dispel"; "Nature's Cure" = "dispel"; "Remove Corruption" = "dispel"
    "Cauterizing Flame" = "dispel"; "Naturalize" = "dispel"; "Expunge" = "dispel"; "Tremor Totem" = "dispel"
    # enemy buff removal
    "Purge" = "purge"; "Spellsteal" = "purge"; "Dispel Magic" = "purge"; "Devour Magic" = "purge"
    "Consume Magic" = "purge"; "Tranquilizing Shot" = "purge"
    # enrage removal
    "Soothe" = "soothe"; "Shiv" = "soothe"; "Oppressing Roar" = "soothe"
    # hard CC
    "Capacitor Totem" = "stun"; "Chaos Nova" = "stun"; "Leg Sweep" = "stun"; "Shadowfury" = "stun"
    "Hammer of Justice" = "stun"; "Kidney Shot" = "stun"; "Asphyxiate" = "stun"; "Storm Bolt" = "stun"
    "Shockwave" = "stun"; "Mighty Bash" = "stun"; "Intimidation" = "stun"; "Sigil of Silence" = "stun"
    "Holy Word: Chastise" = "stun"; "Psychic Horror" = "stun"; "Ring of Frost" = "stun"; "Paralysis" = "stun"
    # lust (Data/Lust.lua)
    "Bloodlust" = "lust"; "Heroism" = "lust"; "Time Warp" = "lust"; "Primal Rage" = "lust"; "Fury of the Aspects" = "lust"
    # personal defensives (Data/Defensives.lua, retail)
    "Shield Wall" = "defensive"; "Last Stand" = "defensive"; "Rallying Cry" = "defensive"; "Die by the Sword" = "defensive"
    "Divine Shield" = "defensive"; "Ardent Defender" = "defensive"; "Guardian of Ancient Kings" = "defensive"
    "Divine Protection" = "defensive"; "Blessing of Protection" = "defensive"; "Aspect of the Turtle" = "defensive"
    "Exhilaration" = "defensive"; "Evasion" = "defensive"; "Cloak of Shadows" = "defensive"; "Crimson Vial" = "defensive"
    "Desperate Prayer" = "defensive"; "Dispersion" = "defensive"; "Icebound Fortitude" = "defensive"
    "Anti-Magic Shell" = "defensive"; "Vampiric Blood" = "defensive"; "Astral Shift" = "defensive"; "Ice Block" = "defensive"
    "Greater Invisibility" = "defensive"; "Unending Resolve" = "defensive"; "Dark Pact" = "defensive"
    "Fortifying Brew" = "defensive"; "Diffuse Magic" = "defensive"; "Dampen Harm" = "defensive"; "Barkskin" = "defensive"
    "Survival Instincts" = "defensive"; "Blur" = "defensive"; "Netherwalk" = "defensive"; "Obsidian Scales" = "defensive"
    "Renewing Blaze" = "defensive"
    # group utility: the buttons a spec brings for everyone (Josh 2026-09-09,
    # "poison cleansing totem, wind rush totem, etc.")
    "Wind Rush Totem" = "utility"; "Earthgrab Totem" = "utility"; "Stoneskin Totem" = "utility"
    "Ancestral Protection Totem" = "utility"; "Earthen Wall Totem" = "utility"; "Totemic Projection" = "utility"
    "Stampeding Roar" = "utility"; "Blessing of Freedom" = "utility"; "Lay on Hands" = "utility"
    "Darkness" = "utility"; "Anti-Magic Zone" = "utility"; "Death Grip" = "utility"; "Gorefiend's Grasp" = "utility"
    "Leap of Faith" = "utility"; "Power Infusion" = "utility"; "Vampiric Embrace" = "utility"; "Symbol of Hope" = "utility"
    "Innervate" = "utility"; "Mass Entanglement" = "utility"; "Ring of Peace" = "utility"; "Zephyr" = "utility"
    "Rescue" = "utility"; "Time Spiral" = "utility"; "Mass Barrier" = "utility"; "Mass Invisibility" = "utility"
    "Intervene" = "utility"; "Shroud of Concealment" = "utility"; "Ursol's Vortex" = "utility"
    # healer / raid cooldowns (Data/HealerCDs.lua, retail)
    "Divine Hymn" = "healercd"; "Power Word: Barrier" = "healercd"; "Pain Suppression" = "healercd"; "Guardian Spirit" = "healercd"
    "Tranquility" = "healercd"; "Ironbark" = "healercd"; "Flourish" = "healercd"; "Healing Tide Totem" = "healercd"
    "Spirit Link Totem" = "healercd"; "Ascendance" = "healercd"; "Revival" = "healercd"; "Life Cocoon" = "healercd"
    "Aura Mastery" = "healercd"; "Blessing of Sacrifice" = "healercd"; "Avenging Wrath" = "healercd"
    "Emerald Communion" = "healercd"; "Rewind" = "healercd"; "Time Dilation" = "healercd"
}
$lustIds = @(2825, 32182, 80353, 264667, 390386)
$lustFilter = "ability.id in (" + ($lustIds -join ",") + ")"

# a spread of specs so every role's rankings feed the pool: healers for the
# cooldowns and dispels, a tank for the defensives, DPS for kicks and lust
$rankSpecs = @(
    @{ class = "Paladin"; spec = "Protection"; metric = "dps" }
    @{ class = "Druid"; spec = "Restoration"; metric = "hps" }
    @{ class = "Priest"; spec = "Discipline"; metric = "hps" }
    @{ class = "Shaman"; spec = "Restoration"; metric = "hps" }
    @{ class = "Mage"; spec = "Frost"; metric = "dps" }
    @{ class = "Hunter"; spec = "BeastMastery"; metric = "dps" }
    @{ class = "Warlock"; spec = "Demonology"; metric = "dps" }
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
Write-Host ("Zone: {0} ({1} encounters, kind {2})" -f $zone.name, $zone.encounters.Count, $Kind)

# ---- phase 1: discover report refs per encounter ----
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
            foreach ($page in @(1, 3)) {
                $q = "{ worldData { encounter(id: $($enc.id)) { characterRankings(metric: $($rs.metric), page: $page, className: `"$($rs.class)`", specName: `"$($rs.spec)`"$extra) } } }"
                $cr = $null
                try { $cr = (Invoke-GQL $q).worldData.encounter.characterRankings } catch { continue }
                if ($cr -is [string]) { $cr = $cr | ConvertFrom-Json }
                if (-not ($cr -and $cr.rankings)) { continue }
                foreach ($r in ($cr.rankings | Select-Object -First 3)) {
                    if (-not ($r.report -and $r.report.code)) { continue }
                    $key = "$($r.report.code)#$($r.report.fightID)"
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        [void]$bag.Add(@{ code = $r.report.code; fight = [int]$r.report.fightID; encId = [int]$enc.id; encName = $enc.name })
                    }
                }
            }
        }
    }
    Write-Host ("  {0}: {1} refs" -f $enc.name, $bag.Count)
}

# ---- phase 2: harvest ----
# WHY EVENTS AND NOT THE TABLE FOR THE COUNTS (2026-09-09): a Casts table
# clipped to a pull window returns only each player's top FIVE abilities,
# so a kick or a dispel shows up only when it out-casts the rotation. The
# table is still the one place that says which SPEC a player is (its
# `icon`), so it is fetched for that; the counts come from the events feed
# filtered to the whitelist, which has no such cap.
$utilNames = @($kindByName.Keys | Sort-Object)
$utilFilter = 'type = \"cast\" and ability.name in (' + (($utilNames | ForEach-Object { '\"' + $_ + '\"' }) -join ", ") + ')'

# agg[encName][bossName] = @{ n; lustN; lustAt; lustOn; lustBefore;
#   specs = @{ sid -> @{ n; spells = @{ name -> @{ kind; counts = list (one per player-fight) } } } } }
$agg = @{}
function BossBag($encName, $bossName) {
    if (-not $agg.ContainsKey($encName)) { $agg[$encName] = @{} }
    if (-not $agg[$encName].ContainsKey($bossName)) {
        $agg[$encName][$bossName] = @{ n = 0; lustN = 0; lustAt = New-Object System.Collections.ArrayList
            lustOn = @{}; lustBefore = @{}; specs = @{} }
    }
    return $agg[$encName][$bossName]
}
function Entries($tbl) {
    if ($tbl -and $tbl.data -and $tbl.data.entries) { return $tbl.data.entries }
    if ($tbl -and $tbl.entries) { return $tbl.entries }
    return @()
}
function EventRows($ev) {
    if ($ev -and $ev.data) { return $ev.data }
    return @()
}
# One boss pull (or raid fight): the table's entries name the players and
# their specs; the event rows are every whitelisted cast in the window.
function Add-Pull($bag, $entries, $rows, $abil) {
    $specOf = @{}   # actor id -> specID
    foreach ($e in ($entries | Where-Object { $_.icon })) {
        $sid = $specByIcon[[string]$e.icon]
        if (-not $sid) { continue }
        if ($null -ne $e.id) { $specOf[[int]$e.id] = $sid }
    }
    if ($specOf.Count -eq 0) { return }
    $perPlayer = @{}  # actor id -> @{ name -> count }
    foreach ($row in $rows) {
        if ($null -eq $row.sourceID -or $null -eq $row.abilityGameID) { continue }
        $aid = [int]$row.sourceID
        if (-not $specOf.ContainsKey($aid)) { continue }
        $nm = $abil[[int]$row.abilityGameID]
        if (-not ($nm -and $kindByName[$nm])) { continue }
        if (-not $perPlayer.ContainsKey($aid)) { $perPlayer[$aid] = @{} }
        if (-not $perPlayer[$aid].ContainsKey($nm)) { $perPlayer[$aid][$nm] = 0 }
        $perPlayer[$aid][$nm] += 1
    }
    foreach ($aid in $specOf.Keys) {
        $sid = $specOf[$aid]
        if (-not $bag.specs.ContainsKey($sid)) { $bag.specs[$sid] = @{ n = 0; spells = @{} } }
        $S = $bag.specs[$sid]
        $S.n += 1
        $bag.n += 1
        $mine = $perPlayer[$aid]
        if ($mine) {
            foreach ($nm in $mine.Keys) {
                if (-not $S.spells.ContainsKey($nm)) { $S.spells[$nm] = @{ kind = $kindByName[$nm]; counts = New-Object System.Collections.ArrayList } }
                [void]$S.spells[$nm].counts.Add([int]$mine[$nm])
            }
        }
    }
}
function AbilityNames($master) {
    $abil = @{}
    if ($master -and $master.abilities) {
        foreach ($a in $master.abilities) { if ($null -ne $a.gameID) { $abil[[int]$a.gameID] = [string]$a.name } }
    }
    return $abil
}

$cursor = @{}
foreach ($k in $refsByEnc.Keys) { $cursor[$k] = 0 }
$encOrder = @($zone.encounters | ForEach-Object { $_.name })
$fetched = 0
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
        if ($Kind -eq "raid") {
            $q = "{ reportData { report(code: `"$($ref.code)`") { fights(fightIDs: [$($ref.fight)]) { id startTime endTime } casts: table(fightIDs: [$($ref.fight)], dataType: Casts) util: events(fightIDs: [$($ref.fight)], dataType: Casts, filterExpression: `"$utilFilter`", limit: 5000) { data } lust: events(fightIDs: [$($ref.fight)], dataType: Casts, filterExpression: `"$lustFilter`", limit: 40) { data } master: masterData { abilities { gameID name } } } } }"
            $rep = $null
            try { $rep = (Invoke-GQL $q).reportData.report } catch { Write-Warning "skip $($ref.code): $($_.Exception.Message)"; continue }
            $fetched++
            $B = BossBag $zone.name $encName
            Add-Pull $B (Entries $rep.casts) (EventRows $rep.util) (AbilityNames $rep.master)
            $f = $rep.fights | Select-Object -First 1
            if ($f -and ($f.endTime -gt $f.startTime)) {
                $first = $null
                foreach ($row in (EventRows $rep.lust)) {
                    if ($row.timestamp -and ($null -eq $first -or $row.timestamp -lt $first)) { $first = [double]$row.timestamp }
                }
                if ($null -ne $first) {
                    $B.lustN += 1
                    [void]$B.lustAt.Add([math]::Round(($first - $f.startTime) / ($f.endTime - $f.startTime), 3))
                }
            }
        } else {
            # a keystone run: the fight's boss pulls give each boss its window
            $q = "{ reportData { report(code: `"$($ref.code)`") { fights(fightIDs: [$($ref.fight)]) { id startTime endTime keystoneLevel dungeonPulls { id name startTime endTime encounterID } } lust: events(fightIDs: [$($ref.fight)], dataType: Casts, filterExpression: `"$lustFilter`", limit: 60) { data } master: masterData { abilities { gameID name } } } } }"
            $rep = $null
            try { $rep = (Invoke-GQL $q).reportData.report } catch { Write-Warning "skip $($ref.code): $($_.Exception.Message)"; continue }
            $f = $rep.fights | Select-Object -First 1
            if (-not $f) { continue }
            $pulls = @($f.dungeonPulls | Where-Object { $_.encounterID -gt 0 -and $_.name } | Sort-Object { [double]$_.startTime })
            if ($pulls.Count -eq 0) { continue }
            $abil = AbilityNames $rep.master
            $aliases = @()
            for ($i = 0; $i -lt $pulls.Count; $i++) {
                $p = $pulls[$i]
                $aliases += ("b{0}: table(fightIDs: [{1}], dataType: Casts, startTime: {2}, endTime: {3})" -f $i, $ref.fight, [long]$p.startTime, [long]$p.endTime)
                $aliases += ("e{0}: events(fightIDs: [{1}], dataType: Casts, startTime: {2}, endTime: {3}, filterExpression: `"{4}`", limit: 2000) {{ data }}" -f $i, $ref.fight, [long]$p.startTime, [long]$p.endTime, $utilFilter)
            }
            $q2 = "{ reportData { report(code: `"$($ref.code)`") { " + ($aliases -join " ") + " } } }"
            $tabs = $null
            try { $tabs = (Invoke-GQL $q2).reportData.report } catch { Write-Warning "skip $($ref.code) pulls: $($_.Exception.Message)"; continue }
            $fetched++
            for ($i = 0; $i -lt $pulls.Count; $i++) {
                $B = BossBag $encName ([string]$pulls[$i].name)
                Add-Pull $B (Entries $tabs.("b$i")) (EventRows $tabs.("e$i")) $abil
            }
            # lust: the first cast of the run, placed on or before a boss
            $first = $null
            foreach ($row in (EventRows $rep.lust)) {
                if ($row.timestamp -and ($null -eq $first -or $row.timestamp -lt $first)) { $first = [double]$row.timestamp }
            }
            if ($null -ne $first) {
                $placed = $false
                foreach ($p in $pulls) {
                    if ($first -ge $p.startTime -and $first -le $p.endTime) {
                        $B = BossBag $encName ([string]$p.name); $B.lustN += 1
                        if (-not $B.lustOn.ContainsKey("self")) { $B.lustOn["self"] = 0 }
                        $B.lustOn["self"] += 1
                        $placed = $true; break
                    }
                }
                if (-not $placed) {
                    foreach ($p in $pulls) {
                        if ($first -lt $p.startTime) {
                            $B = BossBag $encName ([string]$p.name); $B.lustN += 1
                            if (-not $B.lustBefore.ContainsKey("self")) { $B.lustBefore["self"] = 0 }
                            $B.lustBefore["self"] += 1
                            break
                        }
                    }
                }
            }
        }
    }
    if (-not $any) { break }
}
Write-Host ("Reports harvested: {0}; total HTTP requests: {1}" -f $fetched, $script:requestCount)

function Median($list) {
    $s = @($list | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    return $s[[int][math]::Floor(($s.Count - 1) / 2)]
}
function LuaStr($s) { return '"' + ([string]$s -replace '\\', '\\' -replace '"', '\"') + '"' }

$today = Get-Date -Format "yyyy-MM-dd"
$lines = New-Object System.Collections.ArrayList
function E1($s) { [void]$lines.Add($s) }
E1 "-- GENERATED by scripts\fetch-boss-casts.ps1 - do not edit by hand."
E1 "-- Per-boss, per-spec UTILITY casts in ranked WCL kills, plus lust timing."
E1 ("-- Generated {0} from {1} (zone {2}, {3}); {4} reports." -f $today, $zone.name, $ZoneId, $Kind, $fetched)
E1 "--"
E1 "-- put(instance, boss, n, lust, specs)"
E1 "--   n      player-fights sampled on this boss (all specs)"
E1 "--   lust   { n=, at= } (raid: median first-cast time as a fraction of the"
E1 "--          fight) or { n=, on=, before= } (keystone: runs whose FIRST lust"
E1 "--          landed on this boss, or on the stretch before it)"
E1 "--   specs  [specID] = { n=, s = { { name, kind, cpf, share }, ... } }"
E1 "--          cpf = median casts per player-fight (0 when most cast none),"
E1 "--          share = fraction of that spec's players who cast it at all."
E1 "--          kind = kick dispel purge soothe stun lust defensive healercd utility"
E1 "local _, TP = ..."
E1 "TP.BossCasts = TP.BossCasts or {}"
E1 "local B = TP.BossCasts"
E1 "local function put(instance, boss, n, lust, specs)"
E1 "	B[instance] = B[instance] or {}"
E1 "	B[instance][boss] = { n = n, lust = lust, specs = specs }"
E1 "end"
E1 ""
$emitted = 0
foreach ($encName in ($agg.Keys | Sort-Object)) {
    foreach ($bossName in ($agg[$encName].Keys | Sort-Object)) {
        $B = $agg[$encName][$bossName]
        if ($B.n -lt $MinPlayers) { continue }
        $specParts = @()
        foreach ($sid in ($B.specs.Keys | Sort-Object)) {
            $S = $B.specs[$sid]
            if ($S.n -lt $MinPlayers) { continue }
            $spellParts = @()
            foreach ($nm in ($S.spells.Keys | Sort-Object)) {
                $sp = $S.spells[$nm]
                # back-fill zeros for player-fights before/after the spell appeared
                $counts = New-Object System.Collections.ArrayList
                foreach ($c in $sp.counts) { [void]$counts.Add([int]$c) }
                while ($counts.Count -lt $S.n) { [void]$counts.Add(0) }
                $nonzero = @($counts | Where-Object { $_ -gt 0 }).Count
                $share = [math]::Round($nonzero / [double]$S.n, 2)
                if ($share -lt 0.1) { continue }
                $cpf = Median $counts
                $spellParts += ("{{ {0}, {1}, {2}, {3} }}" -f (LuaStr $nm), (LuaStr $sp.kind), $cpf, $share)
            }
            if ($spellParts.Count -eq 0) { continue }
            $specParts += ("[{0}] = {{ n = {1}, s = {{ {2} }} }}" -f $sid, $S.n, ($spellParts -join ", "))
        }
        $lust = "nil"
        if ($B.lustN -gt 0) {
            if ($Kind -eq "raid") {
                $lust = ("{{ n = {0}, at = {1} }}" -f $B.lustN, (Median $B.lustAt))
            } else {
                $on = 0; $before = 0
                if ($B.lustOn["self"]) { $on = $B.lustOn["self"] }
                if ($B.lustBefore["self"]) { $before = $B.lustBefore["self"] }
                $lust = ("{{ n = {0}, on = {1}, before = {2} }}" -f $B.lustN, $on, $before)
            }
        }
        E1 ("put({0}, {1}, {2}, {3}, {{ {4} }})" -f (LuaStr $encName), (LuaStr $bossName), $B.n, $lust, ($specParts -join ", "))
        $emitted++
    }
}
$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile }
    else { Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path "Data" $OutFile) }
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host ("Wrote {0}: {1} bosses" -f $outPath, $emitted)
