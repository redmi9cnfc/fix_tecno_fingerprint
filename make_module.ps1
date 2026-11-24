# Builds a Magisk / KernelSU / APatch module containing SystemUI.
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\make_module.ps1
#   powershell -ExecutionPolicy Bypass -File .\make_module.ps1 -Apk .\out\SystemUI_signed.apk
#
# NOTE: keep this file ASCII-only, Windows PowerShell 5.1 parses .ps1 as ANSI.

param(
    [string]$Apk = "$PSScriptRoot\out\SystemUI_aligned.apk",
    [string]$Out = "$PSScriptRoot\out\systemui_transsion_hbm.zip",
    [switch]$AllowUnsigned
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path $Apk)) { throw "APK not found: $Apk" }

$bytes = [System.IO.File]::ReadAllBytes($Apk)
$ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
$hasV2 = $ascii.Contains('APK Sig Block 42')
$hasV1 = $false
$z = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    $hasV1 = @($z.Entries | Where-Object { $_.FullName -match '^META-INF/.*\.(RSA|DSA|EC)$' }).Count -gt 0
} finally { $z.Dispose() }

Write-Host ("APK : {0} ({1:N1} MB)" -f $Apk, ($bytes.Length / 1MB))
Write-Host ("sig : v2={0} v1={1}" -f $hasV2, $hasV1)

if (-not $hasV2) {
    if (-not $AllowUnsigned) {
        Write-Host ""
        Write-Host "APK is not signed with v2+ scheme, refusing to build the module." -ForegroundColor Red
        Write-Host "Sign it first (MT Manager / apksigner) and pass -Apk <signed.apk>." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "WARNING: APK is unsigned. Module will build, but customize.sh will abort on install." -ForegroundColor Yellow
}

if (Test-Path $Out) { Remove-Item $Out -Force }
$zip = [System.IO.Compression.ZipFile]::Open($Out, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $items = @(
        @{ Name = 'module.prop';  Path = (Join-Path $PSScriptRoot 'magisk\module.prop') },
        @{ Name = 'customize.sh'; Path = (Join-Path $PSScriptRoot 'magisk\customize.sh') },
        @{ Name = 'system.prop';  Path = (Join-Path $PSScriptRoot 'magisk\system.prop') },
        @{ Name = 'SystemUI.apk'; Path = $Apk }
    )
    foreach ($i in $items) {
        if (-not (Test-Path $i.Path)) { throw "missing file: $($i.Path)" }
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $i.Path, $i.Name, [System.IO.Compression.CompressionLevel]::Optimal)
        Write-Host ("  + {0}" -f $i.Name)
    }
} finally { $zip.Dispose() }

$outItem = Get-Item $Out
Write-Host ""
Write-Host ("Done: {0} ({1:N1} MB)" -f $outItem.FullName, ($outItem.Length / 1MB)) -ForegroundColor Green
