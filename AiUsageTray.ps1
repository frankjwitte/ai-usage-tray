<#
  AI Usage Tray
  One Windows tray icon showing how much of your weekly Claude Pro (top half) and
  Codex Plus (bottom half) limits is left. It reads the logins that Claude Code and
  Codex already keep on this machine and only reads them (never renews or changes them).

  Normally started by AiUsageTray.exe (gives the tray icon its own name in Windows).
  Direct run:  powershell -NoProfile -STA -ExecutionPolicy Bypass -File AiUsageTray.ps1
  Test:        ... -File AiUsageTray.ps1 -Test [-TestOut <folder>]   (prints data, saves icon previews, exits)
  App icon:    ... -File AiUsageTray.ps1 -MakeIco <path.ico>
#>
param(
    [switch]$Test,
    [string]$TestOut = (Join-Path $env:TEMP 'AiUsageTray-preview'),
    [string]$MakeIco,
    [switch]$DemoHistory,  # with -Test: live numbers plus a made-up chart history
    [switch]$Demo,         # with -Test: made-up numbers and history, no network (used for README screenshots)
    [switch]$LibOnly      # internal: define functions only (used by the background fetch runspace)
)

$ErrorActionPreference = 'Stop'

# ---------------- Settings ----------------
$RefreshMinutes  = 5                 # how often to ask the services
$AlertThresholds = @(50, 25, 10)     # notify when weekly % LEFT drops to these
$FiveHourAlertAt = 10                # notify when a 5-hour window drops to this % left (once per window)
$StateDir   = Join-Path $env:LOCALAPPDATA 'AiUsageTray'
$StatePath  = Join-Path $StateDir 'state.json'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Usage Tray.lnk'
$ScriptPath = $MyInvocation.MyCommand.Path
$UserHome   = $env:USERPROFILE

$Colors = @{ Green = '#2E9E5B'; Amber = '#E8A317'; Red = '#D64545'; Gray = '#7A7A7A' }

# Order matters: first = top half of the icon, second = bottom half
$Services = @(
    @{ Key = 'claude'; Name = 'Claude'; UsageUrl = 'https://claude.ai/settings/usage' },
    @{ Key = 'codex';  Name = 'Codex';  UsageUrl = 'https://chatgpt.com/codex/settings/usage' }
)

# Diagnostic log (rotates at 256 KB): %LOCALAPPDATA%\AiUsageTray\app.log
$LogPath = Join-Path $StateDir 'app.log'
function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 256KB) { Move-Item $LogPath "$LogPath.old" -Force }
        [IO.File]::AppendAllText($LogPath, "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $msg`r`n")
    } catch {}
}

# ---------------- Setup ----------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('AiTrayNative' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Windows.Forms;
public static class AiTrayNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
// Borderless popup panel with Windows 11 rounded corners, hidden from taskbar and Alt+Tab
public class AiFlyoutForm : Form {
    public AiFlyoutForm() {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        StartPosition = FormStartPosition.Manual; KeyPreview = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
    }
    protected override CreateParams CreateParams { get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80; return cp; } }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        int v = 2; try { DwmSetWindowAttribute(Handle, 33, ref v, 4); } catch {}   // round corners
    }
    public void SetBorderColor(System.Drawing.Color c) {
        int v = c.R | (c.G << 8) | (c.B << 16); try { DwmSetWindowAttribute(Handle, 34, ref v, 4); } catch {}
    }
}
'@
}
[void][AiTrayNative]::SetProcessDPIAware()   # crisp icon on high-DPI screens
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Dot = [char]0x00B7

# ---------------- Data fetching ----------------
function Invoke-Usage([string]$Uri, [hashtable]$Headers, [string]$AuthHint) {
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 15 -UseBasicParsing
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
        if ($code -eq 401 -or $code -eq 403) { throw "Login expired - $AuthHint" }
        if ($code -eq 429) {
            $sec = 0; $ra = $null
            try { $ra = $_.Exception.Response.Headers['Retry-After'] } catch {}
            if ($ra -and [int]::TryParse([string]$ra, [ref]$sec)) { throw "Rate limited (retry in ${sec}s)" }
            throw 'Rate limited'
        }
        if ($code) { throw "Service error (HTTP $code)" }
        throw "Can't reach service"
    }
}

function ConvertTo-Dto($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { return [DateTimeOffset]$v }
    return [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-ClaudeUsage {
    $path = Join-Path $UserHome '.claude\.credentials.json'
    if (-not (Test-Path $path)) { throw 'Not logged in - open Claude Code' }
    $cred = (Get-Content $path -Raw | ConvertFrom-Json).claudeAiOauth
    if (-not $cred -or -not $cred.accessToken) { throw 'Not logged in - open Claude Code' }
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($cred.expiresAt -and [int64]$cred.expiresAt -lt $nowMs) { throw 'Login expired - open Claude Code' }

    $r = Invoke-Usage 'https://api.anthropic.com/api/oauth/usage' @{
        Authorization    = "Bearer $($cred.accessToken)"
        'anthropic-beta' = 'oauth-2025-04-20'
        'User-Agent'     = 'claude-code'
    } 'open Claude Code'

    if (-not $r.seven_day -or $null -eq $r.seven_day.utilization) { throw 'No weekly limit in response' }
    $plan = 'Pro'
    if ($cred.subscriptionType) { $plan = (Get-Culture).TextInfo.ToTitleCase([string]$cred.subscriptionType) }
    $u = [pscustomobject]@{
        Plan = $plan
        WeekUsed = [double]$r.seven_day.utilization
        WeekResetAt = ConvertTo-Dto $r.seven_day.resets_at
        WeekSeconds = 7 * 86400
        WeekIdle = $false
        FiveUsed = $null; FiveResetAt = $null   # FiveResetAt stays $null when no 5-hour window is active
        LimitReached = $false
    }
    if ($r.five_hour -and $null -ne $r.five_hour.utilization) {
        $u.FiveUsed = [double]$r.five_hour.utilization
        $u.FiveResetAt = ConvertTo-Dto $r.five_hour.resets_at
    }
    if ($u.WeekUsed -ge 100) { $u.LimitReached = $true }
    return (Set-WeekIdle $u)
}

# No usage yet this week means no reset time. Mark it idle and assume a full window from now,
# so the rest of the code always has a WeekResetAt.
function Set-WeekIdle($u) {
    if (-not $u.WeekResetAt) {
        $u.WeekIdle = $true
        $u.WeekResetAt = [DateTimeOffset]::UtcNow.AddSeconds($u.WeekSeconds)
    }
    return $u
}

function ConvertFrom-Unix($v) {
    if ($null -eq $v -or [int64]$v -le 0) { return $null }
    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$v)
}

function Get-CodexUsage {
    $path = Join-Path $UserHome '.codex\auth.json'
    if (-not (Test-Path $path)) { throw 'Not logged in - open Codex' }
    $t = (Get-Content $path -Raw | ConvertFrom-Json).tokens
    if (-not $t -or -not $t.access_token) { throw 'Not logged in - open Codex' }

    $h = @{ Authorization = "Bearer $($t.access_token)"; 'User-Agent' = 'codex_cli_rs' }
    if ($t.account_id) { $h['ChatGPT-Account-Id'] = $t.account_id }
    $r = Invoke-Usage 'https://chatgpt.com/backend-api/wham/usage' $h 'open Codex'

    $rl = $r.rate_limit
    if (-not $rl) { throw 'No rate limit in response' }
    # The longer window is the weekly one, the shorter is the 5-hour one.
    $wins = @(@($rl.primary_window, $rl.secondary_window) | Where-Object { $_ } |
              Sort-Object { [int64]$_.limit_window_seconds })
    if ($wins.Count -eq 0) { throw 'No rate limit windows in response' }
    $week = $wins[-1]
    $plan = 'Plus'
    if ($r.plan_type) { $plan = (Get-Culture).TextInfo.ToTitleCase([string]$r.plan_type) }
    $u = [pscustomobject]@{
        Plan = $plan
        WeekUsed = [double]$week.used_percent
        WeekResetAt = ConvertFrom-Unix $week.reset_at
        WeekSeconds = [int64]$week.limit_window_seconds
        WeekIdle = $false
        FiveUsed = $null; FiveResetAt = $null
        # Weekly only. rate_limit.limit_reached is also true when just the 5-hour window is used up.
        LimitReached = ([double]$week.used_percent -ge 100)
    }
    if ($wins.Count -gt 1) {
        $five = $wins[0]
        $u.FiveUsed = [double]$five.used_percent
        $u.FiveResetAt = ConvertFrom-Unix $five.reset_at
    }
    return (Set-WeekIdle $u)
}

function Get-Usage([string]$Key) {
    if ($Key -eq 'claude') { return Get-ClaudeUsage } else { return Get-CodexUsage }
}

# ---------------- Presentation ----------------
function Format-Span([TimeSpan]$ts) {
    if ($ts.TotalMinutes -lt 1) { return 'now' }
    if ($ts.TotalDays -ge 1)  { return ('{0}d {1}h' -f [int][math]::Floor($ts.TotalDays), $ts.Hours) }
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes) }
    return ('{0}m' -f $ts.Minutes)
}

