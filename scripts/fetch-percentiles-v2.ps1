# V2 (GraphQL) percentile fetcher - same output as fetch-percentiles.ps1
# but batched: one HTTP request carries dozens of aliased characterRankings
# queries, and population-size probing happens for ALL specs of an
# encounter simultaneously (one request per probe round instead of a serial
# binary search per spec). Typically 10-50x fewer round trips than V1.
# Auth: OAuth client credentials from scripts\wcl-v2-client.local.txt
# (line 1 = client id, line 2 = secret; create at warcraftlogs.com clients).
# MoP:    powershell -File scripts\fetch-percentiles-v2.ps1 `
#           -GameBase https://classic.warcraftlogs.com -ZoneId 1054 `
#           -OutFile Percentiles_Mists.lua
# Retail: powershell -File scripts\fetch-percentiles-v2.ps1 -ZoneId 46
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int]$ZoneId = 46,
    # Comma-separated WCL brackets: "3" (difficulty only, retail flex) or
    # "3x10" (difficulty x raid size, classic). Empty = one unfiltered "all"
    # bracket. Pooling brackets skews percentiles badly (25H parses bury a
    # 10N raider), so real deployments should always pass brackets.
    [string]$Brackets = "",
    [int]$MinParses = 300,
    [int]$MaxAliases = 30,     # aliased queries per HTTP request
    [int]$MaxProbePages = 512,
    [int]$EncounterLimit = 0,  # >0 = only the first N encounters (smoke tests)
    [string]$OutFile = "Percentiles.lua",
    [string]$ClientFile = "$PSScriptRoot\wcl-v2-client.local.txt"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $ClientFile)) {
    Write-Error "Missing $ClientFile (line 1 = client id, line 2 = secret)."
    exit 1
}
$creds = Get-Content $ClientFile
$clientId = $creds[0].Trim()
$clientSecret = $creds[1].Trim()

$quantiles = @(99, 95, 90, 75, 50, 25, 10)

# V1-style "Class:Spec" -> global specID; V2 wants space-free names
$specIDs = @{
    "Death Knight:Blood" = 250; "Death Knight:Frost" = 251; "Death Knight:Unholy" = 252
    "Demon Hunter:Havoc" = 577; "Demon Hunter:Vengeance" = 581
    "Druid:Balance" = 102; "Druid:Feral" = 103; "Druid:Guardian" = 104; "Druid:Restoration" = 105
    "Evoker:Devastation" = 1467; "Evoker:Preservation" = 1468; "Evoker:Augmentation" = 1473
    "Hunter:Beast Mastery" = 253; "Hunter:Marksmanship" = 254; "Hunter:Survival" = 255
    "Mage:Arcane" = 62; "Mage:Fire" = 63; "Mage:Frost" = 64
    "Monk:Brewmaster" = 268; "Monk:Mistweaver" = 270; "Monk:Windwalker" = 269
    "Paladin:Holy" = 65; "Paladin:Protection" = 66; "Paladin:Retribution" = 70
    "Priest:Discipline" = 256; "Priest:Holy" = 257; "Priest:Shadow" = 258
    "Rogue:Assassination" = 259; "Rogue:Combat" = 260; "Rogue:Subtlety" = 261
    "Shaman:Elemental" = 262; "Shaman:Enhancement" = 263; "Shaman:Restoration" = 264
    "Warlock:Affliction" = 265; "Warlock:Demonology" = 266; "Warlock:Destruction" = 267
    "Warrior:Arms" = 71; "Warrior:Fury" = 72; "Warrior:Protection" = 73
}
$healerSpecs = @("Druid:Restoration", "Evoker:Preservation", "Monk:Mistweaver",
    "Paladin:Holy", "Priest:Discipline", "Priest:Holy", "Shaman:Restoration")
$skipDamage = @("Evoker:Augmentation")

