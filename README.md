# AI Usage Tray

A Windows tray icon that shows how much of your weekly **Claude** (Pro/Max) and **Codex** (ChatGPT Plus/Pro) usage limits you have left, and whether it will last until the reset.

- **Icon**: one split icon. The top half is Claude and the bottom half is Codex. Each half shows the % of the weekly limit left, colored green (>50%), amber (20–50%), red (<20%) or gray (can't update).
- **Hover**: a short summary with reset countdowns, the 5-hour window and the forecast.
- **Click**: a popup panel with bars, a pace marker, a forecast ("At this pace: ~86% left at reset" / "runs out Tue 09:58") and a chart of this week's usage.
- **Right-click**: full details, links to each service's usage page, refresh, *Color by forecast*, *Start with Windows*, and quit.
- **Notifications**: when weekly usage drops to 50/25/10% left, when the forecast says you'll run out before the reset, when a 5-hour window is almost used up, and when the weekly limit resets.

## Requirements

- Windows 10/11, with Windows PowerShell 5.1 (built in). Nothing to install.
- **Claude Code** signed in with a Claude subscription (it creates `%USERPROFILE%\.claude\.credentials.json`).
- **Codex CLI** signed in with ChatGPT (it creates `%USERPROFILE%\.codex\auth.json`).

Either one alone also works; the other half of the icon stays gray.

## Build and run

The `.exe` is a tiny host that runs `AiUsageTray.ps1`. With it, Windows lists the tray icon as "AI Usage Tray" and remembers its pin. Build it with the C# compiler that ships with Windows:

```powershell
# app icon (optional, already in src/)
powershell -NoProfile -ExecutionPolicy Bypass -File .\AiUsageTray.ps1 -MakeIco .\src\AiUsageTray.ico

# compile
& "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /optimize `
  /out:AiUsageTray.exe /win32icon:src\AiUsageTray.ico `
  "/r:$([PSObject].Assembly.Location)" /r:System.Windows.Forms.dll src\AiUsageTray.cs
```

Then run `AiUsageTray.exe`. Keep it next to `AiUsageTray.ps1`, because the exe loads the script from its own folder. Right-click the icon and select **Start with Windows** to launch it at login. If Windows hides the icon under **^**, drag it onto the taskbar once.

Without the exe, you can run the script directly. The icon then shows up as "Windows PowerShell":

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\AiUsageTray.ps1
```

## How it works

Every 5 minutes it asks each service for your current usage, using the login the CLI already stored:

| | Endpoint | Login file |
|---|---|---|
| Claude | `https://api.anthropic.com/api/oauth/usage` | `~/.claude/.credentials.json` |
| Codex | `https://chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` |

These are the same endpoints that `/usage` in Claude Code and `/status` in Codex use. Your tokens are only sent to the company that issued them.

**The app only reads your login files and never changes them.** It does not renew tokens, so it can't sign the CLIs out. The CLIs renew their logins when you use them. If you haven't used one for a while, its half goes gray with "Login expired - open Claude Code" (or Codex). Run the CLI once and it recovers on the next refresh.

The **forecast** assumes the rest of the week goes like the week so far (average rate since the window started). For the first 12 hours it says "too early".

## Files

Everything is stored under `%LOCALAPPDATA%\AiUsageTray\`:

| File | What |
|---|---|
| `state.json` | settings (color mode) and which alerts already fired |
| `history.csv` | one row per refresh, for the chart. Kept for 3 weeks |
| `app.log` | errors and recoveries. Rotates at 256 KB |
| `host.log` | only if the exe itself fails to start the script |

## Settings

These are at the top of `AiUsageTray.ps1`: refresh interval, weekly alert thresholds, the 5-hour alert level and colors.

## Limitations

- **The usage endpoints are not public APIs.** They can change without notice. If one does, that half goes gray, and the reason shows in the panel and in `app.log`.
- **Claude's endpoint has a strict rate limit.** Normal polling is fine. If it does return HTTP 429, the app backs off for at least 10 minutes and keeps showing the last numbers.
- **The chart only has data from while the app was running.**
- **The panel opens correctly with the taskbar at the bottom or top of the screen.** Side taskbars aren't handled yet.
- **Two digits on the icon**: 100% left shows as 99.

## Development

`-Test` prints the current tooltip and menu text and saves icon and panel previews to `%TEMP%\AiUsageTray-preview`. Add `-DemoHistory` to preview the chart with made-up data. Test mode queries the live endpoints, so use it sparingly. See `CLAUDE.md` for code structure notes.
