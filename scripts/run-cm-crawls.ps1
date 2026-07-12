# MoP Challenge Mode crawls (sequential; single-active WCL tokens).
$repo = Split-Path $PSScriptRoot -Parent
$steps = @(
    @("fetch-percentiles-v2.ps1", "-GameBase", "https://classic.warcraftlogs.com", "-ZoneId", "1039", "-OutFile", "Percentiles_Mists_Dungeons.lua"),
    @("fetch-killtimes.ps1", "-GameBase", "https://classic.warcraftlogs.com", "-ZoneId", "1039", "-OutFile", "KillTimes_Mists_Dungeons.lua")
)
foreach ($step in $steps) {
    $script = $step[0]
    $stepArgs = $step[1..($step.Count - 1)]
    Write-Output ("===== RUN {0} {1}" -f $script, ($stepArgs -join " "))
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\$script" @stepArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Output "step failed with exit $LASTEXITCODE; continuing"
    }
}
Write-Output "ALL CM CRAWLS DONE"
