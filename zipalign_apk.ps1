# Minimal zipalign replacement (no Android SDK needed).
# Aligns STORED entries: *.so -> 16384 bytes (covers 4K and 16K page devices),
# resources.arsc -> 4096, everything else -> 4.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\zipalign_apk.ps1
#   powershell -ExecutionPolicy Bypass -File .\zipalign_apk.ps1 -In .\out\SystemUI.apk -Out .\out\SystemUI_aligned.apk
#
# NOTE: ASCII only (PowerShell 5.1 reads .ps1 as ANSI).

param(
    [string]$In  = "$PSScriptRoot\out\SystemUI.apk",
    [string]$Out = "$PSScriptRoot\out\SystemUI_aligned.apk",
    [int]$SoAlign = 16384,
    [int]$ArscAlign = 4096,
    [int]$DefaultAlign = 4
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $In)) { throw "input not found: $In" }

$code = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public class ApkAligner
{
    class Ent
    {
        public byte[] NameRaw;
        public string Name;
        public int Flags, Method, Time, Date;
        public uint Crc, CS, US;
        public int Attr;
        public uint Lho;
        public byte[] ExtraLocal;
        public byte[] ExtraCd;
        public byte[] Comment;
    }

    static uint U32(byte[] b, long p) { return BitConverter.ToUInt32(b, (int)p); }
    static int I32(byte[] b, long p) { return BitConverter.ToInt32(b, (int)p); }
    static ushort U16(byte[] b, long p) { return BitConverter.ToUInt16(b, (int)p); }

    static List<Ent> Parse(byte[] b, out int eocd)
    {
        eocd = -1;
        for (int i = b.Length - 22; i >= 0 && i > b.Length - 65558; i--)
            if (U32(b, i) == 0x06054b50) { eocd = i; break; }
        if (eocd < 0) throw new Exception("EOCD not found");

        int cnt = U16(b, eocd + 10);
        long cdOff = U32(b, eocd + 16);
        var list = new List<Ent>();
        long p = cdOff;
        for (int i = 0; i < cnt; i++)
        {
            if (U32(b, p) != 0x02014b50) throw new Exception("bad central directory at " + p);
            var e = new Ent();
            e.Flags = U16(b, p + 8);
            e.Method = U16(b, p + 10);
            e.Time = U16(b, p + 12);
            e.Date = U16(b, p + 14);
            e.Crc = U32(b, p + 16);
            e.CS = U32(b, p + 20);
            e.US = U32(b, p + 24);
            int nlen = U16(b, p + 28), elen = U16(b, p + 30), clen = U16(b, p + 32);
            e.Attr = I32(b, p + 38);
            e.Lho = U32(b, p + 42);
            e.NameRaw = new byte[nlen];
            Array.Copy(b, p + 46, e.NameRaw, 0, nlen);
            e.Name = Encoding.UTF8.GetString(e.NameRaw);
            e.ExtraCd = new byte[elen];
            Array.Copy(b, p + 46 + nlen, e.ExtraCd, 0, elen);
            e.Comment = new byte[clen];
            Array.Copy(b, p + 46 + nlen + elen, e.Comment, 0, clen);
            list.Add(e);
            p += 46 + nlen + elen + clen;
        }
        byte[] tail = new byte[Math.Max(0, b.Length - (eocd + 22))];
        Array.Copy(b, eocd + 22, tail, 0, tail.Length);
        return list;
    }

    static void W16(Stream s, int v) { s.WriteByte((byte)(v & 0xff)); s.WriteByte((byte)((v >> 8) & 0xff)); }
    static void W32(Stream s, long v) { for (int i = 0; i < 4; i++) s.WriteByte((byte)((v >> (8 * i)) & 0xff)); }

    public static string Run(string src, string dst, int soAlign, int arscAlign, int defAlign)
    {
        byte[] b = File.ReadAllBytes(src);
        int eocd;
        var entries = Parse(b, out eocd);
        int cnt = entries.Count;
        byte[] comment = new byte[Math.Max(0, b.Length - (eocd + 22))];
        Array.Copy(b, eocd + 22, comment, 0, comment.Length);

        var lhos = new long[entries.Count];
        var report = new StringBuilder();

        using (var w = new FileStream(dst, FileMode.Create, FileAccess.Write))
        {
            long pos = 0;
            for (int i = 0; i < entries.Count; i++)
            {
                var e = entries[i];
                // local header: 30 + nlen + extra, data follows
                int ln = U16(b, e.Lho + 26);
                int le = U16(b, e.Lho + 28);
                e.ExtraLocal = new byte[le];
                Array.Copy(b, e.Lho + 30 + ln, e.ExtraLocal, 0, le);
                long dataOff = e.Lho + 30 + ln + le;

                int align = 4;
                if (e.Method == 0)
                {
                    if (e.Name.EndsWith(".so", StringComparison.OrdinalIgnoreCase)) align = soAlign;
                    else if (e.Name == "resources.arsc") align = arscAlign;
                    else align = defAlign;
                }
                if (align < 4) align = 4;

                int baseLen = e.ExtraLocal.Length;
                long minData = pos + 30 + e.Name.Length + baseLen + 4;
                int pad = (int)((align - (minData % align)) % align);
                int newExtraLen = baseLen + 4 + pad;
                byte[] newExtra = new byte[newExtraLen];
                Array.Copy(e.ExtraLocal, newExtra, baseLen);
                newExtra[baseLen] = 0x35;      // extra field id 0xD935 (alignment)
                newExtra[baseLen + 1] = 0xD9;
                newExtra[baseLen + 2] = (byte)(pad & 0xff);
                newExtra[baseLen + 3] = (byte)((pad >> 8) & 0xff);

                lhos[i] = pos;
                W32(w, 0x04034b50);
                W16(w, 20);                 // version needed
                W16(w, e.Flags);
                W16(w, e.Method);
                W16(w, e.Time);
                W16(w, e.Date);
                W32(w, e.Crc);
                W32(w, e.CS);
                W32(w, e.US);
                W16(w, e.Name.Length);
                W16(w, newExtraLen);
                w.Write(e.NameRaw, 0, e.NameRaw.Length);
                w.Write(newExtra, 0, newExtra.Length);

                long realData = pos + 30 + e.Name.Length + newExtraLen;
                if (e.Method == 0 && (realData % align) != 0)
                    report.AppendLine("MISALIGNED " + e.Name + " " + realData);

                // copy compressed data as-is
                long copy = e.CS;
                w.Write(b, (int)dataOff, (int)copy);
                long after = dataOff + copy;

                // data descriptor (bit 3)
                if ((e.Flags & 8) != 0)
                {
                    int dlen = 12;
                    if (after + 4 <= b.Length && U32(b, after) == 0x08074b50) dlen = 16;
                    w.Write(b, (int)after, dlen);
                    after += dlen;
                }
                pos = w.Position;
                if (realData % align == 0)
                    report.AppendLine(string.Format("{0,-40} off={1,-10} align={2}", e.Name, realData, align));
            }

            long cdStart = w.Position;
            for (int i = 0; i < entries.Count; i++)
            {
                var e = entries[i];
                W32(w, 0x02014b50);
                W16(w, 20);                 // version made by
                W16(w, 20);                 // version needed
                W16(w, e.Flags);
                W16(w, e.Method);
                W16(w, e.Time);
                W16(w, e.Date);
                W32(w, e.Crc);
                W32(w, e.CS);
                W32(w, e.US);
                W16(w, e.Name.Length);
                W16(w, e.ExtraCd.Length);
                W16(w, e.Comment.Length);
                W16(w, 0);                  // disk number start
                W16(w, 0);                  // internal attributes
                W32(w, e.Attr);
                W32(w, lhos[i]);
                w.Write(e.NameRaw, 0, e.NameRaw.Length);
                w.Write(e.ExtraCd, 0, e.ExtraCd.Length);
                w.Write(e.Comment, 0, e.Comment.Length);
            }
            long cdSize = w.Position - cdStart;

            W32(w, 0x06054b50);
            W16(w, 0); W16(w, 0);
            W16(w, entries.Count); W16(w, entries.Count);
            W32(w, cdSize);
            W32(w, cdStart);
            W16(w, comment.Length);
            w.Write(comment, 0, comment.Length);
        }
        return report.ToString();
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp | Out-Null

Write-Host ("in : {0}" -f $In)
$report = [ApkAligner]::Run($In, $Out, $SoAlign, $ArscAlign, $DefaultAlign)
$lines = $report -split "`r?`n" | Where-Object { $_ -match '\.so|resources\.arsc|^MISALIGNED' }
$lines | ForEach-Object { Write-Host "  $_" }
if ($report -match 'MISALIGNED') { Write-Host "ERROR: misaligned entries remain" -ForegroundColor Red; exit 1 }
Write-Host ("out: {0} ({1:N1} MB)" -f $Out, ((Get-Item $Out).Length / 1MB)) -ForegroundColor Green
