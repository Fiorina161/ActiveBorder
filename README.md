# ActiveBorder

A tiny Windows 11 utility that draws a red and white hazard stripe around
whichever window currently has keyboard focus.

It lives in the system tray, needs no configuration, and costs effectively
nothing to leave running.

## Why

On a wide or multi-monitor desktop it is genuinely easy to lose track of which
window your keystrokes are going to. The cue Windows gives you is a subtle
title-bar tint, and plenty of applications never show it at all: Visual
Studio, Windows Terminal, VS Code, Chrome and anything Electron draw their own
title bars and ignore the system accent colour entirely.

ActiveBorder answers "where am I typing?" with an outline you cannot miss, and
it behaves the same for every application because it never relies on the
application to draw anything.

## What it does

- Draws a **5-pixel hazard stripe** just inside the edge of the focused
  window: red `#FF0000` and white `#FFFFFF` bands at 45 degrees, like the
  markings on a warning panel.
- Follows that window as it moves, resizes, snaps, maximizes, restores and
  crosses between monitors.
- Moves to the new window the moment focus changes, and disappears when you
  click the desktop or minimize everything.
- Is **click-through**. The outline covers the outermost 5 pixels of the
  window, but every click passes straight to the application beneath it.
- Never touches the target application. No window styles are changed, no title
  bar is redrawn, nothing is injected into any process. The outline is four
  separate transparent windows of our own, positioned around the target.

## Requirements

- Windows 11 (developed against 10.0.26200; Windows 10 1703+ should work but
  is untested)
- The .NET 8 **Runtime** to run it - not the Desktop Runtime, since there is
  no WPF or WinForms here - or nothing at all if you use the self-contained
  build below
- The .NET 8 SDK or newer to build it

## Build

```
dotnet build -c Release
```

The executable lands in `bin\Release\net8.0-windows\ActiveBorder.exe`.

For a single self-contained `.exe` that runs on a machine with no .NET
installed (about 65 MB):

```
dotnet publish -c Release -r win-x64 --self-contained true ^
  -p:PublishSingleFile=true --source https://api.nuget.org/v3/index.json
```

> The repo ships a `NuGet.config` that clears inherited package sources. This
> project has no package references, so an ordinary `dotnet build` is fully
> offline. A self-contained publish is the exception: it needs the .NET
> runtime packs, hence the explicit `--source`.

## Run

```
ActiveBorder.exe
```

That is the whole setup. No installer, no first-run wizard, no settings file.
Focus a window and it gets an outline.

The utility has **no window and no taskbar button**. It is built as a `WinExe`
and lives entirely in the notification area. Its icon is a small hollow red
square - solid rather than striped, because stripes do not resolve at 16x16.

### Finding the tray icon

**Windows 11 hides new tray icons by default.** The first time you run
ActiveBorder, the icon will almost certainly be inside the overflow flyout
behind the `^` chevron rather than on the taskbar itself. If you look at the
taskbar and see nothing, that is why - it is running.

To pin it somewhere visible, either drag it out of the flyout onto the
taskbar, or go to Settings > Personalization > Taskbar > "Other system tray
icons" and switch ActiveBorder on.

### Quitting

**Right-click the tray icon and choose "Exit ActiveBorder".**

That is the only way to stop it, and it shuts down cleanly: the tray icon is
removed, the system hooks are unhooked, the overlay windows are destroyed and
the GDI bitmaps are freed before the process exits.

### Starting it with Windows

Not built in, deliberately. If you want it, put a shortcut to
`ActiveBorder.exe` in your Startup folder - press Win+R and enter
`shell:startup`.

## Changing the colour or thickness

Three environment variables, read once when the utility starts. No rebuild,
no settings file:

| Variable | Meaning | Default |
| --- | --- | --- |
| `AB_COLOR_1` | first stripe colour, `RRGGBB` | `FF0000` red |
| `AB_COLOR2` | second stripe colour, `RRGGBB` | `FFFFFF` white |
| `AB_WIDTH` | border thickness in physical pixels, 1 to 64 | `5` |

```powershell
$env:AB_COLOR_1 = "00A0FF"
$env:AB_COLOR2  = "202020"
$env:AB_WIDTH   = "9"
.\bin\Release\net8.0-windows\ActiveBorder.exe
```

To make them stick, set them for your account once and they apply to every
later run:

```powershell
[Environment]::SetEnvironmentVariable("AB_COLOR_1", "00A0FF", "User")
```

A leading `#` is accepted, so `#00A0FF` works as well as `00A0FF`.

