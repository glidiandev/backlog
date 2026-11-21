<#
.SYNOPSIS
  Backlog library sync for Windows (Windows PowerShell 5.1, nothing to install).

.DESCRIPTION
  The Backlog screensaver page runs walled off: no Steam API, no network. This script reads your Steam files (read
  only), copies your games' art and newest screenshots into the screensaver folder, and writes library\library.js,
  which sets window.BACKLOG_LIBRARY. Big art and screenshots are scaled down and re-encoded with System.Drawing.

  Reads: steamapps\libraryfolders.vdf + appmanifest_*.acf (installed games), userdata\<id>\config\localconfig.vdf
  (Playtime, LastPlayed), config\loginusers.vdf (last account, persona name), appcache\appinfo.vdf (names and types),
  appcache\librarycache\ (art), userdata\<id>\config\grid\ (your custom art, wins), userdata\<id>\config\shortcuts.vdf
  (non-Steam games with custom art), userdata\<id>\760\remote\<appid>\screenshots\, userdata\<id>\config\cloudstorage\
  and localconfig.vdf (the games you hid in Steam, left out unless config.js says showHidden: true).

  Optional online refresh: with your own Steam Web API key (-ApiKey, STEAM_API_KEY, or
  %APPDATA%\backlog\steam-api-key.txt), playtime and last played come from Steam for every device, games played only
  elsewhere are added, and their art comes from Steam's public store CDN. See tools\README.md.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\sync.ps1 -Install
  Copies this repo's backlog folder into Steam (keeping your config.js), then syncs into it.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\sync.ps1 -Target C:\path\to\backlog -MaxScreenshots 40
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\sync.ps1 -Install -Scenes mosaic,drift -Minutes 5
  Installs, plays only Mosaic and Drift, five minutes each. Works without -Install too, to change your mind later.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\sync.ps1 -ScheduleDaily
  Registers a per-user scheduled task "Backlog library sync" that re-runs this sync at logon and every day at 4:00.
  -Unschedule removes it.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\sync.ps1 -Target backlog -Reset
  Removes the synced library and puts back the placeholder library.js (Backlog then shows its demo library).
#>
[CmdletBinding()]
param(
  [string]$Target,
  [switch]$Install,
  [int]$MaxScreenshots = 60,
  [int]$MaxGames = 0,
  [switch]$IncludeUnplayed,
  [switch]$NoShortcuts,
  [string]$Account,
  [switch]$ListAccounts,
  [string]$Steam,
  [switch]$ScheduleDaily,
  [switch]$Unschedule,
  [switch]$Reset,
  # Which scenes play, in order, as a comma list (mosaic, drift, flip, ripple, ripple2), and how many minutes
  # each stays. Written into the installed config.js; leave them out and config.js is not touched.
  [string]$Scenes,
  [double]$Minutes = 0,
  # What the clock corner shows: all, clock (the time and date only) or none.
  [string]$Clock,
  # Optional: your own Steam Web API key, for up-to-date playtime from every device. Also read from the STEAM_API_KEY
  # environment variable or %APPDATA%\backlog\steam-api-key.txt. Never written anywhere, never printed.
  [string]$ApiKey,
  # Test only: a JSON file used in place of the GetOwnedGames call, and a stand-in for the store art CDN.
  [string]$ApiResponseFile,
  [string]$CdnBase = 'https://shared.steamstatic.com/store_item_assets/steam/apps'
)
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ helpers in C# (compiled once per run, .NET Framework only)
$cs = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Text;

public static class BacklogVdf
{
    // ---------- text KeyValues -> case-insensitive dictionaries
    public static Dictionary<string, object> ParseText(string t)
    {
        int i = 0;
        return Block(t, ref i);
    }

