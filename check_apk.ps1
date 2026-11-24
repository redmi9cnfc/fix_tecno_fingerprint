# Checks an APK before flashing: signature scheme + native lib / arsc alignment.
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\check_apk.ps1
#   powershell -ExecutionPolicy Bypass -File .\check_apk.ps1 -Apk .\out\SystemUI_signed.apk
#
# NOTE: ASCII only (PowerShell 5.1 reads .ps1 as ANSI).

param(
    [string]$Apk = "$PSScriptRoot\out\SystemUI_aligned.apk"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Apk)) { throw "APK not found: $Apk" }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$bytes = [System.IO.File]::ReadAllBytes($Apk)
$ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
$hasV2 = $ascii.Contains('APK Sig Block 42')
$hasV1 = $false
$zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try { $hasV1 = @($zip.Entries | Where-Object { $_.FullName -match '^META-INF/.*\.(RSA|DSA|EC)$' }).Count -gt 0 }
finally { $zip.Dispose() }

$code = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public class ZipCheck {
  public static List<string> Run(string path) {
    var res = new List<string>();
    var b = File.ReadAllBytes(path);
    int eocd = -1;
    for (int i = b.Length - 22; i >= 0 && i > b.Length - 65558; i--)
      if (BitConverter.ToUInt32(b, i) == 0x06054b50) { eocd = i; break; }
    if (eocd < 0) { res.Add("EOCD not found"); return res; }
    int cnt = BitConverter.ToUInt16(b, eocd + 10);
    long p = BitConverter.ToUInt32(b, eocd + 16);
    for (int i = 0; i < cnt; i++) {
      if (BitConverter.ToUInt32(b, (int)p) != 0x02014b50) break;
      int nlen = BitConverter.ToUInt16(b, (int)p + 28);
      int elen = BitConverter.ToUInt16(b, (int)p + 30);
      int clen = BitConverter.ToUInt16(b, (int)p + 32);
      int method = BitConverter.ToUInt16(b, (int)p + 10);
      long csize = BitConverter.ToUInt32(b, (int)p + 20);
      long usize = BitConverter.ToUInt32(b, (int)p + 24);
      uint lho = BitConverter.ToUInt32(b, (int)p + 42);
      string name = Encoding.UTF8.GetString(b, (int)p + 46, nlen);
      if (method == 0 && (name.EndsWith(".so") || name == "resources.arsc")) {
        int ln = BitConverter.ToUInt16(b, (int)lho + 26);
        int le = BitConverter.ToUInt16(b, (int)lho + 28);
        long data = lho + 30 + ln + le;
        long align = name.EndsWith(".so") ? 16384 : 4;
        res.Add(string.Format("{0,-40} off={1,-10} aligned_{2}={3} stored={4}",
          name, data, align, (data % align == 0), (csize == usize)));
      }
      p += 46 + nlen + elen + clen;
    }
    return res;
  }
}
'@
Add-Type -TypeDefinition $code -Language CSharp | Out-Null

Write-Host ("APK  : {0}" -f $Apk)
Write-Host ("size : {0:N1} MB" -f ($bytes.Length / 1MB))
Write-Host ("sig  : v2+={0} v1={1}" -f $hasV2, $hasV1) -ForegroundColor ($(if ($hasV2) { 'Green' } else { 'Red' }))

$fail = $false
foreach ($line in [ZipCheck]::Run($Apk)) {
    Write-Host ("       " + $line)
    if ($line -match 'aligned_\d+=False' -or $line -match 'stored=False') { $fail = $true }
}

if (-not $hasV2) { Write-Host "RESULT: not signed with v2+, do NOT flash." -ForegroundColor Red }
elseif ($fail)   { Write-Host "RESULT: alignment problem, run zipalign_apk.ps1 again (and sign after it)." -ForegroundColor Red }
else             { Write-Host "RESULT: OK" -ForegroundColor Green }
