# Creates a directory junction so WoW loads the addon straight from this repo.
# Junctions don't require admin rights (unlike symlinks).
param(
    [string]$WowPath = "C:\Program Files (x86)\World of Warcraft"
)

$addonsDir = Join-Path $WowPath "_retail_\Interface\AddOns"
$link = Join-Path $addonsDir "TrueParse"
$repo = Split-Path $PSScriptRoot -Parent

if (-not (Test-Path $addonsDir)) {
    Write-Error "AddOns folder not found: $addonsDir (pass -WowPath if WoW is installed elsewhere)"
    exit 1
}

if (Test-Path $link) {
    Write-Host "Already linked (or a folder exists): $link"
    exit 0
}

New-Item -ItemType Junction -Path $link -Target $repo | Out-Null
Write-Host "Linked $link -> $repo"