# ---- OAuth ----
# NOTE: minting a token appears to revoke the previous one (single-active),
# and revoked tokens surface as 500s. Never request tokens elsewhere while
# a crawl is running; Get-Token below also lets the crawl self-heal.
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${clientId}:${clientSecret}"))
function Get-Token {
    foreach ($tokenHost in @($script:GameBase, "https://www.warcraftlogs.com")) {
        try {
            $resp = Invoke-RestMethod -Method Post -Uri "$tokenHost/oauth/token" `
                -Headers @{ Authorization = "Basic $script:basic" } `
                -Body @{ grant_type = "client_credentials" } -TimeoutSec 30
            return $resp.access_token
        } catch {
            Write-Warning "token from $tokenHost failed: $_"
        }
    }
    return $null
}
$token = Get-Token
if (-not $token) { Write-Error "OAuth token request failed"; exit 1 }
$gqlUri = "$GameBase/api/v2/client"
Write-Host "OAuth OK; endpoint $gqlUri"

$script:requestCount = 0
function Invoke-GQL($query, $quick) {
    $script:requestCount++
    $body = @{ query = $query } | ConvertTo-Json -Compress
    $resp = $null
    $attempt = 0
    # quick mode fails fast so the caller can split the batch; slow mode
    # outwaits transient trouble and the hourly points window
    $waits = @(10, 60, 300, 600)
    if ($quick) { $waits = @(5) }
    while ($true) {
        $attempt++
        try {
            # 180s: cold ranking slices can take WCL minutes to compute;
            # a short client timeout abandons and restarts that work forever
            $resp = Invoke-RestMethod -Method Post -Uri $script:gqlUri -TimeoutSec 180 `
                -Headers @{ Authorization = "Bearer $script:token" } `
                -ContentType "application/json" -Body $body
            break
        } catch {
            # read the error RESPONSE body: the server usually says why
            $serverSays = ""
            try {
                $respStream = $_.Exception.Response.GetResponseStream()
                if ($respStream) {
                    $reader = New-Object System.IO.StreamReader($respStream)
                    $serverSays = $reader.ReadToEnd()
                    if ($serverSays.Length -gt 300) { $serverSays = $serverSays.Substring(0, 300) }
                }
            } catch {}
            if ($attempt -eq 1) {
                [System.IO.File]::WriteAllText("$PSScriptRoot\last-failed-query.local.txt", $query)
                [System.IO.File]::WriteAllText("$PSScriptRoot\last-failed-body.local.txt", $body)
            }
            if ($attempt -gt $waits.Count) { throw }
            $wait = $waits[$attempt - 1]
            Write-Warning "retry $attempt in ${wait}s: $_ [server: $serverSays]"
            Start-Sleep -Seconds $wait
            if ($attempt -ge 2) {
                # a revoked token (someone else minted one) 500s forever;
                # re-auth reclaims it and the crawl self-heals
                $fresh = Get-Token
                if ($fresh) { $script:token = $fresh }
            }
        }
    }
    if ($resp.errors) {
        Write-Warning ("GraphQL errors: " + (($resp.errors | ForEach-Object { $_.message }) -join "; "))
    }
    $rl = $resp.data.rateLimitData
    if ($rl -and $rl.pointsSpentThisHour -gt ($rl.limitPerHour * 0.92)) {
        $wait = [math]::Ceiling($rl.pointsResetIn) + 5
        Write-Warning "Near point limit ($($rl.pointsSpentThisHour)/$($rl.limitPerHour)); sleeping ${wait}s"
        Start-Sleep -Seconds $wait
    }
    Start-Sleep -Milliseconds 250
    return $resp.data
}

# ---- zone / encounters ----
$zoneData = Invoke-GQL "query { rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } worldData { zone(id: $ZoneId) { name encounters { id name } } } }"
$zone = $zoneData.worldData.zone
if (-not $zone) { Write-Error "Zone $ZoneId not found"; exit 1 }
$encList = @($zone.encounters)
if ($EncounterLimit -gt 0 -and $encList.Count -gt $EncounterLimit) {
    $encList = $encList[0..($EncounterLimit - 1)]
}
Write-Host ("Zone: {0} ({1} encounters)" -f $zone.name, $encList.Count)