function Format-When([DateTimeOffset]$t) {
    $local = $t.LocalDateTime
    if ($local.Date -eq (Get-Date).Date) { return $local.ToString('HH:mm') }
    return $local.ToString('ddd HH:mm')
}

function Get-Left([double]$used) { return [int][math]::Max(0.0, [math]::Min(100.0, [math]::Round(100.0 - $used))) }

function Get-Pace($u) {
    $remain = ($u.WeekResetAt - [DateTimeOffset]::UtcNow).TotalSeconds
    $frac = 1 - ($remain / [double]$u.WeekSeconds)
    $frac = [math]::Max(0.0, [math]::Min(1.0, $frac))
    $delta = $u.WeekUsed - ($frac * 100)
    $short = 'ok'; $long = 'on track'
    if ($frac -ge 0.05) {
        if ($delta -gt 10) { $short = 'fast'; $long = 'too fast' }
        elseif ($delta -lt -10) { $short = 'easy'; $long = 'room to spare' }
    }
    return [pscustomobject]@{ Delta = $delta; ElapsedPct = [int][math]::Round($frac * 100); Short = $short; Long = $long }
}

# Will the weekly limit last until reset? Uses the average rate since the week started.
function Get-Forecast($u) {
    $now = [DateTimeOffset]::UtcNow
    $len = [double]$u.WeekSeconds
    $remain = [math]::Max(0.0, ($u.WeekResetAt - $now).TotalSeconds)
    $elapsed = $len - $remain
    $f = [pscustomobject]@{ Kind = 'early'; Elapsed = $elapsed; ProjUsed = $u.WeekUsed; RunOutAt = $null; Short = 'too early'; Long = 'Too early in the week to forecast' }
    if ($u.WeekIdle) { $f.Short = 'not started'; $f.Long = 'No usage yet this week'; return $f }
    if ($u.LimitReached -or $u.WeekUsed -ge 100) {
        $f.Kind = 'out'; $f.RunOutAt = $now; $f.ProjUsed = 100
        $f.Short = 'limit hit'; $f.Long = "Limit reached - back at $(Format-When $u.WeekResetAt)"
        return $f
    }
    if ($elapsed -lt 12 * 3600) { return $f }
    $rate = $u.WeekUsed / $elapsed                       # % per second
    $proj = $u.WeekUsed + $rate * $remain
    $f.ProjUsed = [math]::Min(100.0, $proj)
    if ($proj -lt 100) {
        $leftAt = [int][math]::Floor(100 - $proj)
        $f.Kind = 'ok'; if ($leftAt -lt 10) { $f.Kind = 'tight' }
        $f.Short = "~$leftAt% at reset"
        if ($f.Kind -eq 'tight') { $f.Long = "At this pace: only ~$leftAt% left at reset" }
        else { $f.Long = "At this pace: ~$leftAt% left at reset" }
    } else {
        $f.Kind = 'out'
        $f.RunOutAt = $now.AddSeconds((100 - $u.WeekUsed) / $rate)
        $f.Short = "out $(Format-When $f.RunOutAt)"
        $f.Long = "At this pace: runs out $(Format-When $f.RunOutAt) ($(Format-Span ($u.WeekResetAt - $f.RunOutAt)) early)"
    }
    return $f
}

# Everything needed to draw one service: icon half, tooltip lines, menu lines
function Get-Status($svc, $entry, [bool]$colorByPace) {
    $now = [DateTimeOffset]::UtcNow
    $u = $null; if ($entry) { $u = $entry.Usage }
    $err = 'Loading...'; if ($entry) { $err = $entry.Error }

    if (-not $u) {
        return [pscustomobject]@{
            Text = '?'; Color = $Colors.Gray
            Tip  = @("$($svc.Name): $err")
            Menu = @("$($svc.Name): $err")
        }
    }

    $left = Get-Left $u.WeekUsed
    $fc = Get-Forecast $u
    if ($u.LimitReached -or $left -le 0) { $color = $Colors.Red }
    elseif ($colorByPace) {
        # "Color by forecast": red = projected to run out, amber = little left at reset
        if ($fc.Kind -eq 'out') { $color = $Colors.Red }
        elseif ($fc.Kind -eq 'tight' -or $left -lt 10) { $color = $Colors.Amber }
        else { $color = $Colors.Green }
    } else {
        if ($left -gt 50) { $color = $Colors.Green } elseif ($left -ge 20) { $color = $Colors.Amber } else { $color = $Colors.Red }
    }

    if ($u.WeekIdle) {
        $weekIn = 'n/a'
        $menu = @("$($svc.Name) $($u.Plan): $left% left this week $Dot no usage yet")
    } else {
        $weekIn = Format-Span ($u.WeekResetAt - $now)
        $menu = @("$($svc.Name) $($u.Plan): $left% left this week $Dot resets $(Format-When $u.WeekResetAt) ($weekIn)")
    }
    $five = ''
    if ($null -ne $u.FiveUsed) {
        $fl = Get-Left $u.FiveUsed
        $five = "5h $fl% | "
        if ($u.FiveResetAt) {
            $menu += "      5-hour: $fl% left $Dot resets $(Format-When $u.FiveResetAt) ($(Format-Span ($u.FiveResetAt - $now)))"
        } else {
            $menu += "      5-hour: $fl% left $Dot no active window"
        }
    }

    if ($entry.Error) {
        $color = $Colors.Gray
        $tip = @("$($svc.Name) $left% (old): $($entry.Error)")
        $menu += "      ! $($entry.Error) $Dot data from $($entry.LastOk.ToString('ddd HH:mm'))"
    } else {
        if ($u.WeekIdle) { $tip = @("$($svc.Name) $left% left, week not started", "   $($five)$($fc.Short)") }
        else { $tip = @("$($svc.Name) $left% left, resets $weekIn", "   $($five)$($fc.Short)") }
        $menu += "      $($fc.Long)"
    }

    return [pscustomobject]@{
        Text = [string]([math]::Min(99, $left))   # 2 digits fit; 100 shows as 99
        Color = $color; Tip = $tip; Menu = $menu
    }
}

