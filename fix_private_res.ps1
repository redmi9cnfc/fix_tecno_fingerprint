$ErrorActionPreference = 'Stop'
$res = 'C:\systemuiudps\apktool+3.0.3\SystemUI_src\res'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom   = New-Object System.Text.UTF8Encoding($true)
$xmlns     = 'xmlns:androidprv="http://schemas.android.com/apk/prv/res/android"'

$files = Get-ChildItem $res -Recurse -Filter *.xml
$changed = 0
$nsAdded = 0
$attrFixed = 0
$atFixed = 0
$noRoot = @()

foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($f.FullName, $utf8NoBom)
    $orig = $text

    if ($text.Contains('?android:^attr-private/')) {
        $n = ([regex]::Matches($text, [regex]::Escape('?android:^attr-private/'))).Count
        $text = $text.Replace('?android:^attr-private/', '?androidprv:attr/')
        $attrFixed += $n
        if (-not $text.Contains('xmlns:androidprv')) {
            $m = [regex]::Match($text, '<[A-Za-z_][A-Za-z0-9_.:-]*')
            if ($m.Success) {
                $insertAt = $m.Index + $m.Length
                $text = $text.Substring(0, $insertAt) + ' ' + $xmlns + $text.Substring($insertAt)
                $nsAdded++
            } else {
                $noRoot += $f.FullName
            }
        }
    }

    if ($text.Contains('@android:')) {
        $n = ([regex]::Matches($text, [regex]::Escape('@android:'))).Count
        $text = $text.Replace('@android:', '@*android:')
        $atFixed += $n
    }

    if ($text -ne $orig) {
        if ($hasBom) { [System.IO.File]::WriteAllText($f.FullName, $text, $utf8Bom) }
        else         { [System.IO.File]::WriteAllText($f.FullName, $text, $utf8NoBom) }
        $changed++
    }
}

Write-Host "files_changed=$changed xmlns_added=$nsAdded attr_private_fixed=$attrFixed at_android_fixed=$atFixed"
if ($noRoot.Count -gt 0) { Write-Host "NO ROOT TAG:"; $noRoot | ForEach-Object { Write-Host $_ } }