# ---- combo list ----
# BOTH metrics per spec: healer damage and tank/DPS self-healing rank on WCL
# too, and those off-metric curves are what make cross-metric contributions
# spec-fair (a Blood DK's self-healing measured against Blood DKs, Disc
# damage against Disc). Thin populations fall out via MinParses.
$combos = New-Object System.Collections.ArrayList
foreach ($specKey in $specIDs.Keys) {
    if ($skipDamage -contains $specKey) { continue } # Aug: support damage invisible
    $parts = $specKey -split ":"
    foreach ($metric in @("dps", "hps")) {
        [void]$combos.Add(@{
            key = "$specKey/$metric"
            specID = $specIDs[$specKey]
            classV2 = ($parts[0] -replace " ", "")
            specV2 = ($parts[1] -replace " ", "")
            metric = $metric
        })
    }
}

# Parsed bracket list: @{ key; args } where args is the GraphQL argument
# suffix appended to every characterRankings call
$bracketList = New-Object System.Collections.ArrayList
if ($Brackets -ne "") {
    foreach ($token in ($Brackets -split ",")) {
        $t = $token.Trim()
        if ($t -match "^(\d+)x(\d+)$") {
            [void]$bracketList.Add(@{ key = $t; args = (", difficulty: {0}, size: {1}" -f $Matches[1], $Matches[2]) })
        } elseif ($t -match "^(\d+)$") {
            [void]$bracketList.Add(@{ key = $t; args = (", difficulty: {0}" -f $t) })
        } else {
            Write-Error "Bad bracket token '$t' (want '3' or '3x10')"
            exit 1
        }
    }
} else {
    [void]$bracketList.Add(@{ key = "all"; args = "" })
}

# One batched round: fetch (comboIdx -> page) pairs, return alias -> blob.
# $script:bracketArgs carries the current bracket's difficulty/size filter.
# WCL computes filtered ranking slices lazily; a batch of COLD slices can
# 500 while each query succeeds alone (and warms the cache). So failed
# chunks split in half and retry, degenerating to singles only where cold.
function Invoke-Chunk($encId, $chunkKeys, $results) {
    $fields = New-Object System.Collections.ArrayList
    foreach ($k in $chunkKeys) {
        $c = $script:combos[[int]($k -split "@")[0]]
        $page = [int]($k -split "@")[1]
        [void]$fields.Add(("x{0}: characterRankings(className: `"{1}`", specName: `"{2}`", metric: {3}, page: {4}{5})" -f `
            ($k -replace "@", "_"), $c.classV2, $c.specV2, $c.metric, $page, $script:bracketArgs))
    }
    $q = "query { rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } worldData { encounter(id: $encId) { " + ($fields -join " ") + " } } }"
    try {
        $data = Invoke-GQL $q ($chunkKeys.Count -gt 1)
    } catch {
        if ($chunkKeys.Count -le 1) {
            # one persistently-broken slice must never kill the crawl
            Write-Warning ("giving up on {0}: {1}" -f $chunkKeys[0], $_)
            $results[$chunkKeys[0]] = $null
            return
        }
        $mid = [int][math]::Floor($chunkKeys.Count / 2)
        Write-Warning ("chunk of {0} failed; splitting" -f $chunkKeys.Count)
        Invoke-Chunk $encId @($chunkKeys[0..($mid - 1)]) $results
        Invoke-Chunk $encId @($chunkKeys[$mid..($chunkKeys.Count - 1)]) $results
        return
    }
    $encNode = $data.worldData.encounter
    foreach ($k in $chunkKeys) {
        $alias = "x" + ($k -replace "@", "_")
        $results[$k] = $encNode.$alias
    }
}

function Invoke-Round($encId, $wanted) {
    $results = @{}
    $keys = @($wanted.Keys)
    for ($chunk = 0; $chunk -lt $keys.Count; $chunk += $script:MaxAliases) {
        $upper = [math]::Min($chunk + $script:MaxAliases - 1, $keys.Count - 1)
        Invoke-Chunk $encId @($keys[$chunk..$upper]) $results
    }
    return $results
}

function Get-PageSize($blob) {
    if ($null -eq $blob -or $null -eq $blob.rankings) { return 0 }
    return @($blob.rankings).Count
}

$PAGE_SIZE = 100