# ---------------- Icon drawing ----------------
function Get-IconFont {
    foreach ($f in @(@('Bahnschrift SemiBold SemiConden', 'Regular'), @('Segoe UI', 'Bold'))) {
        try { return @{ Family = New-Object System.Drawing.FontFamily($f[0]); Style = [System.Drawing.FontStyle]$f[1] } } catch {}
    }
    return @{ Family = [System.Drawing.FontFamily]::GenericSansSerif; Style = [System.Drawing.FontStyle]::Bold }
}
$IconFont = Get-IconFont

function Get-TextColor([string]$bgHex) {
    if ($bgHex -eq $Colors.Amber) { return [System.Drawing.Color]::FromArgb(26, 26, 26) }
    return [System.Drawing.Color]::White
}

# Pixel-snapped (hinted) number, centered in rect, digit height ~ rect height
function Draw-Number($g, [string]$text, [System.Drawing.RectangleF]$rect, [System.Drawing.Color]$color) {
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $fam = $IconFont.Family; $style = $IconFont.Style
    $em = $fam.GetEmHeight($style); $asc = $fam.GetCellAscent($style)
    $sf = [System.Drawing.StringFormat]::GenericTypographic
    $px = [math]::Floor($rect.Height / 0.70)
    $font = New-Object System.Drawing.Font($fam, [single]$px, $style, [System.Drawing.GraphicsUnit]::Pixel)
    $sz = $g.MeasureString($text, $font, 1000, $sf)
    while ($sz.Width -gt $rect.Width + 1 -and $px -gt 5) {
        $font.Dispose(); $px--
        $font = New-Object System.Drawing.Font($fam, [single]$px, $style, [System.Drawing.GraphicsUnit]::Pixel)
        $sz = $g.MeasureString($text, $font, 1000, $sf)
    }
    $gapAbove = $px * ($asc / $em) - $px * 0.70
    $x = [math]::Round($rect.X + ($rect.Width - $sz.Width) / 2)
    $y = [math]::Round($rect.Y + ($rect.Height - $px * 0.70) / 2 - $gapAbove)
    $br = New-Object System.Drawing.SolidBrush($color)
    $g.DrawString($text, $font, $br, [single]$x, [single]$y, $sf)
    $br.Dispose(); $font.Dispose()
}

# Split icon: top half = first service, bottom half = second
function New-ComboBitmap($top, $bottom, [int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $r = [math]::Max(2, [int]($size / 6)); $d = $r * 2; $w = $size - 1
    $outer = New-Object System.Drawing.Drawing2D.GraphicsPath
    $outer.AddArc(0, 0, $d, $d, 180, 90); $outer.AddArc($w - $d, 0, $d, $d, 270, 90)
    $outer.AddArc($w - $d, $w - $d, $d, $d, 0, 90); $outer.AddArc(0, $w - $d, $d, $d, 90, 90)
    $outer.CloseFigure()

    $half = [int]($size / 2)
    $g.SetClip($outer)
    $b1 = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($top.Color))
    $b2 = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($bottom.Color))
    $g.FillRectangle($b1, 0, 0, $size, $half)
    $g.FillRectangle($b2, 0, $half, $size, $size - $half)
    $g.ResetClip(); $b1.Dispose(); $b2.Dispose(); $outer.Dispose()

    $padX = 1; $padY = [math]::Max(1, [int]($size / 10))
    $h = $half - 2 * $padY + 1; $tw = $size - 2 * $padX - 1; $y2 = $half + $padY - 1
    Draw-Number $g $top.Text    ([System.Drawing.RectangleF]::new($padX, $padY, $tw, $h)) (Get-TextColor $top.Color)
    Draw-Number $g $bottom.Text ([System.Drawing.RectangleF]::new($padX, $y2,    $tw, $h)) (Get-TextColor $bottom.Color)
    $g.Dispose()
    return $bmp
}

# Writes a multi-size .ico (PNG-compressed entries) for the .exe
function Save-Ico([string]$path) {
    $top = [pscustomobject]@{ Text = 'AI'; Color = $Colors.Green }
    $bot = [pscustomobject]@{ Text = '%';  Color = $Colors.Amber }
    $pngs = foreach ($sz in 16, 20, 24, 32, 48, 64, 256) {
        $bmp = New-ComboBitmap $top $bot $sz
        $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        , @($sz, $ms.ToArray())
    }
    $fs = [IO.File]::Create($path); $bw = New-Object IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
    $offset = 6 + 16 * $pngs.Count
    foreach ($p in $pngs) {
        $dim = [byte]($p[0] % 256)
        $bw.Write($dim); $bw.Write($dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$p[1].Length); $bw.Write([uint32]$offset)
        $offset += $p[1].Length
    }
    foreach ($p in $pngs) { $bw.Write([byte[]]$p[1]) }
    $bw.Close()
}

# ---------------- State (settings + alert memory) ----------------
function Get-State {
    $s = @{ colorByPace = $false }
    foreach ($k in 'claude', 'codex') { $s[$k] = @{ resetAt = 0; fired = @(); fiveFired = $false } }
    if (Test-Path $StatePath) {
        try {
            $j = Get-Content $StatePath -Raw | ConvertFrom-Json
            if ($null -ne $j.colorByPace) { $s.colorByPace = [bool]$j.colorByPace }
            foreach ($k in 'claude', 'codex') {
                if ($j.$k) {
                    $s[$k].resetAt = [int64]$j.$k.resetAt
                    $s[$k].fired = @($j.$k.fired | ForEach-Object { [int]$_ })
                    if ($null -ne $j.$k.fiveFired) { $s[$k].fiveFired = [bool]$j.$k.fiveFired }
                }
            }
        } catch { Write-Log "state.json unreadable, using defaults: $_" }
    }
    return $s
}

function Save-State {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    $script:State | ConvertTo-Json -Depth 4 | Set-Content -Path $StatePath -Encoding UTF8
}

# ---------------- History (for the weekly chart) ----------------
# history.csv rows: unixTime,service,weekUsedPercent,weekResetUnix
$HistoryPath = Join-Path $StateDir 'history.csv'
$script:History = New-Object System.Collections.Generic.List[object]
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Import-History([switch]$NoPrune) {
    if (-not (Test-Path $HistoryPath)) { return }
    $cut = [DateTimeOffset]::UtcNow.AddDays(-21).ToUnixTimeSeconds()
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($HistoryPath)) {
        $p = $line.Split(',')
        if ($p.Count -lt 4) { continue }
        $t = 0L; $used = 0.0; $reset = 0L
        if (-not [int64]::TryParse($p[0], [ref]$t) -or $t -lt $cut) { continue }
        if (-not [double]::TryParse($p[2], [Globalization.NumberStyles]::Float, $Inv, [ref]$used)) { continue }
        if (-not [int64]::TryParse($p[3], [ref]$reset)) { continue }
        $script:History.Add([pscustomobject]@{ T = $t; Key = $p[1]; Used = $used; Reset = $reset })
        $keep.Add($line)
    }
    if (-not $NoPrune) { [IO.File]::WriteAllLines($HistoryPath, $keep) }   # drop rows older than 3 weeks
}

function Add-History($svc, $u) {
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $reset = $u.WeekResetAt.ToUnixTimeSeconds()
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    [IO.File]::AppendAllText($HistoryPath, ("{0},{1},{2},{3}`r`n" -f $t, $svc.Key, $u.WeekUsed.ToString($Inv), $reset))
    $script:History.Add([pscustomobject]@{ T = $t; Key = $svc.Key; Used = $u.WeekUsed; Reset = $reset })
}

# ---------------- Popup panel ----------------
$script:ForceTheme = $null
$script:Scale = 1.0
try { $sg = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:Scale = $sg.DpiX / 96.0; $sg.Dispose() } catch {}

