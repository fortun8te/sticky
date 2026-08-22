$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$DotNet = Join-Path $env:USERPROFILE ".dotnet\dotnet.exe"
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    $DotNet = (Get-Command dotnet).Source
} elseif (-not (Test-Path $DotNet)) {
    throw "dotnet was not found."
}

$Output = Join-Path $Root "build/release/win-x64"
& $DotNet publish (Join-Path $Root "windows/StickyWin/StickyWin.csproj") `
    -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:EnableWindowsTargeting=true `
    -o $Output
Write-Host "Packaged $Output"