# Fold one fetched page into a combo's population-search state
function Apply-Probe($s, $page, $blob) {
    $size = Get-PageSize $blob
    if ($size -eq 0) {
        if ($null -eq $s.hiBound -or $page -lt $s.hiBound) { $s.hiBound = $page }
    } elseif (-not $blob.hasMorePages) {
        $s.n = ($page - 1) * $script:PAGE_SIZE + $size
    } elseif ($page -gt $s.lo) {
        $s.lo = $page
    }
}

# Next page this combo needs to pin down its population size, or $null when
# resolved. Consumes cached pages inline so a combo can never stall.
function Get-NextProbe($s) {
    while ($true) {
        if ($null -ne $s.n) { return $null }
        $next = $null
        if ($null -eq $s.hiBound) {
            $next = $s.lo * 2
            if ($next -gt $script:MaxProbePages) {
                $s.hiBound = $script:MaxProbePages + 1
                continue
            }
        } elseif ($s.lo + 1 -lt $s.hiBound) {
            # [int] casts matter: hashtable keys are type-sensitive and
            # [math]::Floor returns a double — pages[3.0] misses key [int]3
            $next = [int][math]::Floor(($s.lo + $s.hiBound) / 2)
        } else {
            # lo is the last non-empty page
            $loBlob = $s.pages[$s.lo]
            $loSize = Get-PageSize $loBlob
            if ($loSize -eq $script:PAGE_SIZE -and $loBlob.hasMorePages) {
                $s.n = $s.lo * $script:PAGE_SIZE # boundary: full page, next empty
            } else {
                $s.n = ($s.lo - 1) * $script:PAGE_SIZE + $loSize
            }
            return $null
        }
        if ($s.pages.ContainsKey($next)) {
            Apply-Probe $s $next $s.pages[$next]
            continue
        }
        return $next
    }
}

$encounters = @{}
foreach ($enc in $encList) {
    Write-Host ("=== {0} ({1})" -f $enc.name, $enc.id)
    $bracketSets = @{}
    foreach ($bracket in $bracketList) {
    $script:bracketArgs = $bracket.args
    # state per combo
    $state = @{}
    for ($i = 0; $i -lt $combos.Count; $i++) {
        $state[$i] = @{ pages = @{}; n = $null; lo = 1; hiBound = $null }
    }

    # Round 0: page 1 for everyone
    $wanted = @{}
    for ($i = 0; $i -lt $combos.Count; $i++) { $wanted["$i@1"] = $true }
    $got = Invoke-Round $enc.id $wanted
    for ($i = 0; $i -lt $combos.Count; $i++) {
        $blob = $got["$i@1"]
        $s = $state[$i]
        $s.pages[1] = $blob
        if ((Get-PageSize $blob) -eq 0) { $s.n = 0 }
        else { Apply-Probe $s 1 $blob }
    }

    # Probe rounds: one batched request per round until every combo's
    # population size is pinned down
    while ($true) {
        $wanted = @{}
        for ($i = 0; $i -lt $combos.Count; $i++) {
            $next = Get-NextProbe $state[$i]
            if ($null -ne $next) { $wanted["$i@$next"] = $true }
        }
        if ($wanted.Count -eq 0) { break }
        $got = Invoke-Round $enc.id $wanted
        foreach ($k in $got.Keys) {
            $idx = [int]($k -split "@")[0]
            $page = [int]($k -split "@")[1]
            $state[$idx].pages[$page] = $got[$k]
            Apply-Probe $state[$idx] $page $got[$k]
        }
    }
    $pageSize = $PAGE_SIZE

    # Quantile round(s): everything needed that isn't cached yet
    $wanted = @{}
    for ($i = 0; $i -lt $combos.Count; $i++) {
        $s = $state[$i]
        if ($null -eq $s.n -or $s.n -lt $MinParses) { continue }
        foreach ($pct in $quantiles) {
            $rank = [int][math]::Max(1, [math]::Ceiling((100 - $pct) / 100 * $s.n))
            if ($rank -gt $s.n) { $rank = [int]$s.n }
            $page = [int]([math]::Floor(($rank - 1) / $pageSize) + 1)
            if (-not $s.pages.ContainsKey($page)) { $wanted["$i@$page"] = $true }
        }
    }
    if ($wanted.Count -gt 0) {
        $got = Invoke-Round $enc.id $wanted
        foreach ($k in $got.Keys) {
            $idx = [int]($k -split "@")[0]
            $page = [int]($k -split "@")[1]
            $state[$idx].pages[$page] = $got[$k]
        }
    }

    # Build curves
    $dps = @{}; $hps = @{}
    for ($i = 0; $i -lt $combos.Count; $i++) {
        $s = $state[$i]
        $c = $combos[$i]
        if ($null -eq $s.n -or $s.n -lt $MinParses) { continue }
        $curve = New-Object System.Collections.ArrayList
        foreach ($pct in $quantiles) {
            $rank = [int][math]::Max(1, [math]::Ceiling((100 - $pct) / 100 * $s.n))
            if ($rank -gt $s.n) { $rank = [int]$s.n }
            $page = [int]([math]::Floor(($rank - 1) / $pageSize) + 1)
            $idxInPage = ($rank - 1) % $pageSize
            $blob = $s.pages[$page]
            if ($null -ne $blob -and (Get-PageSize $blob) -gt $idxInPage) {
                $row = @($blob.rankings)[$idxInPage]
                $val = $row.amount
                if ($null -eq $val) { $val = $row.total }
                if ($null -ne $val) {
                    [void]$curve.Add(@($pct, [math]::Round([double]$val, 0)))
                }
            }
        }
        if ($curve.Count -ge 4) {
            $entry = @{ n = $s.n; curve = $curve }
            if ($c.metric -eq "dps") { $dps[$c.specID] = $entry } else { $hps[$c.specID] = $entry }
            Write-Host ("    [{0}] {1}: n={2}" -f $bracket.key, $c.key, $s.n)
        }
    }
    if ($dps.Count -gt 0 -or $hps.Count -gt 0) {
        $bracketSets[$bracket.key] = @{ dps = $dps; hps = $hps }
    }
    } # foreach bracket
    $encounters[$enc.name] = $bracketSets
}

