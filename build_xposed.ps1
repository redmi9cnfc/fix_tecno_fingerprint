# Builds the Transsion UDFPS HBM LSPosed module (no Gradle, no Android Studio).
# NOTE: ASCII only (Windows PowerShell 5.1 parses .ps1 as ANSI).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\build_xposed.ps1

param(
    [string]$Out = "$PSScriptRoot\out\TranssionUdfpsHbm.apk"
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$xmod = Join-Path $PSScriptRoot 'xmod'
$sdk  = 'C:\Program Files\Unity\Hub\Editor\2021.3.45f2\Editor\Data\PlaybackEngines\AndroidPlayer'
$java = Join-Path $sdk 'OpenJDK\bin\java.exe'
$javac = Join-Path $sdk 'OpenJDK\bin\javac.exe'
$jarTool = Join-Path $sdk 'OpenJDK\bin\jar.exe'
$keytool = Join-Path $sdk 'OpenJDK\bin\keytool.exe'
$androidJar = Join-Path $sdk 'SDK\platforms\android-35\android.jar'
$bt = Join-Path $sdk 'SDK\build-tools\34.0.0'
$aapt2 = Join-Path $bt 'aapt2.exe'
$zipalign = Join-Path $bt 'zipalign.exe'
$apksigner = Join-Path $bt 'apksigner.bat'
$d8jar = Join-Path $bt 'lib\d8.jar'

$build = Join-Path $here 'build'
$classes = Join-Path $build 'classes'
$dexDir = Join-Path $build 'dex'

foreach ($p in @($java, $javac, $androidJar, $aapt2, $zipalign, $apksigner, $d8jar)) {
    if (-not (Test-Path $p)) { throw "missing tool: $p" }
}

if (Test-Path $build) { Remove-Item $build -Recurse -Force }
New-Item -ItemType Directory -Force $classes, $dexDir | Out-Null
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null

Write-Host '[1/6] javac'
$sources = @()
$sources += (Get-ChildItem (Join-Path $xmod 'stubs') -Recurse -Filter *.java).FullName
$sources += (Get-ChildItem (Join-Path $xmod 'src')   -Recurse -Filter *.java).FullName
& $javac -source 8 -target 8 -nowarn -bootclasspath $androidJar -d $classes $sources
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }

# Xposed API stubs must NOT go into the module: real classes are provided by LSPosed.
Remove-Item (Join-Path $classes 'de') -Recurse -Force

Write-Host '[2/6] d8'
$moduleJar = Join-Path $build 'module.jar'
& $jarTool cf $moduleJar -C $classes .
if ($LASTEXITCODE -ne 0) { throw 'jar failed' }
& $java -cp $d8jar com.android.tools.r8.D8 --release --min-api 29 --lib $androidJar --output $dexDir $moduleJar
if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }

Write-Host '[3/6] aapt2'
$resZip = Join-Path $build 'res.zip'
$baseApk = Join-Path $build 'base.apk'
& $aapt2 compile --dir (Join-Path $xmod 'res') -o $resZip
if ($LASTEXITCODE -ne 0) { throw 'aapt2 compile failed' }
& $aapt2 link -o $baseApk -I $androidJar --manifest (Join-Path $xmod 'AndroidManifest.xml') -R $resZip -A (Join-Path $xmod 'assets') --auto-add-overlay
if ($LASTEXITCODE -ne 0) { throw 'aapt2 link failed' }

Write-Host '[4/6] add classes.dex'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($baseApk, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, (Join-Path $dexDir 'classes.dex'), 'classes.dex',
        [System.IO.Compression.CompressionLevel]::Optimal)
} finally { $zip.Dispose() }

Write-Host '[5/6] zipalign'
$aligned = Join-Path $build 'aligned.apk'
& $zipalign -f 4 $baseApk $aligned
if ($LASTEXITCODE -ne 0) { throw 'zipalign failed' }

Write-Host '[6/6] sign'
$ks = Join-Path $here 'hbm.jks'
if (-not (Test-Path $ks)) {
    & $keytool -genkeypair -keystore $ks -alias hbm -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass hbmpass -keypass hbmpass -storetype JKS `
        -dname 'CN=Transsion UDFPS HBM, O=Local, C=RU'
    if ($LASTEXITCODE -ne 0) { throw 'keytool failed' }
}
if (Test-Path $Out) { Remove-Item $Out -Force }
& $apksigner sign --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true `
    --ks $ks --ks-pass pass:hbmpass --key-pass pass:hbmpass --out $Out $aligned
if ($LASTEXITCODE -ne 0) { throw 'apksigner failed' }

Write-Host ''
Write-Host ("done: {0} ({1:N0} bytes)" -f $Out, (Get-Item $Out).Length) -ForegroundColor Green
& $apksigner verify --print-certs $Out | Select-Object -First 3