    static Dictionary<string, object> NewDict() { return new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase); }

    static string Token(string t, ref int i, out bool quoted)
    {
        quoted = false;
        int n = t.Length;
        while (i < n)
        {
            char c = t[i];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\uFEFF') { i++; continue; }
            if (c == '/' && i + 1 < n && t[i + 1] == '/') { int j = t.IndexOf('\n', i); i = j < 0 ? n : j + 1; continue; }
            break;
        }
        if (i >= n) return null;
        char ch = t[i];
        if (ch == '{' || ch == '}') { i++; return ch.ToString(); }
        if (ch == '"')
        {
            quoted = true; i++;
            var sb = new StringBuilder();
            while (i < n && t[i] != '"')
            {
                if (t[i] == '\\' && i + 1 < n)
                {
                    char x = t[i + 1];
                    if (x == 'n') sb.Append('\n'); else if (x == 't') sb.Append('\t');
                    else if (x == '\\' || x == '"') sb.Append(x); else { sb.Append('\\'); sb.Append(x); }
                    i += 2;
                }
                else sb.Append(t[i++]);
            }
            i++;
            return sb.ToString();
        }
        int s = i;
        while (i < n && " \t\r\n{}\"".IndexOf(t[i]) < 0) i++;
        return t.Substring(s, i - s);
    }

    static Dictionary<string, object> Block(string t, ref int i)
    {
        var d = NewDict();
        string key = null;
        while (true)
        {
            bool q;
            string tok = Token(t, ref i, out q);
            if (tok == null || (!q && tok == "}")) return d;
            if (!q && tok == "{") { d[key ?? ""] = Block(t, ref i); key = null; }
            else if (key == null) key = tok;
            else
            {
                if (!q && tok.StartsWith("[$") && tok.EndsWith("]")) continue;
                d[key] = tok; key = null;
            }
        }
    }

    public static object Get(object d, params string[] path)
    {
        foreach (var k in path)
        {
            var dd = d as IDictionary;
            if (dd == null) return null;
            object v = null;
            foreach (DictionaryEntry e in dd) if (string.Equals((string)e.Key, k, StringComparison.OrdinalIgnoreCase)) { v = e.Value; break; }
            if (v == null) return null;
            d = v;
        }
        return d;
    }

    // ---------- binary KeyValues
    class Bin
    {
        public byte[] B; public string[] Strings;
        public string CStr(ref int p) { int e = Array.IndexOf(B, (byte)0, p); string s = Encoding.UTF8.GetString(B, p, e - p); p = e + 1; return s; }
        public string Key(ref int p) { if (Strings != null) { int k = BitConverter.ToInt32(B, p); p += 4; return Strings[k]; } return CStr(ref p); }
        public object Value(byte t, ref int p)
        {
            switch (t)
            {
                case 0: return Section(ref p, null);
                case 1: return CStr(ref p);
                case 5: { int e = p; while (B[e] != 0 || B[e + 1] != 0) e += 2; string s = Encoding.Unicode.GetString(B, p, e - p); p = e + 2; return s; }
                case 2: case 4: case 6: { int v = BitConverter.ToInt32(B, p); p += 4; return v; }
                case 3: { float v = BitConverter.ToSingle(B, p); p += 4; return v; }
                case 7: { ulong v = BitConverter.ToUInt64(B, p); p += 8; return v; }
                case 10: { long v = BitConverter.ToInt64(B, p); p += 8; return v; }
                default: throw new InvalidDataException("unknown KeyValues type " + t + " at " + p);
            }
        }
        public Dictionary<string, object> Section(ref int p, string stopAfter)
        {
            var d = NewDict();
            while (true)
            {
                byte t = B[p++];
                if (t == 8 || t == 11) return d;
                string k = Key(ref p);
                d[k] = Value(t, ref p);
                if (stopAfter != null && string.Equals(k, stopAfter, StringComparison.OrdinalIgnoreCase)) return d;
            }
        }
    }

    public class AppInfo { public Dictionary<uint, string[]> Apps = new Dictionary<uint, string[]>(); public string Status = "ok"; }

    // appid -> { name, type } for the wanted appids only (others are skipped by their size field).
    public static AppInfo ReadAppInfo(string path, uint[] wantedList)
    {
        var r = new AppInfo();
        var wanted = new HashSet<uint>(wantedList);
        byte[] b;
        try { b = File.ReadAllBytes(path); } catch (Exception) { r.Status = "missing"; return r; }
        uint magic = BitConverter.ToUInt32(b, 0);
        int p = 8;
        var bin = new Bin { B = b };
        if (magic >= 0x07564429)
        {
            long table = BitConverter.ToInt64(b, p); p += 8;
            int q = (int)table, count = BitConverter.ToInt32(b, q); q += 4;
            bin.Strings = new string[count];
            for (int i = 0; i < count; i++) bin.Strings[i] = bin.CStr(ref q);
        }
        else if (magic != 0x07564427 && magic != 0x07564428) { r.Status = "unknown format 0x" + magic.ToString("X8"); return r; }
        int header = 4 + 4 + 8 + 20 + 4 + (magic >= 0x07564428 ? 20 : 0);
        try
        {
            while (p + 8 <= b.Length)
            {
                uint appid = BitConverter.ToUInt32(b, p);
                if (appid == 0) break;
                int next = p + 8 + (int)BitConverter.ToUInt32(b, p + 4);
                if (wanted.Contains(appid))
                {
                    int q = p + 8 + header;
                    byte t = b[q++];
                    bin.Key(ref q);
                    if (t == 0)
                    {
                        var info = bin.Section(ref q, "common");
                        var name = Get(info, "common", "name") as string;
                        var type = Get(info, "common", "type") as string;
                        r.Apps[appid] = new string[] { name, type == null ? null : type.ToLowerInvariant() };
                    }
                }
                p = next;
            }
        }
        catch (Exception e) { r.Status = "stopped early (" + e.Message + ")"; }
        return r;
    }

    // Non-Steam shortcuts: { appid (uint as long), name, lastPlayed }.
    public static List<Hashtable> ReadShortcuts(string path)
    {
        var list = new List<Hashtable>();
        byte[] b;
        try { b = File.ReadAllBytes(path); } catch (Exception) { return list; }
        Dictionary<string, object> root;
        try
        {
            var bin = new Bin { B = b };
            int p = 1;
            bin.Key(ref p);
            if (b[0] != 0) return list;
            root = bin.Section(ref p, null);
        }
        catch (Exception) { return list; }
        foreach (var kv in root)
        {
            var e = kv.Value as Dictionary<string, object>;
            if (e == null) continue;
            var name = Get(e, "AppName") as string;
            var exe = (Get(e, "Exe") as string) ?? "";
            if (string.IsNullOrWhiteSpace(name)) continue;
            var hidden = Get(e, "IsHidden");
            if (hidden is int && (int)hidden == 1) continue;
            var aidObj = Get(e, "appid");
            uint aid;
            if (aidObj is int && (int)aidObj != 0) aid = unchecked((uint)(int)aidObj);
            else aid = Crc32(Encoding.UTF8.GetBytes(exe + name)) | 0x80000000u; // older files: Steam's derived id
            var lp = Get(e, "LastPlayTime");
            var h = new Hashtable();
            h["appid"] = (long)aid; h["name"] = name.Trim(); h["lastPlayed"] = (long)Math.Max(0, lp is int ? (int)lp : 0);
            list.Add(h);
        }
        return list;
    }

    public static uint Crc32(byte[] data)
    {
        uint crc = 0xFFFFFFFF;
        foreach (byte x in data)
        {
            crc ^= x;
            for (int k = 0; k < 8; k++) crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
        }
        return ~crc;
    }

    // ---------- images: copy, or scale down / re-encode when big. Returns the path written (extension may change).
    public static string Shrink(string src, string dstNoExt, int maxW, int maxH, long reencodeOver, int quality, bool keepAlpha)
    {
        string ext = Path.GetExtension(src).ToLowerInvariant();
        long size = new FileInfo(src).Length;
        if (ext == ".gif" || ext == ".webp") { string d0 = dstNoExt + ext; File.Copy(src, d0, true); return d0; }
        try
        {
            using (var fs = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var img = Image.FromStream(fs, false, false))
            {
                double scale = Math.Min(1.0, Math.Min((double)maxW / img.Width, (double)maxH / img.Height));
                bool png = keepAlpha && ext == ".png";
                if (scale >= 1.0 && size <= reencodeOver) { string d1 = dstNoExt + (ext == ".jpeg" ? ".jpg" : ext); File.Copy(src, d1, true); return d1; }
                ImageCodecInfo jpg = null;
                foreach (var c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") jpg = c;
                if (scale >= 1.0 && !png)
                {
                    // Same size, just too heavy: re-encode without resampling (fast).
                    string d3 = dstNoExt + ".jpg";
                    using (var ep = new EncoderParameters(1))
                    {
                        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
                        img.Save(d3, jpg, ep);
                    }
                    if (new FileInfo(d3).Length >= size && (ext == ".jpg" || ext == ".jpeg")) File.Copy(src, d3, true);
                    return d3;
                }
                int w = Math.Max(1, (int)Math.Round(img.Width * scale)), h = Math.Max(1, (int)Math.Round(img.Height * scale));
                using (var bmp = new Bitmap(w, h, png ? PixelFormat.Format32bppArgb : PixelFormat.Format24bppRgb))
                {
                    using (var g = Graphics.FromImage(bmp))
                    using (var attr = new ImageAttributes())
                    {
                        g.CompositingMode = CompositingMode.SourceCopy;
                        g.CompositingQuality = CompositingQuality.HighQuality;
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        g.SmoothingMode = SmoothingMode.HighQuality;
                        attr.SetWrapMode(WrapMode.TileFlipXY);
                        if (!png) g.Clear(Color.Black);
                        g.DrawImage(img, new Rectangle(0, 0, w, h), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, attr);
                    }
                    string dst = dstNoExt + (png ? ".png" : ".jpg");
                    if (png) bmp.Save(dst, ImageFormat.Png);
                    else
                    {
                        using (var ep = new EncoderParameters(1))
                        {
                            ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
                            bmp.Save(dst, jpg, ep);
                        }
                    }
                    // Same size and no smaller after re-encoding: keep the original bytes.
                    if (scale >= 1.0 && new FileInfo(dst).Length >= size && string.Equals(Path.GetExtension(dst), ext == ".jpeg" ? ".jpg" : ext, StringComparison.OrdinalIgnoreCase))
                        File.Copy(src, dst, true);
                    return dst;
                }
            }
        }
        catch (Exception)
        {
            string d2 = dstNoExt + (ext == ".jpeg" ? ".jpg" : ext);
            File.Copy(src, d2, true);
            return d2;
        }
    }
}
'@
if (-not ('BacklogVdf' -as [type])) { Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing }

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { if ($VerbosePreference -ne 'SilentlyContinue') { $m = ('[{0,5:N1}s] ' -f $stopwatch.Elapsed.TotalSeconds) + $m }; Write-Host $m }
function ToInt($v) { $n = 0L; if ($null -ne $v -and [long]::TryParse(([string]$v).Trim(), [ref]$n)) { return $n } return 0L }
# A folder name or a cache key as an app id, or -1 when it isn't one. A non-Steam game is filed under its 64-bit game
# id (appid << 32 | 0x02000000), which is too big for Int64: it becomes the unsigned 32-bit appid that game has
# everywhere else here.
function ToAppId($v) {
  $n = [decimal]0
  try {
    $n = if ($v -is [string]) { [decimal]::Parse($v.Trim(), [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture) } else { [decimal]$v }
  } catch { return -1L }
  if ($n -ne [math]::Floor($n)) { return -1L }
  if ($n -gt 4294967295) { $n = [math]::Floor($n / 4294967296) }
  if ($n -lt 0 -or $n -gt 4294967295) { return -1L }
  return [long]$n
}
function ReadVdf([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return @{} }
  return [BacklogVdf]::ParseText([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
}
function G($d) { return [BacklogVdf]::Get($d, [string[]]$args) }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'Backlog library sync'

if ($Unschedule) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Log "Removed the scheduled task '$taskName' (if it existed)."
  return
}

# ------------------------------------------------------------------ Steam and the account
function Find-Steam {
  $c = @()
  if ($Steam) { $c += $Steam }
  try { $c += ((Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath -replace '/', '\') } catch {}
  $c += 'C:\Program Files (x86)\Steam'
  foreach ($p in $c) {
    if ($p -and ((Test-Path -LiteralPath (Join-Path $p 'steamapps')) -or (Test-Path -LiteralPath (Join-Path $p 'userdata')))) {
      return (Resolve-Path -LiteralPath $p).ProviderPath
    }
  }
  return $null
}
$steamDir = Find-Steam
if (-not $steamDir) { throw 'Steam was not found. Pass -Steam <folder>.' }
Log "Steam: $steamDir"

$base64 = 76561197960265728
$users = G (ReadVdf (Join-Path $steamDir 'config\loginusers.vdf')) 'users'
$userdataDir = Join-Path $steamDir 'userdata'
$have = @{}
if (Test-Path -LiteralPath $userdataDir) {
  Get-ChildItem -LiteralPath $userdataDir -Directory | Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' } | ForEach-Object { $have[$_.Name] = $true }
}
$accts = New-Object System.Collections.ArrayList
$seen = @{}
if ($users) {
  foreach ($sid in @($users.Keys)) {
    if ($sid -notmatch '^\d+$') { continue }
    $id64 = [decimal]$sid
    $acc = if ($id64 -gt $base64) { [string]($id64 - $base64) } else { $sid }
    if (-not $have[$acc]) { continue }
    $u = $users[$sid]
    $seen[$acc] = $true
    [void]$accts.Add([pscustomobject]@{ Id = $acc; Id64 = $sid; Persona = [string](G $u 'PersonaName'); Recent = (ToInt (G $u 'MostRecent')); Stamp = (ToInt (G $u 'Timestamp')) })
  }
}
foreach ($acc in @($have.Keys)) {
  if ($seen[$acc]) { continue }
  $lcf = Join-Path $userdataDir "$acc\config\localconfig.vdf"
  $stamp = if (Test-Path -LiteralPath $lcf) { [DateTimeOffset]::new((Get-Item -LiteralPath $lcf).LastWriteTimeUtc).ToUnixTimeSeconds() } else { 0 }
  [void]$accts.Add([pscustomobject]@{ Id = $acc; Id64 = ''; Persona = ''; Recent = 0; Stamp = $stamp })
}
$accts = @($accts | Sort-Object -Property @{ Expression = 'Recent'; Descending = $true }, @{ Expression = 'Stamp'; Descending = $true })

if ($ListAccounts) {
  foreach ($a in $accts) { Log ("  {0}  {1}{2}" -f $a.Id, $(if ($a.Persona) { $a.Persona } else { '(no name)' }), $(if ($a.Recent) { '  (last logged in)' } else { '' })) }
  return
}
if (-not $accts.Count) { throw 'No Steam account with a userdata folder was found.' }
$acct = $accts[0]
if ($Account) {
  $want = $Account.Trim()
  $m = @($accts | Where-Object { $_.Id -eq $want -or $_.Id64 -eq $want -or $_.Persona -eq $want })
  if (-not $m.Count) { throw "No account matches '$Account'. Try -ListAccounts." }
  $acct = $m[0]
}
$userDir = Join-Path $userdataDir $acct.Id
Log ("Account: " + $(if ($acct.Persona) { $acct.Persona } else { '(no name)' }))

# ------------------------------------------------------------------ target, install, schedule
$installedDir = Join-Path $steamDir 'config\uioverrides\screensavers\backlog'
$targetDir = if ($Target) { [IO.Path]::GetFullPath($Target) } else { $installedDir }

if ($Install) {
  $src = Join-Path (Split-Path -Parent $here) 'backlog'
  if (-not (Test-Path -LiteralPath (Join-Path $src 'index.html'))) { throw "-Install: no backlog folder next to tools\ ($src)" }
  Log "Installing Backlog into $targetDir"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $src -Force) {
    $dst = Join-Path $targetDir $item.Name
    if ($item.Name -eq 'library') { New-Item -ItemType Directory -Force -Path $dst | Out-Null; continue }
    if ($item.Name -eq 'config.js' -and (Test-Path -LiteralPath $dst)) { Log '  kept your config.js'; continue }
    if ($item.PSIsContainer) {
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
      Copy-Item -LiteralPath $item.FullName -Destination $dst -Recurse -Force
    } else { Copy-Item -LiteralPath $item.FullName -Destination $dst -Force }
  }
}
if (-not (Test-Path -LiteralPath (Join-Path $targetDir 'index.html'))) { throw "No Backlog screensaver at $targetDir. Run with -Install, or pass -Target." }

# The choices: only those settings of config.js change; a line that is missing is added at the top of the settings.
if ($Scenes -or $Minutes -or $Clock) {
  $all = 'mosaic', 'drift', 'flip', 'ripple', 'ripple2'
  $picked = @()
  foreach ($n in ($Scenes -split ',')) { $n = $n.Trim().ToLower(); if ($n -and $picked -notcontains $n) { $picked += $n } }
  $bad = @($picked | Where-Object { $all -notcontains $_ })
  if ($bad.Count) { throw "-Scenes: pick from $($all -join ', ') (got '$Scenes')" }
  if ($Minutes -and ($Minutes -lt 0.25 -or $Minutes -gt 240)) { throw '-Minutes: between 0.25 and 240' }
  $cfgPath = Join-Path $targetDir 'config.js'
  $cfg = [IO.File]::ReadAllText($cfgPath)
  $nl = if ($cfg.Contains("`r`n")) { "`r`n" } else { "`n" }
  function PutLine([string]$text, [string]$pattern, [string]$key, [string]$value) {
    $rx = New-Object Text.RegularExpressions.Regex($pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($rx.IsMatch($text)) { return $rx.Replace($text, { param($m) $m.Groups[1].Value + $value }, 1) }
    $top = New-Object Text.RegularExpressions.Regex('(BACKLOG_CONFIG\s*=\s*\{[ \t]*\r?\n)')
    if (-not $top.IsMatch($text)) { throw "config.js does not look like a Backlog settings file: $cfgPath" }
    return $top.Replace($text, { param($m) $m.Groups[1].Value + "  ${key}: $value,$nl" }, 1)
  }
  if ($picked.Count) {
    $list = '[' + (($picked | ForEach-Object { "'$_'" }) -join ', ') + ']'
    $cfg = PutLine $cfg '^([ \t]*scenes:\s*)(?:\[[^\]]*\]|''[^'']*''|"[^"]*")' 'scenes' $list
    Log ("  scenes: " + ($picked -join ', '))
  }
  if ($Minutes) {
    $mv = $Minutes.ToString([Globalization.CultureInfo]::InvariantCulture)
    $cfg = PutLine $cfg '^([ \t]*minutesPerScene:\s*)[0-9.]+' 'minutesPerScene' $mv
    Log "  minutes per scene: $mv"
  }
  if ($Clock) {
    $choice = $Clock.Trim().ToLower()
    if ('all', 'clock', 'none' -notcontains $choice) { throw "-Clock: pick from all, clock, none (got '$Clock')" }
    $value = "'$choice'"
    $multi = [Text.RegularExpressions.RegexOptions]::Multiline
    $hasShow = New-Object Text.RegularExpressions.Regex('^((?![ \t]*//)[^\r\n]*?\bshow:\s*)(?:''[^''\r\n]*''|"[^"\r\n]*"|\{[^{}]*\})', $multi)
    $oneLine = New-Object Text.RegularExpressions.Regex('^([ \t]*clock:\s*\{[^{}\r\n]*?)[ \t]*\}', $multi)
    $anyClock = New-Object Text.RegularExpressions.Regex('^[ \t]*clock:', $multi)
    $top = New-Object Text.RegularExpressions.Regex('(BACKLOG_CONFIG\s*=\s*\{[ \t]*\r?\n)')
    $done = $true
    if ($hasShow.IsMatch($cfg)) { $cfg = $hasShow.Replace($cfg, { param($m) $m.Groups[1].Value + $value }, 1) }
    elseif ($oneLine.IsMatch($cfg)) { $cfg = $oneLine.Replace($cfg, { param($m) $m.Groups[1].Value + ", show: $value }" }, 1) }
    elseif (-not $anyClock.IsMatch($cfg) -and $top.IsMatch($cfg)) { $cfg = $top.Replace($cfg, { param($m) $m.Groups[1].Value + "  clock: { show: $value },$nl" }, 1) }
    else { $done = $false }
    if ($done) { Log ("  clock corner: " + @{ all = 'everything'; clock = 'the time and date only'; none = 'off' }[$choice]) }
    else { Log '  clock: left as it is (the clock setting in config.js is not in a shape the installer knows)' }
  }
  [IO.File]::WriteAllText($cfgPath, $cfg, (New-Object Text.UTF8Encoding $false))
}

if ($ScheduleDaily) {
  $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($MyInvocation.MyCommand.Path)`" -MaxScreenshots $MaxScreenshots"
  if ($Target) { $argList += " -Target `"$targetDir`"" }
  if ($Account) { $argList += " -Account `"$Account`"" }
  if ($IncludeUnplayed) { $argList += ' -IncludeUnplayed' }
  if ($MaxGames) { $argList += " -MaxGames $MaxGames" }
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $triggers = @((New-ScheduledTaskTrigger -AtLogOn -User $me), (New-ScheduledTaskTrigger -Daily -At '04:00'))
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Description 'Copies your Steam library art into the Backlog screensaver.' -Force | Out-Null
  Log "Scheduled '$taskName': at logon and daily at 04:00. Remove it with -Unschedule."
  if ($ApiKey) { Log "  The task doesn't store your API key. For online refresh it reads $env:APPDATA\backlog\steam-api-key.txt (or STEAM_API_KEY)." }
}

$lib = Join-Path $targetDir 'library'
New-Item -ItemType Directory -Force -Path $lib | Out-Null
if ($Reset) {
  foreach ($e in Get-ChildItem -LiteralPath $lib -Directory -ErrorAction SilentlyContinue) {
    if ($e.Name -match '^\d+$' -or $e.Name -eq 'shots') { Remove-Item -LiteralPath $e.FullName -Recurse -Force }
  }
  Remove-Item -LiteralPath (Join-Path $lib '.sources') -Force -ErrorAction SilentlyContinue
  $ph = "/* Written by the Backlog sync tool. Until you run it, Backlog shows a demo library. */`nwindow.BACKLOG_LIBRARY = null;`n"
  [IO.File]::WriteAllText((Join-Path $lib 'library.js'), $ph, (New-Object Text.UTF8Encoding $false))
  Log "Reset $lib to the placeholder: Backlog shows its demo library until the next sync."
  return
}

# ------------------------------------------------------------------ gather
$played = @{}
$scPlayed = @{}
$localConfig = ReadVdf (Join-Path $userDir 'config\localconfig.vdf')
$appsCfg = G $localConfig 'UserLocalConfigStore' 'Software' 'Valve' 'Steam' 'apps'
if ($appsCfg) {
  foreach ($k in @($appsCfg.Keys)) {
    if ($k -notmatch '^-?\d+$') { continue }
    $v = $appsCfg[$k]
    if ($v -isnot [System.Collections.IDictionary]) { continue }
    $pt = ToInt (G $v 'Playtime'); $lp = ToInt (G $v 'LastPlayed')
    if (-not ($pt -or $lp)) { continue }
    $n = [decimal]$k
    if ($n -gt 0 -and $n -lt 2147483648) { $played[[uint32]$n] = @{ playtime = $pt; lastPlayed = $lp }; continue }
    # A non-Steam shortcut, keyed by its unsigned 32-bit appid, the signed value, or the 64-bit game id
    # (appid << 32 | 0x02000000). Normalize to the unsigned appid; keep the biggest numbers seen.
    $sid = if ($n -gt 4294967295) { [uint32][math]::Floor($n / 4294967296) } elseif ($n -lt 0) { [uint32]($n + 4294967296) } else { [uint32]$n }
    $old = $scPlayed[$sid]
    if ($old) { $pt = [math]::Max($pt, $old.playtime); $lp = [math]::Max($lp, $old.lastPlayed) }
    $scPlayed[$sid] = @{ playtime = $pt; lastPlayed = $lp }
  }
}

$roots = New-Object System.Collections.ArrayList
[void]$roots.Add($steamDir)
$lf = ReadVdf (Join-Path $steamDir 'steamapps\libraryfolders.vdf')
$lfRoot = G $lf 'libraryfolders'
if (-not $lfRoot) { $lfRoot = $lf }
foreach ($k in @($lfRoot.Keys)) {
  $v = $lfRoot[$k]
  $p = if ($v -is [System.Collections.IDictionary]) { G $v 'path' } elseif ($k -match '^\d+$') { $v } else { $null }
  if ($p) { [void]$roots.Add([string]$p) }
}
$installed = @{}
$seenRoots = @{}
foreach ($r in $roots) {
  $sa = Join-Path $r 'steamapps'
  if (-not (Test-Path -LiteralPath $sa)) { continue }
  $key = (Resolve-Path -LiteralPath $sa).ProviderPath.ToLowerInvariant()
  if ($seenRoots[$key]) { continue }
  $seenRoots[$key] = $true
  foreach ($f in Get-ChildItem -LiteralPath $sa -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
    $st = G (ReadVdf $f.FullName) 'AppState'
    $aid = ToInt (G $st 'appid')
    if ($aid) { $installed[[uint32]$aid] = @{ name = [string](G $st 'name'); lastPlayed = (ToInt (G $st 'LastPlayed')) } }
  }
}

$cache = Join-Path $steamDir 'appcache\librarycache'
$cached = @{}
if (Test-Path -LiteralPath $cache) {
  foreach ($e in Get-ChildItem -LiteralPath $cache -Force) {
    if ($e.PSIsContainer -and $e.Name -match '^\d{1,9}$') { $cached[[uint32]$e.Name] = $true }
    elseif (-not $e.PSIsContainer -and $e.Name -match '^(\d{1,9})_') { $cached[[uint32]$Matches[1]] = $true }
  }
}
Log ("Found: {0} installed, {1} with playtime, {2} with cached art" -f $installed.Count, $played.Count, $cached.Count)

# ------------------------------------------------------------------ optional online refresh (your own Steam Web API key)
# This computer's numbers go stale when you play elsewhere (a Steam Deck, another PC). With a key, Steam's totals for
# every device win (the larger number, in case this PC played offline since). The key is never printed or written.
function Get-Http([string]$url, [int]$timeoutMs) {
  $req = [Net.HttpWebRequest]::Create($url)
  $req.Timeout = $timeoutMs; $req.ReadWriteTimeout = $timeoutMs; $req.UserAgent = 'Backlog-sync'
  $resp = $req.GetResponse()
  try { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); return , $ms.ToArray() } finally { $resp.Close() }
}
function Test-Image([byte[]]$b) {
  return ($b -and $b.Length -gt 8 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) -or ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47)))
}
$apiNames = @{}
$apiOwned = @{}
$keyFile = Join-Path $env:APPDATA 'backlog\steam-api-key.txt'
$key = $null; $keyFrom = $null
if ($ApiKey) { $key = $ApiKey.Trim(); $keyFrom = '-ApiKey' }
elseif ($env:STEAM_API_KEY -and $env:STEAM_API_KEY.Trim()) { $key = $env:STEAM_API_KEY.Trim(); $keyFrom = 'STEAM_API_KEY' }
elseif (Test-Path -LiteralPath $keyFile) { $k = ([IO.File]::ReadAllText($keyFile)).Trim(); if ($k) { $key = $k; $keyFrom = $keyFile } }
if ($key -or $ApiResponseFile) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $owned = $null; $msg = $null
  if ($ApiResponseFile) {
    Log "Online: TEST response from $ApiResponseFile"
    $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ApiResponseFile).ProviderPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  } elseif ($key -notmatch '^[0-9A-Fa-f]{32}$') {
    $msg = "the API key doesn't look like a Steam Web API key (32 letters and digits); skipped"
  } else {
    $id64 = if ($acct.Id64) { $acct.Id64 } else { [string]([decimal]$acct.Id + $base64) }
    $url = 'https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key={0}&steamid={1}&include_appinfo=1&include_played_free_games=1&format=json' -f $key, $id64
    try { $body = [Text.Encoding]::UTF8.GetString((Get-Http $url 30000)) | ConvertFrom-Json }
    catch {
      $we = $_.Exception.InnerException
      if (-not $we) { $we = $_.Exception }
      $code = if ($we -is [Net.WebException] -and $we.Response) { [int]$we.Response.StatusCode } else { 0 }
      $msg = if ($code -eq 401 -or $code -eq 403) { "Steam refused the API key (HTTP $code); using local data only" }
             elseif ($code) { "Steam Web API error (HTTP $code); using local data only" }
             else { "could not reach the Steam Web API ($($we.GetType().Name)); using local data only" }
    }
    $url = $null
  }
  if (-not $msg) {
    $owned = @($body.response.games | Where-Object { $_ })
    if (-not $owned.Count) { $msg = 'Steam returned no games for this account. Its game details are probably private: Steam > your profile > Edit Profile > Privacy Settings > Game details: Public. Using local data only.' }
  }
  if ($msg) { Log "Online: $msg" }
  else {
    $changed = 0; $added = 0
    foreach ($o in $owned) {
      $aid = ToInt $o.appid
      if ($aid -le 0 -or $aid -ge 2147483648) { continue }
      $aid = [uint32]$aid
      $apiOwned[$aid] = $true
      if ($o.name -and ([string]$o.name).Trim()) { $apiNames[$aid] = ([string]$o.name).Trim() }
      $pt = ToInt $o.playtime_forever; $lp = ToInt $o.rtime_last_played
      if (-not ($pt -or $lp)) { continue }
      $old = $played[$aid]
      if (-not $old) { $added++; $played[$aid] = @{ playtime = $pt; lastPlayed = $lp } }
      else {
        $np = [math]::Max($pt, $old.playtime); $nl = [math]::Max($lp, $old.lastPlayed)
        if ($np -ne $old.playtime -or $nl -ne $old.lastPlayed) { $changed++ }
        $played[$aid] = @{ playtime = $np; lastPlayed = $nl }
      }
    }
    Log ("Online: {0} owned games from Steam (key from {1}); {2} updated, {3} this computer never saw" -f $owned.Count, $(if ($keyFrom) { $keyFrom } else { 'test file' }), $changed, $added)
  }
}
$key = $null; $ApiKey = $null

$wanted = @{}
foreach ($h in @($installed, $played, $cached)) { foreach ($k in $h.Keys) { $wanted[[uint32]$k] = $true } }
if ($IncludeUnplayed) { foreach ($k in $apiOwned.Keys) { $wanted[[uint32]$k] = $true } }
$ai = [BacklogVdf]::ReadAppInfo((Join-Path $steamDir 'appcache\appinfo.vdf'), [uint32[]]@($wanted.Keys))
Log ("appinfo.vdf: {0}, {1} of {2} apps named" -f $ai.Status, $ai.Apps.Count, $wanted.Count)

$gridDir = Join-Path $userDir 'config\grid'
$grid = @{}
if (Test-Path -LiteralPath $gridDir) { foreach ($f in Get-ChildItem -LiteralPath $gridDir -File) { $grid[$f.Name.ToLowerInvariant()] = $f.FullName } }

$artNames = [ordered]@{
  cover  = @('library_600x900_2x.jpg', 'library_600x900.jpg', 'library_capsule_2x.jpg', 'library_capsule.jpg')
  hero   = @('library_hero_2x.jpg', 'library_hero.jpg')
  logo   = @('logo_2x.png', 'logo.png')
  header = @('header_2x.jpg', 'header.jpg', 'library_header_2x.jpg', 'library_header.jpg')
}
$flat = [ordered]@{ cover = @('library_600x900_2x.jpg', 'library_600x900.jpg'); hero = @('library_hero.jpg'); logo = @('logo.png'); header = @('header.jpg'); icon = @('icon.jpg') }
$gridPat = [ordered]@{ cover = '{0}p'; hero = '{0}_hero'; logo = '{0}_logo'; header = '{0}'; icon = '{0}_icon' }
$imgExt = @('.jpg', '.jpeg', '.png', '.webp', '.gif')

function Get-CacheArt([uint32]$appid) {
  $art = @{}
  $folder = Join-Path $cache ([string]$appid)
  if (Test-Path -LiteralPath $folder) {
    $byName = @{}; $icons = @()
    foreach ($e in Get-ChildItem -LiteralPath $folder -Force) {
      if ($e.PSIsContainer) {
        foreach ($s in Get-ChildItem -LiteralPath $e.FullName -File -Force) { $n = $s.Name.ToLowerInvariant(); if (-not $byName[$n]) { $byName[$n] = @() }; $byName[$n] += $s }
      } else {
        if ($e.Name -match '^[0-9a-f]{40}\.jpg$' -and $e.Length -lt 65536) { $icons += $e }
        $n = $e.Name.ToLowerInvariant(); if (-not $byName[$n]) { $byName[$n] = @() }; $byName[$n] += $e
      }
    }
    foreach ($kind in $artNames.Keys) {
      foreach ($nm in $artNames[$kind]) {
        if ($byName[$nm]) { $art[$kind] = ($byName[$nm] | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName; break }
      }
    }
    if ($icons.Count) { $art['icon'] = ($icons | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName }
  }
  foreach ($kind in $flat.Keys) {
    if ($art[$kind]) { continue }
    foreach ($nm in $flat[$kind]) { $p = Join-Path $cache ("{0}_{1}" -f $appid, $nm); if (Test-Path -LiteralPath $p) { $art[$kind] = $p; break } }
  }
  return $art
}
function Get-GridArt([uint32]$appid) {
  $art = @{}
  foreach ($kind in $gridPat.Keys) {
    $stem = $gridPat[$kind] -f $appid
    foreach ($x in $imgExt) { if ($grid[$stem + $x]) { $art[$kind] = $grid[$stem + $x]; break } }
  }
  return $art
}
function Has-Art($art) { return [bool]($art['cover'] -or $art['hero'] -or $art['logo'] -or $art['header']) }

$keepTypes = @('game', 'demo', 'mod', 'beta')
$notGame = '^proton\b|steamworks|steam linux runtime|redistributable|\bredist\b|soundtrack|\bost\b|\bsdk\b|dedicated server|^steamvr\b|^steam (controller|client|audio)|benchmark tool'
$notGameIds = @(7, 760, 228980, 1070560, 1391110, 1628350, 1493710, 1826330, 2180100, 2348590, 2805730, 3658110)
$skipped = [ordered]@{ 'not a game' = 0; 'no name' = 0; 'no art' = 0; 'unplayed' = 0 }
$games = New-Object System.Collections.ArrayList

foreach ($aid in ($wanted.Keys | Sort-Object)) {
  $info = $ai.Apps[[uint32]$aid]
  $name = if ($info -and $info[0]) { $info[0] } elseif ($installed[$aid]) { $installed[$aid].name } elseif ($apiNames[$aid]) { $apiNames[$aid] } else { '' }
  $type = if ($info) { $info[1] } else { $null }
  $known = $installed.ContainsKey($aid) -or $played.ContainsKey($aid)
  if ($notGameIds -contains [int]$aid -or ($type -and $keepTypes -notcontains $type) -or (-not $type -and $name -and $name -match $notGame)) { $skipped['not a game']++; continue }
  # Owned but never played: only with a confirmed game type (appinfo, or Steam's owned-games list).
  if (-not $known -and (-not $IncludeUnplayed -or ($keepTypes -notcontains $type -and -not $apiOwned[$aid]))) { $skipped['unplayed']++; continue }
  if (-not $name) { $skipped['no name']++; continue }
  $art = Get-CacheArt $aid
  $g = Get-GridArt $aid
  foreach ($k in $g.Keys) { $art[$k] = $g[$k] }
  $cdn = $false
  if (-not (Has-Art $art)) {
    if (-not $apiOwned[$aid]) { $skipped['no art']++; continue }
    $cdn = $true  # owned per Steam, never shown on this computer: fetch its public store art below
  }
  $pl = $played[$aid]
  $lp = if ($pl -and $pl.lastPlayed) { $pl.lastPlayed } elseif ($installed[$aid]) { $installed[$aid].lastPlayed } else { 0 }
  [void]$games.Add([pscustomobject]@{ appid = [long]$aid; name = $name; playtime = $(if ($pl) { $pl.playtime } else { 0 }); lastPlayed = [long]$lp; nonSteam = $false; art = $art; cdn = $cdn })
}

$ns = 0
if (-not $NoShortcuts) {
  $shortcuts = [BacklogVdf]::ReadShortcuts((Join-Path $userDir 'config\shortcuts.vdf'))
  foreach ($s in $shortcuts) {
    # Each shortcut stays its own entry (core.js joins same-name entries). Playtime is in localconfig.vdf.
    $sid = [uint32]$s['appid']
    $art = Get-GridArt $sid
    $pl = $scPlayed[$sid]
    $pt = if ($pl) { $pl.playtime } else { 0 }
    $lp = [math]::Max([long]$s['lastPlayed'], $(if ($pl) { [long]$pl.lastPlayed } else { 0L }))
    if ((Has-Art $art) -or $pt -or $lp) {
      [void]$games.Add([pscustomobject]@{ appid = [long]$sid; name = $s['name']; playtime = $pt; lastPlayed = [long]$lp; nonSteam = $true; art = $art; cdn = $false })
      $ns++
    }
  }
  if ($shortcuts.Count) { Log ("Non-Steam games: {0} of {1} kept (custom art or played)" -f $ns, $shortcuts.Count) }
}

# Adds the app ids of one Steam collection, given as JSON text {"id":..,"added":[ids],"removed":[ids]}, to $out: added
# minus removed. A 64-bit game id (a non-Steam shortcut id in the top 32 bits) becomes that 32-bit shortcut id. The ids
# are read as text so a 64-bit one never loses digits.
function Add-CollectionIds($out, [string]$json) {
  $removed = @{}
  $rm = [regex]::Match($json, '"removed"\s*:\s*\[([^\]]*)\]')
  if ($rm.Success) { foreach ($x in [regex]::Matches($rm.Groups[1].Value, '\d+')) { $removed[$x.Value] = $true } }
  $ad = [regex]::Match($json, '"added"\s*:\s*\[([^\]]*)\]')
  if (-not $ad.Success) { return }
  foreach ($x in [regex]::Matches($ad.Groups[1].Value, '\d+')) {
    if ($removed[$x.Value]) { continue }
    $n = [decimal]$x.Value
    if ($n -gt 4294967295) { $n = [math]::Floor($n / 4294967296) }
    if ($n -gt 0 -and $n -le 4294967295) { $out[[uint32]$n] = $true }
  }
}

# The first value anywhere in a parsed VDF whose key is $key (any case), else $null.
function Find-VdfValue($d, [string]$key) {
  if (-not ($d -is [System.Collections.IDictionary])) { return $null }
  foreach ($k in @($d.Keys)) { if ($k -eq $key) { return $d[$k] } }
  foreach ($v in @($d.Values)) { $hit = Find-VdfValue $v $key; if ($null -ne $hit) { return $hit } }
  return $null
}

# App ids of the games hidden in Steam (Manage > Hide this game). Steam keeps them in two places (checked on a Steam
# Deck, 2026-11-21): Steam games in the "Hidden" collection it syncs to the cloud, the 'user-collections.hidden' entry
# of config\cloudstorage\cloud-storage-namespace-1.json (a list of [key, entry] pairs; the entry's value is a JSON
# string), and non-Steam games only on the device, in localconfig.vdf's "user-collections" value (a JSON string of
# collections by id, with a "hidden" one). Anything unreadable adds nothing.
function Get-HiddenApps([string]$dir, $localConfig) {
  $out = @{}
  $file = Join-Path $dir 'config\cloudstorage\cloud-storage-namespace-1.json'
  try {
    if (Test-Path -LiteralPath $file) {
      $pairs = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
      foreach ($p in $pairs) {
        if (-not ($p -is [array] -and $p.Count -eq 2 -and $p[0] -eq 'user-collections.hidden')) { continue }
        if (-not $p[1].is_deleted) { Add-CollectionIds $out ([string]$p[1].value) }
        break
      }
    }
  } catch {}
  try {
    $local = Find-VdfValue $localConfig 'user-collections'
    if ($local -is [string]) {
      $m = [regex]::Match($local, '"hidden"\s*:\s*(\{[^{}]*\})')
      if ($m.Success) { Add-CollectionIds $out $m.Groups[1].Value }
    }
  } catch {}
  return $out
}

# True when the installed config.js turns showHidden on (library: { ..., showHidden: true }). Lines that are comments
# don't count; a missing or unreadable config.js means off.
function Test-ShowHidden([string]$dir) {
  $path = Join-Path $dir 'config.js'
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  try { $text = [IO.File]::ReadAllText($path) } catch { return $false }
  $text = [regex]::Replace($text, '(?m)^\s*//.*$', '')
  return [regex]::IsMatch($text, '\bshowHidden\s*:\s*true\b')
}

# Games hidden in Steam stay hidden here too, unless config.js says showHidden: true.
if (Test-ShowHidden $targetDir) {
  $hidden = @{}
  Log 'Hidden in Steam: shown (showHidden is on in config.js)'
} else {
  $hidden = Get-HiddenApps $userDir $localConfig
  $kept = @($games | Where-Object { -not $hidden[[uint32]$_.appid] })
  if ($kept.Count -lt $games.Count) { Log ("Hidden in Steam: {0} left out (showHidden in config.js shows them)" -f ($games.Count - $kept.Count)) }
  $games = $kept
}

$games = @($games | Sort-Object -Property @{ Expression = 'lastPlayed'; Descending = $true }, @{ Expression = 'playtime'; Descending = $true })
if ($MaxGames -gt 0 -and $games.Count -gt $MaxGames) { $games = @($games[0..($MaxGames - 1)]) }

# ------------------------------------------------------------------ write
Write-Verbose ('[{0,5:N1}s] Writing {1} games...' -f $stopwatch.Elapsed.TotalSeconds, $games.Count)
# Remove what an earlier sync wrote for games that are gone, nothing else. Kept folders are reused (fast re-runs).
$keep = @{}
foreach ($g in $games) { $keep[[string]$g.appid] = $true }
foreach ($e in Get-ChildItem -LiteralPath $lib -Directory -ErrorAction SilentlyContinue) {
  if ($e.Name -match '^\d+$' -and -not $keep[$e.Name]) { Remove-Item -LiteralPath $e.FullName -Recurse -Force }
}

# Reuse library/<dir>/<stem>.* when its source is unchanged. library/.sources holds one fingerprint per output
# (a hash of the source's path, time and size, so no paths or account ids are stored).
$srcFile = Join-Path $lib '.sources'
$prevSrc = @{}
if (Test-Path -LiteralPath $srcFile) {
  foreach ($line in [IO.File]::ReadAllLines($srcFile)) { $kv = $line.Split(' '); if ($kv.Count -eq 2) { $prevSrc[$kv[0]] = $kv[1] } }
}
$newSrc = @{}
$md5 = [Security.Cryptography.MD5]::Create()
function Write-Art([string]$src, [string]$dir, [string]$stem, $l, [bool]$alpha) {
  $si = Get-Item -LiteralPath $src
  $fp = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}' -f $si.FullName, $si.LastWriteTimeUtc.Ticks, $si.Length)))).Replace('-', '')
  $key = (Split-Path -Leaf $dir) + '/' + $stem
  $script:newSrc[$key] = $fp
  $old = @(Get-ChildItem -LiteralPath $dir -File -Filter "$stem.*" -ErrorAction SilentlyContinue)
  if ($old.Count -eq 1 -and $prevSrc[$key] -eq $fp) { return $old[0] }
  foreach ($o in $old) { Remove-Item -LiteralPath $o.FullName -Force }
  $w = [BacklogVdf]::Shrink($src, (Join-Path $dir $stem), $l[0], $l[1], $l[2], $l[3], $alpha)
  return (Get-Item -LiteralPath $w)
}

# Size limits per kind: max width, max height, re-encode when the file is over this many bytes, JPEG quality.
$limits = @{
  cover  = @(600, 900, 120KB, 86)
  hero   = @(1920, 1080, 160KB, 82)
  logo   = @(1280, 720, 400KB, 90)
  header = @(920, 430, 200KB, 86)
  icon   = @(256, 256, 64KB, 90)
}
# Public store art for a game this computer has no art for. Kept between runs; $null when Steam has none.
$cdnFiles = [ordered]@{ cover = 'library_600x900.jpg'; hero = 'library_hero.jpg'; logo = 'logo.png'; header = 'header.jpg' }
function Fetch-Art([string]$url, [string]$dir, [string]$stem, $l) {
  $key = (Split-Path -Leaf $dir) + '/' + $stem
  $fp = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes('cdn|' + $url))).Replace('-', '')
  $old = @(Get-ChildItem -LiteralPath $dir -File -Filter "$stem.*" -ErrorAction SilentlyContinue)
  if ($old.Count -eq 1 -and $prevSrc[$key] -eq $fp) { $script:newSrc[$key] = $fp; return $old[0] }
  $b = $null
  try { $b = Get-Http $url 20000 } catch { $b = $null }
  if (-not (Test-Image $b)) { return $null }
  foreach ($o in $old) { Remove-Item -LiteralPath $o.FullName -Force }
  $tmp = Join-Path $dir ('_dl_' + $stem + $(if ($b[0] -eq 0x89) { '.png' } else { '.jpg' }))
  [IO.File]::WriteAllBytes($tmp, $b)
  $w = [BacklogVdf]::Shrink($tmp, (Join-Path $dir $stem), $l[0], $l[1], $l[2], $l[3], $true)
  Remove-Item -LiteralPath $tmp -Force
  $script:newSrc[$key] = $fp
  return (Get-Item -LiteralPath $w)
}

$total = 0L
$fetched = 0; $dropped = 0
# Achievements: Steam keeps a summary of each game's progress (unlocked of total) in achievement_progress.json, but
# only updates it now and then, so it goes stale (a newer PC may have only a few games in it). Steam also writes one
# file per game (librarycache\<appid>.json) whenever that game's library page is shown; where that file is newer
# than the summary's entry, its counts win.
$achDir = Join-Path $userDir 'config\librarycache'
$ach = @{}; $achTime = @{}; $achNewer = 0
try {
  $achFile = Join-Path $achDir 'achievement_progress.json'
  if (Test-Path -LiteralPath $achFile) {
    foreach ($pair in (Get-Content -LiteralPath $achFile -Raw -Encoding UTF8 | ConvertFrom-Json).mapCache) {
      $aid = ToAppId $pair[0]
      if ($aid -lt 0) { continue }
      $achTime[$aid] = [long]$pair[1].cache_time
      if ($pair[1].total -gt 0) { $ach[$aid] = [ordered]@{ unlocked = [int]$pair[1].unlocked; total = [int]$pair[1].total } }
    }
  }
} catch { $ach = @{}; $achTime = @{} }
# (unlocked, total) from a game's own cache file when it was written after $olderThan (Unix seconds) and counts any
# achievements, else $null. Read as text: the counts sit in its "achievements" section as nTotal and nAchieved.
function Get-GameAchievements([string]$path, [long]$olderThan) {
  try {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $item = Get-Item -LiteralPath $path
    if ([DateTimeOffset]::new($item.LastWriteTimeUtc).ToUnixTimeSeconds() -le $olderThan) { return $null }
    $text = [IO.File]::ReadAllText($path)
    $at = $text.IndexOf('["achievements"')
    if ($at -lt 0) { return $null }
    $section = $text.Substring($at)
    $t = [regex]::Match($section, '"nTotal"\s*:\s*(\d+)'); $a = [regex]::Match($section, '"nAchieved"\s*:\s*(\d+)')
    if (-not $t.Success -or -not $a.Success -or [int]$t.Groups[1].Value -le 0) { return $null }
    return @([int]$a.Groups[1].Value, [int]$t.Groups[1].Value)
  } catch { return $null }
}
foreach ($g in $games) {
  if ($g.nonSteam) { continue }
  $aid = [long]$g.appid
  $older = if ($achTime.ContainsKey($aid)) { $achTime[$aid] } else { 0L }
  $own = Get-GameAchievements (Join-Path $achDir ('{0}.json' -f $aid)) $older
  if ($own) {
    $was = $ach[$aid]
    if (-not $was -or $was.unlocked -ne $own[0] -or $was.total -ne $own[1]) { $achNewer++ }
    $ach[$aid] = [ordered]@{ unlocked = [math]::Min($own[0], $own[1]); total = $own[1] }
  }
}

$out = New-Object System.Collections.ArrayList
foreach ($g in $games) {
  $dir = Join-Path $lib ([string]$g.appid)
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $entry = [ordered]@{ appid = $g.appid; name = $g.name; playtime = [long]$g.playtime; lastPlayed = $g.lastPlayed }
  if (-not $g.nonSteam -and $ach.ContainsKey([long]$g.appid)) { $entry['achievements'] = $ach[[long]$g.appid] }
  if ($g.cdn) {
    foreach ($kind in $cdnFiles.Keys) {
      $f = Fetch-Art ('{0}/{1}/{2}' -f $CdnBase.TrimEnd('/'), $g.appid, $cdnFiles[$kind]) $dir $kind $limits[$kind]
      if ($f) { $g.art[$kind] = $f; $fetched++ }
    }
    if (-not (Has-Art $g.art)) { $dropped++; Remove-Item -LiteralPath $dir -Recurse -Force; continue }
  }
  foreach ($kind in @('cover', 'hero', 'logo', 'header', 'icon')) {
    $src = $g.art[$kind]
    if ($src -is [IO.FileInfo]) {
      $total += $src.Length
      $entry[$kind] = 'library/{0}/{1}' -f $g.appid, $src.Name
      continue
    }
    if (-not $src) {
      $entry[$kind] = $null
      Get-ChildItem -LiteralPath $dir -File -Filter "$kind.*" -ErrorAction SilentlyContinue | Remove-Item -Force
      continue
    }
    $f = Write-Art $src $dir $kind $limits[$kind] $true
    $total += $f.Length
    $entry[$kind] = 'library/{0}/{1}' -f $g.appid, $f.Name
  }
  if ($g.nonSteam) { $entry['nonSteam'] = $true }
  [void]$out.Add($entry)
}

if ($fetched -or $dropped) { Log ("Store art: {0} images for games this computer never showed; {1} games had none" -f $fetched, $dropped) }
Write-Verbose ('[{0,5:N1}s] Art written.' -f $stopwatch.Elapsed.TotalSeconds)
# Screenshots: newest first, scaled to at most 1920x1080.
$shots = New-Object System.Collections.ArrayList
$remote = Join-Path $userDir '760\remote'
if ($MaxScreenshots -gt 0 -and (Test-Path -LiteralPath $remote)) {
  $found = New-Object System.Collections.ArrayList
  foreach ($d in Get-ChildItem -LiteralPath $remote -Directory | Where-Object { $_.Name -match '^\d+$' }) {
    $shotId = ToAppId $d.Name
    if ($shotId -lt 0 -or $hidden[[uint32]$shotId]) { continue }
    $sd = Join-Path $d.FullName 'screenshots'
    if (-not (Test-Path -LiteralPath $sd)) { continue }
    foreach ($f in Get-ChildItem -LiteralPath $sd -File | Where-Object { $_.Extension -match '^\.(jpe?g|png)$' }) {
      $t = 0L
      if ($f.Name -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})_\d+\.') {
        try { $t = [DateTimeOffset]::new((Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Matches[6])).ToUnixTimeSeconds() } catch { $t = 0L }
      }
      if (-not $t) { $t = [DateTimeOffset]::new($f.LastWriteTimeUtc).ToUnixTimeSeconds() }
      [void]$found.Add([pscustomobject]@{ appid = $shotId; file = $f; time = $t })
    }
  }
  $pick = @($found | Sort-Object time -Descending | Select-Object -First $MaxScreenshots)
  $shotDir = Join-Path $lib 'shots'
  if ($pick.Count) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }
  foreach ($s in $pick) {
    $stem = '{0}_{1}' -f $s.appid, [IO.Path]::GetFileNameWithoutExtension($s.file.Name)
    $f = Write-Art $s.file.FullName $shotDir $stem @(1920, 1080, 600KB, 85) $false
    $total += $f.Length
    [void]$shots.Add([ordered]@{ appid = $s.appid; path = ('library/shots/' + $f.Name); time = $s.time })
  }
}
# Drop screenshots that fell out of the newest N.
$shotKeep = @{}
foreach ($s in $shots) { $shotKeep[(Split-Path -Leaf $s.path)] = $true }
Get-ChildItem -LiteralPath (Join-Path $lib 'shots') -File -ErrorAction SilentlyContinue | Where-Object { -not $shotKeep[$_.Name] } | Remove-Item -Force
[IO.File]::WriteAllLines($srcFile, [string[]]@($newSrc.Keys | Sort-Object | ForEach-Object { "$_ $($newSrc[$_])" }))

$data = [ordered]@{
  generated   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  user        = [ordered]@{ name = [string]$acct.Persona }
  games       = @($out)
  screenshots = @($shots)
}
$json = ConvertTo-Json -InputObject $data -Depth 6 -Compress
# ASCII only (\uXXXX for the rest), so the file reads the same under any page encoding.
$json = [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
$js = "/* Written by the Backlog sync tool (tools/sync.ps1). Run it again to refresh. */`nwindow.BACKLOG_LIBRARY = $json;`n"
[IO.File]::WriteAllText((Join-Path $lib 'library.js'), $js, (New-Object Text.UTF8Encoding $false))
$total += $js.Length

$sk = ($skipped.Keys | Where-Object { $skipped[$_] } | ForEach-Object { "$($skipped[$_]) $_" }) -join ', '
Log ("Games: {0} ({1} non-Steam). Skipped: {2}" -f $out.Count, @($out | Where-Object { $_['nonSteam'] }).Count, $sk)
$achCount = @($out | Where-Object { $_.Contains('achievements') }).Count
if ($achCount) { Log ("Achievements: {0} games{1}" -f $achCount, $(if ($achNewer) { " ($achNewer newer than Steam's summary)" } else { '' })) }
Log ("Screenshots: {0}. Output: {1:N1} MB in {2}" -f $shots.Count, ($total / 1MB), $lib)

$p = $targetDir
while ($p) {
  if (Test-Path -LiteralPath (Join-Path $p '.git')) {
    Log "Note: $p is a git work tree. Keep your real library.js out of commits with:"
    Log "  git -C `"$p`" update-index --skip-worktree backlog/library/library.js"
    break
  }
  $up = Split-Path -Parent $p
  if ($up -eq $p) { break }
  $p = $up
}