function C([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }

function Get-Theme {
    $light = $false
    if ($script:ForceTheme) { $light = $script:ForceTheme -eq 'light' }
    else {
        try { $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction Stop).SystemUsesLightTheme -eq 1 } catch {}
    }
    if ($light) {
        $t = @{ Bg = '#F9F9F9'; Border = '#D5D5D5'; Text = '#1A1A1A'; Muted = '#5F5F5F'; Track = '#E3E3E3'; Grid = '#D6D6D6'; Accent = '#005FB8'; Warn = '#9A6500' }
        $t.Status = @{}; $t.Status[$Colors.Green] = '#1E7D45'; $t.Status[$Colors.Amber] = '#9A6500'; $t.Status[$Colors.Red] = '#C03535'; $t.Status[$Colors.Gray] = '#6E6E6E'
    } else {
        $t = @{ Bg = '#2B2B2B'; Border = '#404040'; Text = '#FFFFFF'; Muted = '#ABABAB'; Track = '#474747'; Grid = '#4A4A4A'; Accent = '#60CDFF'; Warn = '#F5B83D' }
        $t.Status = @{}; $t.Status[$Colors.Green] = '#4CD486'; $t.Status[$Colors.Amber] = '#F5B83D'; $t.Status[$Colors.Red] = '#FF6B6B'; $t.Status[$Colors.Gray] = '#9A9A9A'
    }
    return $t
}

function New-RoundPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [math]::Min($r, [math]::Min($w, $h) / 2)
    if ($r -le 0.5) { $p.AddRectangle([System.Drawing.RectangleF]::new($x, $y, $w, $h)); return $p }
    $d = $r * 2
    $p.AddArc([System.Drawing.RectangleF]::new($x, $y, $d, $d), 180, 90)
    $p.AddArc([System.Drawing.RectangleF]::new($x + $w - $d, $y, $d, $d), 270, 90)
    $p.AddArc([System.Drawing.RectangleF]::new($x + $w - $d, $y + $h - $d, $d, $d), 0, 90)
    $p.AddArc([System.Drawing.RectangleF]::new($x, $y + $h - $d, $d, $d), 90, 90)
    $p.CloseFigure()
    return $p
}

function Draw-Text($g, [string]$s, $font, [System.Drawing.Color]$color, [double]$x, [double]$y, [double]$w, [string]$align = 'Near') {
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]$align
    $sf.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $br = New-Object System.Drawing.SolidBrush($color)
    $g.DrawString($s, $font, $br, [System.Drawing.RectangleF]::new($x, $y, $w, $font.GetHeight($g) + 2), $sf)
    $br.Dispose(); $sf.Dispose()
}

function Fill-Path($g, $path, [System.Drawing.Color]$color) {
    $br = New-Object System.Drawing.SolidBrush($color); $g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
}

function Draw-Bar($g, [double]$x, [double]$y, [double]$w, [double]$h, [double]$pct, [System.Drawing.Color]$fill, [System.Drawing.Color]$track) {
    Fill-Path $g (New-RoundPath $x $y $w $h ($h / 2)) $track
    if ($pct -gt 0) {
        $fw = [math]::Max($h, $w * [math]::Min(100, $pct) / 100)
        Fill-Path $g (New-RoundPath $x $y $fw $h ($h / 2)) $fill
    }
}

# Used % across the current week window, with a dashed "even pace" diagonal
function Draw-WeekChart($g, $svc, $u, [double]$x, [double]$y, [double]$w, [double]$h, $th, $font, [System.Drawing.Color]$lineColor) {
    $S = $script:Scale
    $reset = $u.WeekResetAt.ToUnixTimeSeconds(); $len = [double]$u.WeekSeconds; $start = $reset - $len
    $nowT = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    Fill-Path $g (New-RoundPath $x $y $w $h (4 * $S)) ([System.Drawing.Color]::FromArgb(18, (C $th.Text)))
    # day dividers
    $gp = New-Object System.Drawing.Pen((C $th.Grid), [single]1)
    for ($d = 1; $d -lt [math]::Round($len / 86400); $d++) {
        $dx = [single]($x + $w * ($d * 86400) / $len)
        $g.DrawLine($gp, $dx, [single]($y + 2 * $S), $dx, [single]($y + $h - 2 * $S))
    }
    $gp.Dispose()
    # even pace
    $dp = New-Object System.Drawing.Pen((C $th.Muted), [single](1.2 * $S))
    $dp.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $g.DrawLine($dp, [single]$x, [single]($y + $h), [single]($x + $w), [single]$y); $dp.Dispose()

    $rows = @($script:History | Where-Object { $_.Key -eq $svc.Key -and [math]::Abs($_.Reset - $reset) -lt 3600 -and $_.T -ge $start -and $_.T -le $nowT } | Sort-Object T)
    $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    foreach ($r in $rows) {
        $pts.Add([System.Drawing.PointF]::new($x + $w * ($r.T - $start) / $len, $y + $h - $h * [math]::Min(100, $r.Used) / 100))
    }
    $pts.Add([System.Drawing.PointF]::new($x + $w * ($nowT - $start) / $len, $y + $h - $h * [math]::Min(100, $u.WeekUsed) / 100))

    if ($pts.Count -ge 2) {
        $area = New-Object System.Drawing.Drawing2D.GraphicsPath
        $area.AddLines($pts.ToArray())
        $area.AddLine($pts[$pts.Count - 1], [System.Drawing.PointF]::new($pts[$pts.Count - 1].X, $y + $h))
        $area.AddLine([System.Drawing.PointF]::new($pts[$pts.Count - 1].X, $y + $h), [System.Drawing.PointF]::new($pts[0].X, $y + $h))
        $area.CloseFigure()
        Fill-Path $g $area ([System.Drawing.Color]::FromArgb(60, $lineColor))
        $lp = New-Object System.Drawing.Pen($lineColor, [single](2 * $S))
        $lp.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $g.DrawLines($lp, $pts.ToArray()); $lp.Dispose()
    } else {
        Draw-Text $g 'History fills in as the app runs' $font (C $th.Muted) ($x + 8 * $S) ($y + 6 * $S) ($w * 0.7) 'Near'
    }
    # Forecast: dotted line from now to the reset (or to where it hits 100%)
    $fc = Get-Forecast $u
    if ($fc.Kind -ne 'early' -and -not $u.LimitReached) {
        $endT = [double]$reset; $endUsed = $fc.ProjUsed
        if ($fc.Kind -eq 'out') { $endT = [double]$fc.RunOutAt.ToUnixTimeSeconds(); $endUsed = 100 }
        $from = $pts[$pts.Count - 1]
        $pp = New-Object System.Drawing.Pen($lineColor, [single](1.6 * $S))
        $pp.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot
        $g.DrawLine($pp, $from, [System.Drawing.PointF]::new($x + $w * ($endT - $start) / $len, $y + $h - $h * $endUsed / 100)); $pp.Dispose()
    }
    $last = $pts[$pts.Count - 1]; $rd = 3.5 * $S
    $br = New-Object System.Drawing.SolidBrush($lineColor)
    $g.FillEllipse($br, [single]($last.X - $rd), [single]($last.Y - $rd), [single]($rd * 2), [single]($rd * 2)); $br.Dispose()

    $ly = $y + $h + 2 * $S
    $startLocal = [DateTimeOffset]::FromUnixTimeSeconds($start).LocalDateTime
    Draw-Text $g $startLocal.ToString('ddd') $font (C $th.Muted) $x $ly ($w / 3) 'Near'
    Draw-Text $g "used  $Dot  ... forecast  $Dot  - - even pace" $font (C $th.Muted) ($x + $w / 8) $ly ($w * 3 / 4) 'Center'
    Draw-Text $g $u.WeekResetAt.LocalDateTime.ToString('ddd') $font (C $th.Muted) ($x + 2 * $w / 3) $ly ($w / 3) 'Far'
}

