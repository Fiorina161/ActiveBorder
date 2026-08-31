# ActiveBorder - design notes

Implementation detail, the reasoning behind the awkward parts, and what has
actually been verified. For what the utility is and how to run it, see
[README.md](README.md).

## Files

| File | Purpose |
| --- | --- |
| `Program.cs` | DPI awareness, start-up wiring, the message loop |
| `NativeMethods.cs` | All P/Invoke declarations, constants and structs |
| `FocusTracker.cs` | WinEvent hooks, target lifetime, the safety-net timer |
| `OverlayWindow.cs` | The four border strips: creation, drawing, z-order |
| `WindowBounds.cs` | Which windows qualify, and where their visible edge is |
| `TrayIcon.cs` | The notification-area icon, its menu, and shutdown |

No dependencies beyond the .NET base class library.

## Win32 APIs used, and why

### Focus detection

- **`SetWinEventHook(EVENT_SYSTEM_FOREGROUND, ...)`** with
  `WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS` — the push notification
  for "the foreground window changed". No polling for focus.
- **`SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART..MOVESIZEEND)`** — tells us a
  drag is in progress so tracking can temporarily run at 30 Hz.
- **`SetWinEventHook(EVENT_SYSTEM_MINIMIZESTART..MINIMIZEEND)`** — hide and
  restore the border.
- **`SetWinEventHook(EVENT_OBJECT_DESTROY..EVENT_OBJECT_LOCATIONCHANGE, idProcess: target)`**
  — geometry tracking. This one is re-registered per target and **scoped to
  the target's process**, so the utility never receives events for the rest
  of the machine and never enumerates windows.

Out-of-context hooks are delivered by dispatching to the thread that
installed them, which is why the `GetMessage` loop in `Program.cs` is load
bearing rather than decorative: no message loop, no callbacks.

### Measuring the target

- **`DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`** — the visible
  frame. `GetWindowRect` includes the invisible resize border DWM adds to
  sizable windows (7-8 px per side at 100% scaling), which would place the
  border well outside the pixels the user actually sees. `GetWindowRect` is
  kept only as a fallback.
- **`DwmGetWindowAttribute(DWMWA_CLOAKED)`** — a window can be
  `IsWindowVisible` yet not on screen at all: suspended UWP apps, windows on
  another virtual desktop, Explorer's hidden `CabinetWClass` instances.
- `IsWindow` / `IsWindowVisible` / `IsIconic` / `GetClassName` /
  `GetWindowThreadProcessId` — eligibility filtering.

### The overlay

- **`CreateWindowEx`** with
  `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`
  and a plain `WS_POPUP` style: per-pixel alpha, click-through, never
  activates, never appears in the taskbar or Alt-Tab.
- **`UpdateLayeredWindow`** with a premultiplied 32-bit ARGB DIB section —
  moves, resizes and repaints each strip in a single atomic call, so a stale
  or half-positioned border is never on screen. It also avoids depending on
  `WM_PAINT` timing entirely.
- **`SetWindowPos(..., SWP_NOACTIVATE)`** for z-order only.
- `WM_NCHITTEST` returns `HTTRANSPARENT` and `WM_MOUSEACTIVATE` returns
  `MA_NOACTIVATE`, as belt-and-braces alongside the extended styles.

### The tray icon

- **`Shell_NotifyIcon(NIM_ADD / NIM_DELETE)`** — registers and removes the
  notification-area icon. The icon is owned by a hidden `WS_EX_TOOLWINDOW`
  window that exists only to receive the shell's callback message.
- **`RegisterWindowMessage("TaskbarCreated")`** — the shell broadcasts this
  when Explorer restarts, which destroys every notification icon. Without
  handling it, an Explorer crash would leave the utility running with no way
  to reach it, so the icon is simply added again.
- **`CreatePopupMenu` / `AppendMenu` / `TrackPopupMenuEx`** — the right-click
  menu. `TrackPopupMenuEx` is called without `TPM_RETURNCMD`, so choosing the
  item posts a normal `WM_COMMAND` to the owner window; that keeps the menu
  and any other trigger on one code path.
- **`SetForegroundWindow` before, and a `WM_NULL` post after** — the shell
  requirement from KB135788. Skip it and the menu will not dismiss when the
  user clicks away; it stays stuck on screen. This is also why the tray
  window deliberately does *not* use `WS_EX_NOACTIVATE`, unlike the overlay
  strips.
- **`CreateIconIndirect`** over a 32-bit DIB — the icon is drawn in memory at
  `SM_CXSMICON` rather than shipped as a binary `.ico`. Its ring is fully
  opaque and its interior fully transparent, the two cases where
  premultiplied and straight alpha agree, so no premultiplication is needed.

### DPI

- **`SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`**
  is the first thing `Main` does, before any window exists. Under per-monitor
  v2, `GetWindowRect` and `DWMWA_EXTENDED_FRAME_BOUNDS` report physical
  pixels in the virtual-screen coordinate space, and the compositor does not
  stretch our output — so 5 pixels means 5 physical pixels on every monitor.