**Anything missing, malformed or out of range falls back to its default**
rather than failing. A tray utility with no console has nowhere to report a
bad value, and refusing to start over one typo would be worse than ignoring
it. `AB_WIDTH=wide`, `AB_WIDTH=999` and `AB_COLOR_1=nothex` all just leave
that one setting at its default; the others still apply.

The values are fixed for the lifetime of the process: the strip bitmaps are
rendered once at start-up, so a change takes effect the next time you run it.

The tray icon uses `AB_COLOR_1`, so it always matches the border.

`AB_WIDTH` is in *physical* pixels. The process is per-monitor-v2 DPI aware,
so the system does not scale it: 5 means 5 real pixels on every monitor. The
upper limit of 64 exists because the strips are as long as the virtual
screen, so their bitmaps grow with the thickness.

At the default 5 px the stripe reads as a fine diagonal hatch. For something
closer to real hazard tape, try `AB_WIDTH=12`.

One thing that is still a compile-time constant, in
[`OverlayWindow.cs`](OverlayWindow.cs):

```csharp
private const int STRIPE_PERIOD = 12;   // one first-colour + one second-colour band
```

It is the length of one full band pair measured along an edge. The bands run
at 45 degrees, so the width you see across a band is about 0.35 of it. The
pattern is anchored to screen coordinates rather than to each strip, so the
diagonals run continuously around all four corners instead of restarting at
each one.

## Tested against

Each of these was checked both for correct geometry and for the right pixels
actually reaching the screen:

| Application | Window class | Result |
| --- | --- | --- |
| Windows Terminal | `CASCADIA_HOSTING_WINDOW_CLASS` | pass |
| Visual Studio 2026 | `HwndWrapper[DefaultDomain;;...]` | pass |
| Brave / Chromium | `Chrome_WidgetWin_1` | pass |
| Microsoft Teams (WebView2) | `TeamsWebView` | pass |
| PhpStorm (JetBrains, JVM) | `SunAwtFrame` | pass |
| Windows Explorer | `CabinetWClass` | pass |
| Plain Win32 window | `WindowsForms10.Window...` | pass |

Custom title bars, borderless windows and Electron shells all work, because
none of it depends on chrome drawn by the application itself.

Resource use while running: **0 ms of CPU measured over 20 seconds idle**, and
about 22 MB of working set.

## How it works, briefly

```
  focus changes            SetWinEventHook(EVENT_SYSTEM_FOREGROUND)
        |
        v
  measure visible edge     DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)
        |
        v
  position four thin       UpdateLayeredWindow; layered and click-through,
  transparent windows      placed directly above the target in the z-order
```

Four thin strips rather than one large frame-shaped overlay, so memory stays
small no matter how big the window is, and the middle of the target is left
genuinely untouched rather than merely transparent.

Geometry is event-driven too, through `EVENT_OBJECT_LOCATIONCHANGE` scoped to
the process that owns the target, with a low-rate timer as a safety net for
the cases events do not cover. Nothing ever polls the window list.

For the details - why each API, the awkward parts, and what has actually been
verified - see **[DESIGN.md](DESIGN.md)**.

## Project layout

```
*.cs              the utility (7 source files, no dependencies)
tests/            8 PowerShell verification suites
DESIGN.md         implementation notes and verification results
```

About 1,800 lines of C# with no NuGet packages, no WPF or WinForms and no GUI
framework - just Win32, GDI and DWM through P/Invoke.

## Tests

Eight PowerShell suites cover geometry, colour, click-through, z-order, CPU,
the tray icon, attaching to newly created windows, and the environment
overrides. Build first, then:

```
pwsh -NoProfile -File tests\01-geometry.ps1
```

[DESIGN.md](DESIGN.md) lists them all and what each one covers. They create
and focus their own windows, so do not type while one is running.

## Known limitations

- **Mixed-DPI is unverified.** The code works in physical pixels throughout
  and is per-monitor-v2 aware, which is the correct construction, but both
  monitors on the development machine run at 96 DPI, so moving a window
  between a 100% and a 150% display has never actually been tested.
- **Square corners.** The outline is a plain rectangle, so on the rounded
  windows of Windows 11 the corners show small square nubs. Rounded-corner
  handling is out of scope for now.
- **Elevated windows lag slightly** on their first movement. UIPI stops our
  hooks receiving events from higher-integrity processes, so those windows are
  tracked by polling until the adaptive timer speeds up.
- No configuration UI, hotkeys, per-application colours or auto-start. The
  tray menu has exactly one item.

## License

None yet. Without one, default copyright applies: the code is readable here
but not licensed for reuse.