# Draws the whole panel into a bitmap; returns @{ Bitmap; Hits; Theme }
function Render-Flyout {
    $S = $script:Scale; $th = Get-Theme
    $W = [int](340 * $S); $pad = 16 * $S
    $bmp = New-Object System.Drawing.Bitmap($W, [int](900 * $S))
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear((C $th.Bg))
    $px = [System.Drawing.GraphicsUnit]::Pixel; $reg = [System.Drawing.FontStyle]::Regular
    $fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', [single](14 * $S), $reg, $px)
    $fBody  = New-Object System.Drawing.Font('Segoe UI', [single](12 * $S), $reg, $px)
    $fSmall = New-Object System.Drawing.Font('Segoe UI', [single](11 * $S), $reg, $px)
    $hits = New-Object System.Collections.Generic.List[object]
    $now = [DateTimeOffset]::UtcNow
    $sepPen = New-Object System.Drawing.Pen((C $th.Border), [single]1)
    $y = 14 * $S; $i = 0

    foreach ($svc in $Services) {
        if ($i++ -gt 0) { $y += 6 * $S; $g.DrawLine($sepPen, [single]$pad, [single]$y, [single]($W - $pad), [single]$y); $y += 12 * $S }
        $entry = $script:Data[$svc.Key]
        $u = $null; if ($entry) { $u = $entry.Usage }
        $st = Get-Status $svc $entry $script:State.colorByPace
        $stText = C $th.Status[$st.Color]

        $name = $svc.Name; if ($u) { $name += " $($u.Plan)" }
        Draw-Text $g $name $fTitle (C $th.Text) $pad $y ($W - 2 * $pad)
        $right = 'unavailable'; if ($u) { $right = "$(Get-Left $u.WeekUsed)% left" }
        Draw-Text $g $right $fTitle $stText $pad $y ($W - 2 * $pad) 'Far'
        $hits.Add(@{ Rect = [System.Drawing.RectangleF]::new(0, $y - 4 * $S, $W, 26 * $S); Url = $svc.UsageUrl })
        $y += 26 * $S

        if (-not $u) {
            $msg = 'Loading...'; if ($entry -and $entry.Error) { $msg = $entry.Error }
            Draw-Text $g $msg $fBody (C $th.Muted) $pad $y ($W - 2 * $pad)
            $y += 20 * $S
            continue
        }

        $left = Get-Left $u.WeekUsed; $pace = Get-Pace $u
        $barX = $pad + 44 * $S; $barW = $W - $pad - $barX
        # Week: bar = % left; tick = where % left would be at an even pace
        Draw-Text $g 'Week' $fSmall (C $th.Muted) $pad $y (42 * $S)
        Draw-Bar $g $barX ($y + 4 * $S) $barW (10 * $S) $left (C $st.Color) (C $th.Track)
        $mx = [single]($barX + $barW * (100 - $pace.ElapsedPct) / 100)
        $mp = New-Object System.Drawing.Pen((C $th.Text), [single](2 * $S))
        $g.DrawLine($mp, $mx, [single]($y + 1 * $S), $mx, [single]($y + 17 * $S)); $mp.Dispose()
        $y += 20 * $S
        $resetLine = "Resets $(Format-When $u.WeekResetAt) ($(Format-Span ($u.WeekResetAt - $now)))"
        if ($u.WeekIdle) { $resetLine = 'Weekly window starts with your first use' }
        Draw-Text $g $resetLine $fSmall (C $th.Muted) $barX $y $barW
        $y += 17 * $S
        $fc = Get-Forecast $u
        $fcColor = C $th.Muted
        if ($fc.Kind -eq 'ok') { $fcColor = C $th.Status[$Colors.Green] }
        elseif ($fc.Kind -eq 'tight') { $fcColor = C $th.Status[$Colors.Amber] }
        elseif ($fc.Kind -eq 'out') { $fcColor = C $th.Status[$Colors.Red] }
        Draw-Text $g $fc.Long $fSmall $fcColor $barX $y $barW
        $y += 20 * $S

        if ($null -ne $u.FiveUsed) {
            $fl = Get-Left $u.FiveUsed
            if ($fl -gt 50) { $fc = $Colors.Green } elseif ($fl -ge 20) { $fc = $Colors.Amber } else { $fc = $Colors.Red }
            if ($entry.Error) { $fc = $Colors.Gray }
            $fiveW = $barW - 92 * $S
            Draw-Text $g '5-hour' $fSmall (C $th.Muted) $pad $y (42 * $S)
            Draw-Bar $g $barX ($y + 6 * $S) $fiveW (6 * $S) $fl (C $fc) (C $th.Track)
            $fiveText = "$fl% $Dot idle"
            if ($u.FiveResetAt) { $fiveText = "$fl% $Dot $(Format-Span ($u.FiveResetAt - $now))" }
            Draw-Text $g $fiveText $fSmall (C $th.Muted) ($barX + $fiveW + 6 * $S) $y (86 * $S) 'Far'
            $y += 24 * $S
        }

        $y += 2 * $S
        Draw-WeekChart $g $svc $u $pad $y ($W - 2 * $pad) (56 * $S) $th $fSmall (C $st.Color)
        $y += 76 * $S

        if ($entry.Error) {
            Draw-Text $g "! $($entry.Error) (data from $($entry.LastOk.ToString('ddd HH:mm')))" $fSmall (C $th.Warn) $pad $y ($W - 2 * $pad)
            $y += 18 * $S
        }
    }

    # Footer
    $y += 4 * $S; $g.DrawLine($sepPen, [single]0, [single]$y, [single]$W, [single]$y); $y += 10 * $S
    $upd = 'Not updated yet'; if ($script:LastUpdate) { $upd = "Updated $($script:LastUpdate.ToString('HH:mm'))" }
    if ($script:Jobs.Count -gt 0) { $upd = 'Updating...' }
    Draw-Text $g $upd $fSmall (C $th.Muted) $pad ($y + 1 * $S) ($W - 2 * $pad - 70 * $S)
    Draw-Text $g 'Refresh' $fBody (C $th.Accent) $pad $y ($W - 2 * $pad) 'Far'
    $rw = $g.MeasureString('Refresh', $fBody).Width
    $hits.Add(@{ Rect = [System.Drawing.RectangleF]::new($W - $pad - $rw - 8 * $S, $y - 6 * $S, $rw + 16 * $S, 28 * $S); Action = 'refresh' })
    $y += 28 * $S

    $H = [int][math]::Ceiling($y)
    $sepPen.Dispose(); $fTitle.Dispose(); $fBody.Dispose(); $fSmall.Dispose(); $g.Dispose()
    $out = $bmp.Clone([System.Drawing.Rectangle]::new(0, 0, $W, $H), $bmp.PixelFormat); $bmp.Dispose()
    return @{ Bitmap = $out; Hits = $hits; Theme = $th }
}

