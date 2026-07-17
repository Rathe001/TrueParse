# Kill-time (fight speed) percentile fetcher. For each encounter+bracket,
# samples WCL's speed rankings at fixed percentiles and emits duration
# curves (seconds; p99 = fastest) that merge into TP.Percentiles as
# encounters[name][bracket].killTime = { n, curve }.
# Auth: same client file as fetch-percentiles-v2.ps1.
# Retail: powershell -File scripts\fetch-killtimes.ps1 -ZoneId 46 -Brackets "3,4,5"
# MoP:    powershell -File scripts\fetch-killtimes.ps1 -GameBase https://classic.warcraftlogs.com `
#           -ZoneId 1054 -Brackets "3x10,3x25" -OutFile KillTimes_Mists.lua
param(
    [string]$GameBase = "https://www.warcraftlogs.com",
    [int]$ZoneId = 46,
    [string]$Brackets = "",
    [int]$MinKills = 50,
    [string]$OutFile = "KillTimes.lua",
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
            Start-Sleep -Milliseconds 800
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

# points check between encounters: nap when close to the hourly cap
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

$zone = (Invoke-GQL "{ worldData { zone(id: $ZoneId) { name encounters { id name } } } }").worldData.zone
Write-Host ("Zone: {0} ({1} encounters)" -f $zone.name, $zone.encounters.Count)

# bracket spec -> fightRankings args + emit key
$bracketList = New-Object System.Collections.ArrayList
if ($Brackets -ne "") {
    foreach ($b in ($Brackets -split ",")) {
        $b = $b.Trim()
        if ($b -match "^(\d+)x(\d+)$") {
            [void]$bracketList.Add(@{ key = $b; args = ("difficulty: {0}, size: {1}" -f [int]$Matches[1], [int]$Matches[2]) })
        } else {
            [void]$bracketList.Add(@{ key = $b; args = ("difficulty: {0}" -f [int]$b) })
        }
    }
} else {
    [void]$bracketList.Add(@{ key = "all"; args = "" })
}

function Get-RankingsPage($encId, $bracketArgs, $page) {
    $extra = ""
    if ($bracketArgs -ne "") { $extra = ", $bracketArgs" }
    $q = "{ worldData { encounter(id: $encId) { fightRankings(metric: speed, page: $page$extra) } } }"
    return (Invoke-GQL $q).worldData.encounter.fightRankings
}

$PAGE_SIZE = 50 # verified live: fightRankings pages carry 50 entries
$QUANTS = @(99, 95, 90, 75, 50, 25, 10)

$results = @{}  # name -> bracketKey -> @{ n; curve (array of @(pct, seconds)) }

foreach ($enc in $zone.encounters) {
    Write-Host ("=== {0} ({1})" -f $enc.name, $enc.id)
    Assert-Points
    $encOut = @{}
    foreach ($bracket in $bracketList) {
        $first = Get-RankingsPage $enc.id $bracket.args 1
        if (-not $first -or -not $first.rankings -or $first.rankings.Count -eq 0) {
            Write-Host ("    [{0}] no rankings" -f $bracket.key)
            continue
        }
        # total: the count field is PER-PAGE (verified live: always 50), so
        # find the last non-empty page: exponential doubling then binary
        $lo = 1
        $hi = 2
        while ($hi -le 8192) {
            $probe = Get-RankingsPage $enc.id $bracket.args $hi
            if ($probe -and $probe.rankings -and $probe.rankings.Count -gt 0) {
                $lo = $hi
                $hi = $hi * 2
            } else {
                break
            }
        }
        while ($lo + 1 -lt $hi) {
            $mid = [int][math]::Floor(($lo + $hi) / 2)
            $probe = Get-RankingsPage $enc.id $bracket.args $mid
            if ($probe -and $probe.rankings -and $probe.rankings.Count -gt 0) {
                $lo = $mid
            } else {
                $hi = $mid
            }
        }
        $last = if ($lo -eq 1) { $first } else { Get-RankingsPage $enc.id $bracket.args $lo }
        $total = ($lo - 1) * $PAGE_SIZE + $last.rankings.Count
        if ($total -lt $MinKills) {
            Write-Host ("    [{0}] only {1} kills; skipping" -f $bracket.key, $total)
            continue
        }
        # ranks for each quantile (rank 1 = fastest); group by page
        $needed = @{}
        foreach ($p in $QUANTS) {
            $rank = [int][math]::Max(1, [math]::Round($total * (100 - $p) / 100))
            if ($rank -gt $total) { $rank = $total }
            $page = [int][math]::Floor(($rank - 1) / $PAGE_SIZE) + 1
            if (-not $needed.ContainsKey("$page")) { $needed["$page"] = @{} }
            $needed["$page"]["$p"] = $rank
        }
        $curve = @{}
        foreach ($pageKey in $needed.Keys) {
            $page = [int]$pageKey
            $data = if ($page -eq 1) { $first } else { Get-RankingsPage $enc.id $bracket.args $page }
            if (-not ($data -and $data.rankings)) { continue }
            foreach ($pKey in $needed[$pageKey].Keys) {
                $rank = $needed[$pageKey][$pKey]
                $idx = ($rank - 1) % $PAGE_SIZE
                if ($idx -lt $data.rankings.Count) {
                    $ms = [double]$data.rankings[$idx].duration
                    $curve["$pKey"] = [math]::Round($ms / 1000, 1)
                }
            }
        }
        if ($curve.Count -ge 4) {
            $encOut[$bracket.key] = @{ n = $total; curve = $curve }
            Write-Host ("    [{0}] n={1} p99={2}s p50={3}s" -f $bracket.key, $total, $curve["99"], $curve["50"])
        }
    }
    if ($encOut.Count -gt 0) { $results[$enc.name] = $encOut }
}

Write-Host ("Total HTTP requests: {0}" -f $script:requestCount)

# ---- emit merge-style Lua ----
$lines = New-Object System.Collections.ArrayList
function Emit($s) { [void]$script:lines.Add($s) }
Emit "-- GENERATED by scripts\fetch-killtimes.ps1 - do not edit by hand."
Emit "-- Kill-duration quantiles per encounter+bracket from WCL speed"
Emit "-- rankings (seconds; p99 = fastest). Merged into TP.Percentiles."
Emit "local _, TP = ..."
Emit ""
Emit "TP.Percentiles = TP.Percentiles or {}"
Emit "TP.Percentiles.encounters = TP.Percentiles.encounters or {}"
Emit "local E = TP.Percentiles.encounters"
Emit ""
Emit "local function put(name, bracket, killTime)"
Emit "`tE[name] = E[name] or {}"
Emit "`tE[name][bracket] = E[name][bracket] or {}"
Emit "`tE[name][bracket].killTime = killTime"
Emit "end"
Emit ""
foreach ($name in ($results.Keys | Sort-Object)) {
    foreach ($bk in ($results[$name].Keys | Sort-Object)) {
        $entry = $results[$name][$bk]
        $pts = New-Object System.Collections.ArrayList
        foreach ($p in $QUANTS) {
            if ($entry.curve.ContainsKey("$p")) {
                [void]$pts.Add("{ $p, $($entry.curve["$p"]) }")
            }
        }
        $points = $pts -join ", "
        Emit ("put(`"{0}`", `"{1}`", {{ n = {2}, curve = {{ {3} }} }})" -f ($name -replace '"', '\"'), $bk, $entry.n, $points)
    }
}
# Rooted -OutFile is used as-is (CI passes absolute paths); a bare name
# lands in the repo Data dir. Nested Join-Path keeps separators legal on
# the Linux runners ("Data\x" is a literal filename there, not a path).
$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile }
    else { Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path "Data" $OutFile) }
[System.IO.File]::WriteAllLines($outPath, $lines)
Write-Host "Wrote $outPath"