## Design decisions worth knowing

**Four strips, not one frame-shaped window.** A single overlay covering the
whole target would need an `UpdateLayeredWindow` bitmap the size of that
window — roughly 33 MB for a maximized 4K window — plus a same-sized DWM
redirection surface. Four thin strips share two small solid bitmaps that are
allocated once and reused for the life of the process, and they leave the
interior of the target genuinely untouched rather than merely transparent.

**The border is drawn just inside the visible frame, not outside it.**
Drawing outside looks marginally nicer for floating windows, but for a
maximized or snapped window the outside falls off the screen or under the
taskbar — exactly the case where a focus indicator matters most. Because the
strips are click-through, covering the outermost 5 px is purely visual.

**Z-order: above the target, not globally topmost.** The strips are inserted
directly above the target rather than made `HWND_TOPMOST`, so they never
float over unrelated windows. Note the direction of `SetWindowPos`:
`hWndInsertAfter` names the window the positioned window goes *behind*, so
passing the target itself puts the border underneath it — where, since the
border is drawn inside the frame, it is completely invisible. The anchor has
to be the window immediately above the target. If the target is itself
topmost, the strips join the topmost band to match, and drop back out again
when focus moves to an ordinary window.

**The strips are chained to each other, not all pinned to one anchor.**
Placing four windows takes four `SetWindowPos` calls, and some applications —
Teams and other WebView2/Electron shells — raise themselves in between.
Anchoring each strip to the previous one keeps the four contiguous so they
move as a single group; anchoring them all to the same window let a
mid-sequence raise strand three of them below the target while the first
stayed above it.

**The safety-net timer reconciles against the attached window, not the last
window seen.** A window that has just been created is routinely *not* eligible
at the instant its `EVENT_SYSTEM_FOREGROUND` arrives - DWM still has it
cloaked for the open animation, or it has no size yet. An earlier version
remembered the last HWND it had looked at, so such a window was rejected once
and then never re-examined, because the foreground HWND never changed again
afterwards. A freshly launched application therefore got no border until the
user clicked another window and back. Comparing against the attached target
instead means the retry continues until the utility is attached to whatever
actually holds the foreground. `tests\07-late-eligible.ps1` covers this
exactly, and fails on the older logic.

**Event-driven first, polling only as a safety net.** The timer idles at
5 Hz and only steps up to 30 Hz when polling actually catches a change that
events missed, decaying back afterwards. This matters for elevated windows,
where UIPI silently drops every WinEvent — those are tracked by polling
alone, and the utility adapts to that on its own without needing to detect
elevation.

**The z-order health check ignores windows that are never drawn, and counts
all four strips.** The z-order is full of `MSCTFIME UI`, `IME`, and 0x0
helper windows that can sit between the target and the border. A naive
`GetWindow(target, GW_HWNDPREV)` comparison treats those as an obstruction
and re-orders four windows on every single timer tick; that alone cost 0.47%
CPU permanently before it was fixed. Equally, the check must require *all*
four strips above the target — an earlier version returned on the first hit
and therefore reported a one-edge-only border as healthy.

## Windows that are deliberately ignored

The desktop (`Progman`, `WorkerW`), the taskbars (`Shell_TrayWnd`,
`Shell_SecondaryTrayWnd`), the tray overflow, shell flyouts
(`Windows.UI.Core.CoreWindow`, which on Windows 11 is the Start menu, search
and similar), Task View / Alt-Tab / snap assist
(`XamlExplorerHostIslandWindow`), the utility's own windows, and any window
that is invisible, minimized, cloaked, or smaller than 10x10 pixels.

Elevated (administrator) windows still get a border, tracked by polling; the
utility does not attempt to inject into or elevate against them.

## Verified behaviour

Automated harnesses checked the following on Windows 11 (26200) with a
two-monitor layout whose virtual screen origin is `-1920,0`:

- Border geometry exactly matches `DWMWA_EXTENDED_FRAME_BOUNDS` on all four
  edges, at the initial position, after a move, after a resize, on the
  monitor at **negative X**, maximized, and restored.
- Exactly 5 physical pixels of the hazard pattern on each edge, verified by
  screen capture; the 6th row/column is the application, not the border, so
  the border is exactly 5 px rather than merely at least 5 px.
- The interior is never painted, and `WindowFromPoint` returns the target -
  never a strip - on all four edges, so clicks pass straight through.
- Ten consecutive focus alternations between two windows: the border followed
  every one, and there were never more or fewer than four strips.
- The border disappears entirely when the target is minimized, and leaves a
  window as soon as it loses focus.
- The overlay was never the foreground window across repeated sampling.
- Idle CPU: at most one 15.6 ms scheduler quantum over 20 s (0.08% of one
  core), frequently 0. Working set ~22 MB, private bytes ~8 MB.