# Returns a notification @{Title;Text} or $null
function Test-Alerts($svc, $u) {
    $st = $script:State[$svc.Key]
    $reset = $u.WeekResetAt.ToUnixTimeSeconds()
    $left = Get-Left $u.WeekUsed
    $note = $null
    # Reset times can jitter by a second; treat >1h later as a new week.
    if (-not $u.WeekIdle -and $reset -gt $st.resetAt + 3600) {   # idle weeks have a moving placeholder reset
        if ($st.resetAt -gt 0) {
            $note = @{ Title = "$($svc.Name) weekly limit reset"; Text = "You have $left% of your weekly $($svc.Name) usage left." }
        }
        $st.resetAt = $reset; $st.fired = @()
    }
    $crossed = @($AlertThresholds | Where-Object { $left -le $_ -and $st.fired -notcontains $_ } | Sort-Object)
    if ($crossed.Count -gt 0) {
        $st.fired = @($st.fired + $crossed)
        $note = @{
            Title = "$($svc.Name): $left% of weekly limit left"
            Text  = "Resets in $(Format-Span ($u.WeekResetAt - [DateTimeOffset]::UtcNow))."
        }
    }
    # Once per week: warn when the forecast first says it runs out (after a day of data)
    $fc = Get-Forecast $u
    if (-not $note -and $fc.Kind -eq 'out' -and -not $u.LimitReached -and $fc.Elapsed -ge 86400 -and $st.fired -notcontains -1) {
        $st.fired = @($st.fired + -1)
        $note = @{
            Title = "$($svc.Name) may run out before reset"
            Text  = "At your pace so far it runs out around $(Format-When $fc.RunOutAt), $(Format-Span ($u.WeekResetAt - $fc.RunOutAt)) before the weekly reset."
        }
    }

    # 5-hour window nearly used up. Re-arms only after the window frees up again (>= threshold + 20),
    # because the 5-hour reset time can slide and isn't a reliable "new window" signal.
    $fiveNote = $null
    if ($null -ne $u.FiveUsed -and $u.FiveResetAt) {
        $fl = Get-Left $u.FiveUsed
        if ($fl -ge $FiveHourAlertAt + 20) { $st.fiveFired = $false }
        if ($fl -le $FiveHourAlertAt -and -not $st.fiveFired) {
            $st.fiveFired = $true
            $fiveNote = @{
                Title = "$($svc.Name): 5-hour limit almost used ($fl% left)"
                Text  = "It frees up at $(Format-When $u.FiveResetAt) (in $(Format-Span ($u.FiveResetAt - [DateTimeOffset]::UtcNow)))."
            }
        }
    }
    return @(@($note, $fiveNote) | Where-Object { $_ })
}

# ---------------- One-shot modes ----------------
if ($LibOnly) { return }

if ($MakeIco) { Save-Ico $MakeIco; "Saved $MakeIco"; return }

function New-DemoUsage([string]$key) {
    # Made-up numbers for -Demo (screenshots / offline testing). Claude on track, Codex projected to run out.
    $now = [DateTimeOffset]::UtcNow
    if ($key -eq 'claude') {
        return [pscustomobject]@{ Plan = 'Pro'; WeekUsed = 31.0; WeekResetAt = $now.AddDays(3.8); WeekSeconds = 604800
                                  FiveUsed = 41.0; FiveResetAt = $now.AddMinutes(134); LimitReached = $false }
    }
    return [pscustomobject]@{ Plan = 'Plus'; WeekUsed = 58.0; WeekResetAt = $now.AddDays(4.3); WeekSeconds = 604800
                              FiveUsed = 12.0; FiveResetAt = $now.AddMinutes(201); LimitReached = $false }
}

# Fake, not saved: a plausible work-hours usage curve ending at the current WeekUsed
function Add-DemoHistory([string]$key, $u) {
    $reset = $u.WeekResetAt.ToUnixTimeSeconds(); $start = $reset - $u.WeekSeconds
    $nowT = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $rnd = New-Object System.Random (7 + $key.Length)
    $steps = New-Object System.Collections.Generic.List[object]; $dayFactor = @{}
    for ($t = $start; $t -lt $nowT; $t += 1800) {
        $local = [DateTimeOffset]::FromUnixTimeSeconds($t).LocalDateTime
        if (-not $dayFactor.ContainsKey($local.Date)) { $dayFactor[$local.Date] = 0.4 + 1.2 * $rnd.NextDouble() }
        $wt = 0.0
        if ($local.Hour -ge 9 -and $local.Hour -lt 18) { $wt = (0.3 + $rnd.NextDouble()) * $dayFactor[$local.Date] }
        elseif ($local.Hour -ge 20 -and $local.Hour -lt 23) { $wt = 0.4 * $rnd.NextDouble() * $dayFactor[$local.Date] }
        $steps.Add(@($t, $wt))
    }
    $total = 0.0; foreach ($s in $steps) { $total += $s[1] }
    if ($total -le 0) { return }
    $v = 0.0
    foreach ($s in $steps) {
        $v += $s[1] / $total * $u.WeekUsed
        $script:History.Add([pscustomobject]@{ T = $s[0]; Key = $key; Used = $v; Reset = $reset })
    }
}

if ($Test) {
    New-Item -ItemType Directory -Force -Path $TestOut | Out-Null
    $script:Data = @{}; $script:LastUpdate = Get-Date
    if ($Demo) {
        $script:State = @{ colorByPace = $false }   # don't use the real setting for screenshots
        $script:Scale = 2.0                          # crisp on high-DPI displays; README shows it at half size
    } else {
        $script:State = Get-State
        Import-History -NoPrune   # preview must not modify the real history file
    }
    # One fetch (or demo data) per service, reused for every preview below
    foreach ($svc in $Services) {
        $entry = @{ Usage = $null; Error = $null; LastOk = (Get-Date) }
        if ($Demo) { $entry.Usage = New-DemoUsage $svc.Key }
        else { try { $entry.Usage = Get-Usage $svc.Key } catch { $entry.Error = $_.Exception.Message } }
        if ($entry.Usage -and ($Demo -or $DemoHistory)) { Add-DemoHistory $svc.Key $entry.Usage }
        $script:Data[$svc.Key] = $entry
    }
    $st = @(foreach ($svc in $Services) { Get-Status $svc $script:Data[$svc.Key] $script:State.colorByPace })
    $tip = (@($st[0].Tip) + @($st[1].Tip) + "Updated $($script:LastUpdate.ToString('HH:mm'))") -join "`n"
    "----- Tooltip ($($tip.Length)/127 chars)"; $tip
    "----- Menu"; $st[0].Menu; $st[1].Menu
    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    $bmp = New-ComboBitmap $st[0] $st[1] $size
    $big = New-Object System.Drawing.Bitmap(($size * 8), ($size * 8))
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half'
    $g.DrawImage($bmp, 0, 0, $size * 8, $size * 8); $g.Dispose()
    $out = Join-Path $TestOut 'icon.png'; $big.Save($out); $big.Dispose(); $bmp.Dispose()
    "Saved $out ($size px icon, 8x zoom)"
    # Popup panel previews in both themes
    foreach ($tm in 'dark', 'light') {
        $script:ForceTheme = $tm
        $r = Render-Flyout
        $out = Join-Path $TestOut "panel-$tm.png"; $r.Bitmap.Save($out); $r.Bitmap.Dispose()
        "Saved $out"
    }
    return
}

# ---------------- Tray app ----------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\AiUsageTray')
if (-not $mutex.WaitOne(0)) { return }   # already running

$script:State = Get-State
$script:Data = @{}
$script:IconHandle = [IntPtr]::Zero
$script:LastUpdate = $null
$script:LastErr = @{}
$script:Jobs = @{}         # service key -> in-flight background fetch @{ PS; Handle; Started }
$script:Rs = @{}           # service key -> background runspace with the fetch functions loaded
$script:NextAllowed = @{}  # service key -> no fetching before this time (rate-limit back-off)
$script:PendingNotes = @()
Write-Log "Started (pid $PID)"

