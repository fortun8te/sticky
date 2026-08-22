$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
dotnet build (Join-Path $root "windows/StickyWin/StickyWin.csproj") -c Release