Write-Host ("Total HTTP requests: {0}" -f $script:requestCount)

# ---- emit Lua (same shape as V1 script) ----
$lines = New-Object System.Collections.ArrayList
function Emit($s) { [void]$script:lines.Add($s) }
function Emit-CurveTable($indent, $name, $tbl) {
    Emit ("$indent$name = {")
    foreach ($specID in ($tbl.Keys | Sort-Object)) {
        $entry = $tbl[$specID]
        $points = ($entry.curve | ForEach-Object { "{ $($_[0]), $($_[1]) }" }) -join ", "
        Emit ("$indent`t[{0}] = {{ n = {1}, curve = {{ {2} }} }}," -f $specID, $entry.n, $points)
    }
    Emit ("$indent},")
}
Emit "-- GENERATED by scripts\fetch-percentiles-v2.ps1 - do not edit by hand."
Emit "-- Per-encounter, per-BRACKET (difficulty/size), per-spec percentile"
Emit "-- curves sampled from the full WCL ranked population (metric value at"
Emit "-- p99..p10). Raw mode interpolates a player's per-second output into"
Emit "-- the curve matching their fight's bracket, producing a true WCL-style"
Emit "-- percentile. Same staleness rules as Benchmarks: regenerate per patch."
Emit "local _, TP = ..."
Emit ""
Emit "TP.Percentiles = {"
Emit ("`tgenerated = `"{0}`"," -f (Get-Date -Format "yyyy-MM-dd"))
Emit ("`tzone = `"{0}`"," -f $zone.name)
Emit "`tencounters = {"
foreach ($name in ($encounters.Keys | Sort-Object)) {
    $bracketSets = $encounters[$name]
    if ($bracketSets.Count -eq 0) { continue }
    Emit ("`t`t[`"{0}`"] = {{" -f ($name -replace '"', '\"'))
    foreach ($bk in ($bracketSets.Keys | Sort-Object)) {
        $set = $bracketSets[$bk]
        Emit ("`t`t`t[`"{0}`"] = {{" -f $bk)
        Emit-CurveTable "`t`t`t`t" "dps" $set.dps
        Emit-CurveTable "`t`t`t`t" "hps" $set.hps
        Emit "`t`t`t},"
    }
    Emit "`t`t},"
}
Emit "`t},"
Emit "}"

$outPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Data\$OutFile"
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath"