function Set-TipText([System.Windows.Forms.NotifyIcon]$ni, [string]$text) {
    # NotifyIcon.Text is capped at 63 chars in .NET Framework; Windows allows 127. Set it directly.
    if ($text.Length -gt 127) { $text = $text.Substring(0, 127) }
    $t = [System.Windows.Forms.NotifyIcon]
    $bf = [Reflection.BindingFlags]'NonPublic,Instance'
    $t.GetField('text', $bf).SetValue($ni, $text)
    if ($t.GetField('added', $bf).GetValue($ni)) { [void]$t.GetMethod('UpdateIcon', $bf).Invoke($ni, @($true)) }
}

function Get-AllStatus {
    # A display error in one service shows as a gray "?" half instead of freezing the whole icon
    foreach ($svc in $Services) {
        try { Get-Status $svc $script:Data[$svc.Key] $script:State.colorByPace }
        catch {
            Write-LogOnce "status-$($svc.Key)" "Display error ($($svc.Name)): $_"
            [pscustomobject]@{ Text = '?'; Color = $Colors.Gray; Tip = @("$($svc.Name): display error (see app.log)"); Menu = @("$($svc.Name): display error (see app.log)") }
        }
    }
}

# Logs a message only when it differs from the last one under the same key (stops 20-second repeats)
$script:LogOnce = @{}
function Write-LogOnce([string]$key, [string]$msg) {
    if ($script:LogOnce[$key] -ne $msg) { Write-Log $msg; $script:LogOnce[$key] = $msg }
}

function Update-Icon {
    $st = @(Get-AllStatus)
    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    if ($size -lt 16) { $size = 16 }
    $bmp = New-ComboBitmap $st[0] $st[1] $size
    $h = $bmp.GetHicon(); $bmp.Dispose()
    $old = $script:IconHandle
    $script:Tray.Icon = [System.Drawing.Icon]::FromHandle($h)
    $script:IconHandle = $h
    if ($old -ne [IntPtr]::Zero) { [void][AiTrayNative]::DestroyIcon($old) }
    $lines = @($st[0].Tip) + @($st[1].Tip)
    if ($script:LastUpdate) { $lines += "Updated $($script:LastUpdate.ToString('HH:mm'))" }
    Set-TipText $script:Tray ($lines -join "`n")
}

