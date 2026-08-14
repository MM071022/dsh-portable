# build.ps1 — build dsh-portable single-file exe from launcher.cs + embedded zips.
#
# Requires: Windows with .NET Framework (csc.exe ships with the OS).
#
# Usage:
#   .\build\build.ps1 -DshZip .\dsh.zip -NodeZip .\node.zip -Out .\dsh.exe
#
#   -DshZip   zip of the dsh package (root folder "dsh\" inside the zip)
#   -NodeZip  zip containing node.exe
#   -Source   launcher.cs path (default: this script's sibling launcher.cs)
#   -Icon     .ico to embed as the exe icon (default: sibling app.ico if present)
#   -Out      output exe path (default: .\dsh.exe)
#
# The launcher's Version constant lives in launcher.cs and decides the
# extraction directory under %LOCALAPPDATA%\dsh-exe\<version>.
param(
    [Parameter(Mandatory = $true)]
    [string]$DshZip,
    [Parameter(Mandatory = $true)]
    [string]$NodeZip,
    [string]$Source = (Join-Path $PSScriptRoot "launcher.cs"),
    [string]$Icon = "",
    [string]$Out = (Join-Path (Get-Location) "dsh.exe")
)

$ErrorActionPreference = "Stop"

function Find-Csc {
    foreach ($base in @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
    )) {
        $candidate = Join-Path $base "csc.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    throw ".NET Framework csc.exe not found; install .NET Framework 4.x"
}

foreach ($p in @($DshZip, $NodeZip, $Source)) {
    if (-not (Test-Path $p)) { throw "input not found: $p" }
}

$csc = Find-Csc
if ($Icon -eq "") {
    $defaultIcon = Join-Path $PSScriptRoot "app.ico"
    if (Test-Path $defaultIcon) { $Icon = $defaultIcon }
}
Write-Host "csc: $csc"
Write-Host "dsh.zip : $((Get-Item $DshZip).Length) bytes"
Write-Host "node.zip: $((Get-Item $NodeZip).Length) bytes"
if ($Icon -ne "" -and (Test-Path $Icon)) { Write-Host "icon    : $Icon" }

# Embed both zips under their plain names ("dsh.zip" / "node.zip") so the
# launcher's Assembly.GetManifestResourceStream(name) lookup works. Optionally
# embed the application icon resource.
$iconArgs = @()
if ($Icon -ne "" -and (Test-Path $Icon)) { $iconArgs = @("/win32icon:$Icon") }
& $csc /nologo /target:exe /out:$Out `
    /r:System.dll /r:System.Core.dll `
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll `
    /r:System.Net.Sockets.dll /r:System.Reflection.dll /r:System.Threading.dll `
    "/resource:$DshZip,dsh.zip" "/resource:$NodeZip,node.zip" `
    $iconArgs `
    $Source

if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

Write-Host "built: $Out ($((Get-Item $Out).Length) bytes)"
Write-Host "next: git commit the sources; publish dsh.exe as a GitHub Release asset"
