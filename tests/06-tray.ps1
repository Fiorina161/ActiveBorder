$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class T1
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint pid);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern ushort RegisterClassExW(ref WNDCLASSEXW c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr CreateWindowExW(int ex,
        [MarshalAs(UnmanagedType.LPWStr)] string cls, [MarshalAs(UnmanagedType.LPWStr)] string name,
        int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandleW(string n);

    public delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEXW {
        public uint CbSize; public uint Style; public IntPtr WndProc; public int ClsExtra; public int WndExtra;
        public IntPtr HInstance; public IntPtr HIcon; public IntPtr HCursor; public IntPtr HbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string MenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string ClassName; public IntPtr HIconSm; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int pos);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint item, StringBuilder s, int max, uint flags);

    public static string ClassOf(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

    public static List<IntPtr> OfProcess(uint pid)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => { if (PidOf(h) == pid) found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }

    public static List<IntPtr> ByClass(string cls)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => { if (ClassOf(h) == cls) found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }

    // A top-level window gets a taskbar button when it is visible, unowned,
    // and either carries WS_EX_APPWINDOW or lacks WS_EX_TOOLWINDOW.
    public static bool HasTaskbarButton(IntPtr h)
    {
        if (!IsWindowVisible(h)) return false;
        if (GetWindow(h, 4 /* GW_OWNER */) != IntPtr.Zero) return false;
        long ex = GetWindowLongPtrW(h, -20).ToInt64();
        if ((ex & 0x00040000) != 0) return true;    // WS_EX_APPWINDOW
        return (ex & 0x00000080) == 0;              // not WS_EX_TOOLWINDOW
    }

    // Windows' foreground lock means a synthetic PostMessage gives the app
    // none of the rights a real tray click would. Reproduce the grant: take
    // the foreground with a window of our own, then pass the right along,
    // exactly as the shell does for the owner of a notification icon.
    public static WndProc KeepAlive;

    public static IntPtr MakeHiddenToolWindow()
    {
        KeepAlive = (h, m, w, l) => DefWindowProcW(h, m, w, l);
        var c = new WNDCLASSEXW();
        c.CbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>();
        c.WndProc = Marshal.GetFunctionPointerForDelegate(KeepAlive);
        c.HInstance = GetModuleHandleW(null);
        c.ClassName = "TrayTestForegroundHelper";
        RegisterClassExW(ref c);
        return CreateWindowExW(0x80, "TrayTestForegroundHelper", "helper",
            unchecked((int)0x80000000), 0, 0, 0, 0,
            IntPtr.Zero, IntPtr.Zero, GetModuleHandleW(null), IntPtr.Zero);
    }

    public static bool GrantForegroundTo(uint pid)
    {
        IntPtr self = MakeHiddenToolWindow();
        if (self == IntPtr.Zero) return false;

        uint me = GetCurrentThreadId();
        uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        if (fgThread != 0 && fgThread != me) AttachThreadInput(me, fgThread, true);
        bool took = SetForegroundWindow(self);
        if (fgThread != 0 && fgThread != me) AttachThreadInput(me, fgThread, false);

        bool granted = AllowSetForegroundWindow(pid);
        DestroyWindow(self);
        return took && granted;
    }
}
'@

[void][T1]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$failures = 0
function Check($n, $c, $d) {
    if ($c) { Write-Host ("  PASS  " + $n) -ForegroundColor Green }
    else { Write-Host ("  FAIL  " + $n + "  " + $d) -ForegroundColor Red; $script:failures++ }
}

$exe = (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe')
# Pin the appearance so this suite is deterministic even on a machine that
# has the AB_* overrides set in the environment.
foreach ($n in 'AB_COLOR_1', 'AB_COLOR_2', 'AB_WIDTH')
{
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}

Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 500

Write-Host "Starting ActiveBorder..." -ForegroundColor Yellow
$app = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "== process and windows" -ForegroundColor Cyan
Check "process is still running" (-not $app.HasExited) ("exited with " + $(if ($app.HasExited) { $app.ExitCode } else { '' }))
if ($app.HasExited) { Write-Host "Cannot continue." -ForegroundColor Red; exit 2 }

$app.Refresh()
$windows = [T1]::OfProcess([uint32]$app.Id)
foreach ($w in $windows) {
    $ex = [T1]::GetWindowLongPtrW($w, -20).ToInt64()
    Write-Host ("   " + [T1]::ClassOf($w).PadRight(24) + " vis=" + ([T1]::IsWindowVisible($w)).ToString().PadRight(5) +
                " exstyle=0x" + $ex.ToString('X') + " taskbar=" + [T1]::HasTaskbarButton($w))
}

# A start-up failure surfaces as a MessageBox (class #32770).
$dialogs = @($windows | Where-Object { [T1]::ClassOf($_) -eq '#32770' })
Check "no start-up error dialog" ($dialogs.Count -eq 0) ("found " + $dialogs.Count)

$taskbarWindows = @($windows | Where-Object { [T1]::HasTaskbarButton($_) })
Check "no window claims a taskbar button" ($taskbarWindows.Count -eq 0) ("found " + $taskbarWindows.Count)
Check "no console window" (@($windows | Where-Object { [T1]::ClassOf($_) -eq 'ConsoleWindowClass' }).Count -eq 0) "console present"
# .NET picks MainWindowHandle as the first visible unowned window, which
# lands on an overlay strip. That is a .NET heuristic, not a taskbar fact -
# what matters is that whatever it resolves to is a tool window with no
# taskbar button.
$mainHwnd = $app.MainWindowHandle
if ($mainHwnd -ne [IntPtr]::Zero) {
    Write-Host ("   MainWindowHandle resolves to " + [T1]::ClassOf($mainHwnd))
    Check "MainWindowHandle is a tool window, not an app window" `
          (-not [T1]::HasTaskbarButton($mainHwnd)) ([T1]::ClassOf($mainHwnd))
}

$tray = @($windows | Where-Object { [T1]::ClassOf($_) -eq 'ActiveBorderTray' })
Check "tray owner window exists" ($tray.Count -eq 1) ("found " + $tray.Count)
if ($tray.Count -ne 1) { $app.Kill(); exit 2 }
$trayHwnd = $tray[0]

Write-Host ""
Write-Host "== right-click on the tray icon" -ForegroundColor Cyan
# Exactly what the shell sends for a right-click on the icon:
# WM_APP+1, wParam = icon id, lParam = WM_RBUTTONUP.
$before = @([T1]::ByClass('#32768')).Count
$granted = [T1]::GrantForegroundTo([uint32]$app.Id)
Write-Host ("   foreground right granted to the app: " + $granted)
Start-Sleep -Milliseconds 300
[void][T1]::PostMessageW($trayHwnd, 0x8001, [IntPtr]1, [IntPtr]0x0205)

$menu = [IntPtr]::Zero
for ($i = 0; $i -lt 40 -and $menu -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 100
    foreach ($m in [T1]::ByClass('#32768')) { if ([T1]::IsWindowVisible($m)) { $menu = $m; break } }
}
Check "a popup menu appeared" ($menu -ne [IntPtr]::Zero) ("before=$before")

if ($menu -ne [IntPtr]::Zero) {
    # If SetForegroundWindow had failed, the menu would not dismiss when the
    # user clicks away. Our process owning the foreground proves it worked.
    $fgPid = [T1]::PidOf([T1]::GetForegroundWindow())
    Check "our process owns the foreground while the menu is up" ($fgPid -eq [uint32]$app.Id) ("foreground pid $fgPid vs app " + $app.Id)

    # MN_GETHMENU hands back the HMENU so the items can be read from here.
    $hmenu = [T1]::SendMessageW($menu, 0x01E1, [IntPtr]0, [IntPtr]0)
    if ($hmenu -ne [IntPtr]::Zero) {
        $count = [T1]::GetMenuItemCount($hmenu)
        $sb = New-Object System.Text.StringBuilder 256
        [void][T1]::GetMenuStringW($hmenu, 0, $sb, $sb.Capacity, 0x0400)  # MF_BYPOSITION
        $text = $sb.ToString()
        $id = [T1]::GetMenuItemID($hmenu, 0)
        Write-Host ("   menu has $count item(s); first = '" + $text + "' id=" + $id)
        # Strip the & accelerator marker before matching ("E&xit ActiveBorder").
        $plain = $text -replace '&', ''
        Check "menu offers a terminate option" ($plain -match 'Exit') ("first item was '" + $text + "'")
        Check "terminate item carries the exit command id" ($id -eq 100) ("id was " + $id)
    } else {
        Write-Host "   (MN_GETHMENU returned null; menu contents not readable cross-process)" -ForegroundColor Yellow
    }

    # Dismiss with Escape, the same way a user clicking away would.
    [void][T1]::PostMessageW($menu, 0x0100, [IntPtr]0x1B, [IntPtr]0)   # WM_KEYDOWN VK_ESCAPE
    $gone = $false
    for ($i = 0; $i -lt 30 -and -not $gone; $i++) {
        Start-Sleep -Milliseconds 100
        $gone = -not [T1]::IsWindowVisible($menu)
    }
    Check "menu dismisses on Escape" $gone "menu still visible"
}

Write-Host ""
Write-Host "== choosing the terminate option" -ForegroundColor Cyan
# The exact WM_COMMAND the menu item posts when clicked.
[void][T1]::PostMessageW($trayHwnd, 0x0111, [IntPtr]100, [IntPtr]0)

$exited = $app.WaitForExit(8000)
Check "process exited after the terminate command" $exited "still running"
if ($exited) { Check "clean exit code" ($app.ExitCode -eq 0) ("exit code " + $app.ExitCode) }

Start-Sleep -Milliseconds 700
Check "no overlay windows left behind" (@([T1]::ByClass('ActiveBorderOverlay')).Count -eq 0) "strips remain"
Check "no tray window left behind"    (@([T1]::ByClass('ActiveBorderTray')).Count -eq 0) "tray window remains"
Check "no controller window left behind" (@([T1]::ByClass('ActiveBorderController')).Count -eq 0) "controller remains"
Check "no ActiveBorder process remains" (@(Get-Process ActiveBorder -ErrorAction SilentlyContinue).Count -eq 0) "process remains"

Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }

Write-Host ""
if ($failures -eq 0) { Write-Host "ALL TRAY CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ("$failures TRAY CHECK(S) FAILED") -ForegroundColor Red
exit 1