# Fetching runs in background runspaces (one per service) so a slow or hung network never
# freezes the icon or panel, and one stuck service doesn't hold up the other.
# The UI thread starts them, a 250 ms timer polls for completion, then Complete-One applies each result.
function Get-BgRunspace([string]$key) {
    if (-not $script:Rs[$key]) {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
        $rs = [runspacefactory]::CreateRunspace($iss)
        $rs.Open()
        $init = [powershell]::Create(); $init.Runspace = $rs
        [void]$init.AddScript(". '$($ScriptPath.Replace("'", "''"))' -LibOnly").Invoke()
        if ($init.Streams.Error.Count) { Write-Log "Background init ($key): $($init.Streams.Error[0])" }
        $init.Dispose()
        $script:Rs[$key] = $rs
    }
    return $script:Rs[$key]
}

function Start-Fetch {
    $script:LastFetch = Get-Date
    $script:RetrySoon = $false
    foreach ($svc in $Services) {
        $k = $svc.Key
        if ($script:Jobs[$k]) { continue }                                                  # still running
        if ($script:NextAllowed[$k]) {
            if ((Get-Date) -lt $script:NextAllowed[$k]) { continue }                        # backing off
            $script:NextAllowed.Remove($k)
        }
        try {
            $ps = [powershell]::Create(); $ps.Runspace = Get-BgRunspace $k
            [void]$ps.AddScript('param($k) $r = [pscustomobject]@{ Key = $k; Usage = $null; Error = $null }; try { $r.Usage = Get-Usage $k } catch { $r.Error = $_.Exception.Message }; $r').AddArgument($k)
            $script:Jobs[$k] = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
        } catch {
            Write-Log "Start-Fetch ($k) failed: $_"
            $script:Rs[$k] = $null
        }
    }
    if ($script:Jobs.Count -gt 0) { $script:FetchPoll.Start() }
}

function Complete-One([string]$key, $r) {
    $svc = $Services | Where-Object { $_.Key -eq $key }
    $entry = $script:Data[$key]
    if (-not $entry) { $entry = @{ Usage = $null; Error = $null; LastOk = (Get-Date) }; $script:Data[$key] = $entry }
    $msg = $null
    if (-not $r) { $msg = 'Update timed out' } elseif ($r.Error) { $msg = [string]$r.Error }

    if (-not $msg) {
        if ($script:LastErr[$key]) { Write-Log "$($svc.Name): OK again" }
        $script:LastErr[$key] = $null
        $u = $r.Usage
        $entry.Usage = $u; $entry.Error = $null; $entry.LastOk = Get-Date
        if (-not $u.WeekIdle) { try { Add-History $svc $u } catch { Write-Log "Add-History failed: $_" } }
        $script:PendingNotes += @(Test-Alerts $svc $u)
        Save-State
        return
    }

    $keepMinutes = 0
    if ($msg -match '^Rate limited') {
        # Back off: honor Retry-After, but wait at least 10 minutes; keep showing data for 30 min
        $sec = 600
        if ($msg -match 'retry in (\d+)s') { $sec = [math]::Max(600, [int]$Matches[1]) }
        $script:NextAllowed[$key] = (Get-Date).AddSeconds($sec)
        $msg = "Rate limited - retrying at $($script:NextAllowed[$key].ToString('HH:mm'))"
        $keepMinutes = 30
    } elseif ($msg -eq "Can't reach service" -or $msg -eq 'Update timed out') {
        # Network blip (e.g. just woke up): retry in a minute; keep showing data for 15 min
        $script:RetrySoon = $true
        $keepMinutes = 15
    }
    # Log changes; always log rate limits (at most one per 10 min) so the log shows how long throttling lasts
    if ($msg -ne $script:LastErr[$key] -or $msg -like 'Rate limited*') { Write-Log "$($svc.Name): $msg" }
    $script:LastErr[$key] = $msg
    if (-not $entry.Usage -or ((Get-Date) - $entry.LastOk).TotalMinutes -ge $keepMinutes) { $entry.Error = $msg }
}

function Show-PendingNotes {
    $notes = @($script:PendingNotes); $script:PendingNotes = @()
    try {
        if ($notes.Count -eq 1) {
            $script:Tray.ShowBalloonTip(10000, $notes[0].Title, $notes[0].Text, [System.Windows.Forms.ToolTipIcon]::Info)
        } elseif ($notes.Count -gt 1) {
            # Balloons replace each other, so combine them
            $script:Tray.ShowBalloonTip(10000, 'AI usage alerts', (($notes | ForEach-Object { $_.Title }) -join "`n"), [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } catch { Write-Log "Notification failed: $_" }
}

function Update-View {
    try { Update-Icon; $script:LogOnce['icon'] = $null } catch { Write-LogOnce 'icon' "Update-Icon failed: $_" }
    try { if ($script:Flyout -and $script:Flyout.Visible) { Update-Flyout } } catch { Write-LogOnce 'flyout' "Update-Flyout failed: $_" }
}

function Update-All([bool]$fetch) {
    if ($fetch) { Start-Fetch }
    Update-View
}

$script:FetchPoll = New-Object System.Windows.Forms.Timer
$script:FetchPoll.Interval = 250
$script:FetchPoll.add_Tick({
    $changed = $false
    foreach ($k in @($script:Jobs.Keys)) {
        $j = $script:Jobs[$k]
        try {
            if ($j.Handle.IsCompleted) {
                $res = $null
                try { $res = @($j.PS.EndInvoke($j.Handle))[0] } catch { Write-Log "Fetch ($k) failed: $_" }
                $j.PS.Dispose(); $script:Jobs.Remove($k)
                Complete-One $k $res; $changed = $true
            } elseif (((Get-Date) - $j.Started).TotalSeconds -gt 45) {
                Write-Log "Fetch ($k) took over 45s; abandoned it"
                try { [void]$j.PS.BeginStop($null, $null) } catch {}
                $script:Jobs.Remove($k); $script:Rs[$k] = $null   # fresh runspace next time; the stuck one finishes on its own
                Complete-One $k $null; $changed = $true
            }
        } catch {
            Write-Log "Poll ($k) failed: $_"
            $script:Jobs.Remove($k); $changed = $true
        }
    }
    if ($script:Jobs.Count -eq 0) { $script:FetchPoll.Stop() }
    if ($changed) {
        $script:LastUpdate = Get-Date
        Show-PendingNotes
        Update-View
    }
})

function Update-Flyout {
    $r = Render-Flyout
    $old = $script:FlyBmp
    $script:FlyBmp = $r.Bitmap; $script:FlyHits = $r.Hits
    $script:Flyout.BackColor = C $r.Theme.Bg
    $script:Flyout.ClientSize = [System.Drawing.Size]::new($r.Bitmap.Width, $r.Bitmap.Height)
    $script:Flyout.SetBorderColor((C $r.Theme.Border))
    $script:Flyout.Invalidate()
    if ($old) { $old.Dispose() }
}

function Show-Flyout {
    Update-Flyout
    $f = $script:Flyout
    $cur = [System.Windows.Forms.Cursor]::Position
    $scr = [System.Windows.Forms.Screen]::FromPoint($cur)
    $wa = $scr.WorkingArea; $b = $scr.Bounds; $m = [int](12 * $script:Scale)
    $x = [int][math]::Min($wa.Right - $f.Width - $m, $cur.X - [int]($f.Width / 2))
    $x = [int][math]::Max($wa.Left + $m, $x)
    if ($wa.Top -gt $b.Top) { $y = $wa.Top + $m } else { $y = $wa.Bottom - $f.Height - $m }   # taskbar at top or bottom
    $f.Location = [System.Drawing.Point]::new($x, $y)
    $f.Show(); $f.Activate()
    [void][AiTrayNative]::SetForegroundWindow($f.Handle)
}

function Hide-Flyout {
    if ($script:Flyout.Visible) { $script:Flyout.Hide(); $script:FlyHidden = Get-Date }
}

function Find-Hit($pt) {
    foreach ($h in $script:FlyHits) { if ($h.Rect.Contains([single]$pt.X, [single]$pt.Y)) { return $h } }
    return $null
}

function Set-Startup([bool]$on) {
    if ($on) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($StartupLnk)
        if ($env:AIUSAGETRAY_EXE -and (Test-Path $env:AIUSAGETRAY_EXE)) {
            $lnk.TargetPath = $env:AIUSAGETRAY_EXE; $lnk.Arguments = ''
        } else {
            $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
            $lnk.Arguments = "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$ScriptPath`""
        }
        $lnk.WorkingDirectory = Split-Path $ScriptPath
        $lnk.Description = 'AI Usage Tray'
        $lnk.Save()
    } elseif (Test-Path $StartupLnk) {
        Remove-Item $StartupLnk
    }
}

# Right-click menu is rebuilt each time it opens so the details are current
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false
$menu.add_Opening({
    $menu.Items.Clear()
    $st = @(Get-AllStatus)
    for ($i = 0; $i -lt $Services.Count; $i++) {
        $first = $true
        foreach ($line in $st[$i].Menu) {
            $mi = $menu.Items.Add($line)
            $mi.Tag = $Services[$i].UsageUrl
            $mi.ToolTipText = "Open $($Services[$i].Name) usage page"
            if ($first) { $mi.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold); $first = $false }
            $mi.add_Click({ param($s, $e) Start-Process $s.Tag })
        }
        [void]$menu.Items.Add('-')
    }
    if ($script:LastUpdate) {
        $mi = $menu.Items.Add("Updated $($script:LastUpdate.ToString('HH:mm'))  -  Refresh now")
    } else { $mi = $menu.Items.Add('Refresh now') }
    $mi.add_Click({ Update-All $true })
    $mp = New-Object System.Windows.Forms.ToolStripMenuItem('Color by forecast (instead of % left)')
    $mp.Checked = $script:State.colorByPace
    $mp.add_Click({ $script:State.colorByPace = -not $script:State.colorByPace; Save-State; Update-All $false })
    [void]$menu.Items.Add($mp)
    $ms = New-Object System.Windows.Forms.ToolStripMenuItem('Start with Windows')
    $ms.Checked = Test-Path $StartupLnk
    $ms.add_Click({ param($s, $e) try { Set-Startup (-not $s.Checked) } catch { Write-Log "Set-Startup failed: $_" } })
    [void]$menu.Items.Add($ms)
    [void]$menu.Items.Add('-')
    $mq = $menu.Items.Add('Quit')
    $mq.add_Click({ $script:Tray.Visible = $false; $script:Tray.Dispose(); [System.Windows.Forms.Application]::Exit() })
    $_.Cancel = $false
})
# ContextMenuStrip won't open when empty; give it a placeholder that Opening replaces
[void]$menu.Items.Add('...')

$menu.add_Opened({ Hide-Flyout })

# Popup panel: click the tray icon to open/close; closes when you click elsewhere or press Esc
Import-History
$script:FlyBmp = $null; $script:FlyHits = @(); $script:FlyHidden = [datetime]::MinValue
$script:Flyout = New-Object AiFlyoutForm
$script:Flyout.Text = 'AI Usage'
$script:Flyout.add_Paint({ param($s, $e) if ($script:FlyBmp) { $e.Graphics.DrawImageUnscaled($script:FlyBmp, 0, 0) } })
$script:Flyout.add_Deactivate({ Hide-Flyout })
$script:Flyout.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Hide-Flyout } })
$script:Flyout.add_MouseMove({ param($s, $e)
    if (Find-Hit $e.Location) { $s.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $s.Cursor = [System.Windows.Forms.Cursors]::Default } })
$script:Flyout.add_MouseClick({ param($s, $e)
    $h = Find-Hit $e.Location
    if (-not $h) { return }
    if ($h.Url) { Hide-Flyout; Start-Process $h.Url }
    elseif ($h.Action -eq 'refresh') { Update-All $true }
})

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.ContextMenuStrip = $menu
$script:Tray.add_MouseClick({ param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:Flyout.Visible) { Hide-Flyout; return }
    # Clicking the icon while open first closes it (focus loss); don't immediately reopen
    if (((Get-Date) - $script:FlyHidden).TotalMilliseconds -lt 400) { return }
    Show-Flyout
})
Update-Icon
$script:Tray.Visible = $true

# Every 20s: redraw (keeps countdowns current) and decide whether to fetch.
# Timers don't run during sleep, so a long gap since the last tick means the PC just woke up.
$script:LastTick = Get-Date; $script:LastFetch = Get-Date; $script:RetrySoon = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20000
$timer.add_Tick({
    $now = Get-Date
    $woke = ($now - $script:LastTick).TotalSeconds -gt 90
    $script:LastTick = $now
    $since = ($now - $script:LastFetch).TotalSeconds
    $backoffOver = @($script:NextAllowed.Values | Where-Object { $now -ge $_ }).Count -gt 0
    $fetch = $woke -or $backoffOver -or $since -ge ($RefreshMinutes * 60) -or ($script:RetrySoon -and $since -ge 60)
    Update-All $fetch
})
$timer.Start()

Update-All $true
[System.Windows.Forms.Application]::Run()
$timer.Stop()
if ($script:IconHandle -ne [IntPtr]::Zero) { [void][AiTrayNative]::DestroyIcon($script:IconHandle) }
$mutex.ReleaseMutex()