Tray behaviour, driven by posting the shell's own callback message rather
than by clicking:

- No window of the process claims a taskbar button, by the shell's own rule
  (visible, unowned, and either `WS_EX_APPWINDOW` or not `WS_EX_TOOLWINDOW`),
  and there is no console window.
- A right-click on the icon produces a popup menu whose single item reads
  "E&xit ActiveBorder" and carries the exit command id, read back
  cross-process with `MN_GETHMENU`.
- The process owns the foreground while the menu is up, which is what makes
  the menu dismiss on click-away. Note this only holds when the caller has
  the foreground grant that a real tray click confers; a bare synthetic
  `PostMessage` does not, and the check fails without it.
- Choosing the exit item ends the process with exit code 0 and leaves behind
  no overlay, tray or controller windows, and no process.

Attaching to a newly created window (`tests\07-late-eligible.ps1`):

- A window that takes the foreground while still hidden gets no border, as it
  should.
- When it is then shown with `SW_SHOWNA` - visible, still foreground, and so
  with no second foreground event to announce it - the border appears within
  about 60 ms, with no focus change of any kind.
- Idle CPU while there is no eligible target at all (the retry path) measures
  0 ms over 20 s.

Real applications tested live, each verified for both geometry and on-screen
pixels, over three consecutive full runs:

| Application | Window class | Result |
| --- | --- | --- |
| Windows Terminal | `CASCADIA_HOSTING_WINDOW_CLASS` | pass (on the negative-X monitor) |
| Visual Studio 2026 | `HwndWrapper[DefaultDomain;;...]` | pass |
| Brave (Chromium) | `Chrome_WidgetWin_1` | pass |
| Microsoft Teams (WebView2/Electron-style) | `TeamsWebView` | pass |
| PhpStorm (JetBrains, JVM) | `SunAwtFrame` | pass |
| Windows Explorer | `CabinetWClass` | pass |
| Plain Win32 window | `WindowsForms10.Window...` | pass |

### Re-running the automated checks

The harnesses used to produce the results above live in `tests\`. Each one
starts its own `ActiveBorder.exe` from `bin\Release\`, kills any stray
instance first, and cleans up after itself. Build first, then:

```
pwsh -NoProfile -File tests\01-geometry.ps1        # bounds, monitors, maximize
pwsh -NoProfile -File tests\02-focus-zorder-cpu.ps1 # switching, z-order, CPU
pwsh -NoProfile -File tests\03-pixels.ps1          # screen-captured colours
pwsh -NoProfile -File tests\04-real-apps.ps1       # Terminal, VS, Chromium, ...
pwsh -NoProfile -File tests\05-click-through.ps1   # hit-testing
pwsh -NoProfile -File tests\06-tray.ps1           # tray icon, menu, shutdown
pwsh -NoProfile -File tests\07-late-eligible.ps1  # attaching to a new window
```

They briefly create and focus their own windows, and `04-real-apps.ps1`
cycles focus through applications you already have open before restoring the
window that was focused when it started. Do not type during a run.

## Manual test checklist

1. Start `ActiveBorder.exe`. The focused window gains a red/white hazard
   stripe.
2. Launch an application that is not already running - Windows Terminal is
   the one that used to fail here - and confirm it gets a border straight
   away, without having to click another window and back.
3. Alt-Tab between Visual Studio and Windows Terminal. The border moves
   immediately, and there is never a border on both.
4. Click into Windows Explorer. The border moves to Explorer.
5. Drag a window by its title bar. The border tracks it while dragging.
6. Resize a window from a corner. The border tracks the resize.
7. Maximize, then restore. The border matches both states, and stays visible
   while maximized.
8. Snap a window with `Win+Left` / `Win+Right`. The border follows the snap.
9. Drag a window to a second monitor, including one positioned to the left of
   the primary (negative coordinates). The border follows.
10. On a mixed-DPI setup, move a window between a 100% and a 150% monitor. The
    border should stay 5 physical pixels on both.
11. Focus a Teams or Electron window, and confirm **all four** edges are
    drawn, not just the top one.
12. Minimize the focused window. The border leaves that window.
13. Click the desktop. The border disappears.
14. Open the Start menu. No border is drawn around it.
15. Click exactly on the border pixels of a window. The click reaches the
    application underneath.
16. Confirm `ActiveBorder` does not appear in Alt-Tab or on the taskbar.
17. Find the tray icon (check the `^` overflow flyout first, as noted in
    [README.md](README.md#finding-the-tray-icon)).
    Hovering shows "ActiveBorder - focus border".
18. Right-click the tray icon. A menu appears with "Exit ActiveBorder".
19. Press Escape, or click somewhere else on the desktop. The menu closes
    rather than staying stuck on screen.
20. Leave it running and check Task Manager: CPU should read 0%.
21. Right-click the tray icon and choose "Exit ActiveBorder". All borders
    vanish immediately, the tray icon disappears without needing a hover to
    clear a ghost, and the process is gone from Task Manager.
