# Sequential LFR + Sporefall crawls (one process: WCL V2 tokens are
# single-active, so crawls must never overlap).
$repo = Split-Path $PSScriptRoot -Parent
$steps = @(
    @("fetch-percentiles-v2.ps1", "-ZoneId", "46", "-Brackets", "1", "-OutFile", "Percentiles_LFR.lua"),
    @("fetch-percentiles-v2.ps1", "-ZoneId", "50", "-Brackets", "1,3,4,5", "-OutFile", "Percentiles_Sporefall.lua"),
    @("fetch-killtimes.ps1", "-ZoneId", "46", "-Brackets", "1", "-OutFile", "KillTimes_LFR.lua"),
    @("fetch-killtimes.ps1", "-ZoneId", "50", "-Brackets", "1,3,4,5", "-OutFile", "KillTimes_Sporefall.lua"),
    @("fetch-percentiles-v2.ps1", "-GameBase", "https://classic.warcraftlogs.com", "-ZoneId", "1054", "-Brackets", "1x25", "-OutFile", "Percentiles_Mists_LFR.lua"),
    @("fetch-killtimes.ps1", "-GameBase", "https://classic.warcraftlogs.com", "-ZoneId", "1054", "-Brackets", "1x25", "-OutFile", "KillTimes_Mists_LFR.lua")
)
foreach ($step in $steps) {
    $script = $step[0]
    $stepArgs = $step[1..($step.Count - 1)]
    Write-Output ("===== RUN {0} {1}" -f $script, ($stepArgs -join " "))
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\$script" @stepArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Output "step failed with exit $LASTEXITCODE; continuing to next"
    }
}
Write-Output "ALL LFR CRAWLS DONE"
