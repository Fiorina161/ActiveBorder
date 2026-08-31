$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class W
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT v, int s);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B;
        public override string ToString() { return L + "," + T + " " + (R - L) + "x" + (B - T); } }

    public static List<IntPtr> ByClass(string cls)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => {
            var sb = new StringBuilder(256);
            GetClassNameW(h, sb, sb.Capacity);
            if (sb.ToString() == cls && IsWindowVisible(h)) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr ByTitle(string title)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(512);
            GetWindowTextW(h, sb, sb.Capacity);
            if (sb.ToString() == title && IsWindowVisible(h)) { result = h; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // Plain SetForegroundWindow is refused when we do not already own the
    // foreground, and this suite used to check focus only once at the start -
    // so anything that stole focus mid-run showed up as a pile of geometry
    // failures rather than as what it was.
    public static void ForceForeground(IntPtr h)
    {
        uint me = GetCurrentThreadId();
        uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        if (fgThread != 0 && fgThread != me) AttachThreadInput(me, fgThread, true);
        ShowWindow(h, 9);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (fgThread != 0 && fgThread != me) AttachThreadInput(me, fgThread, false);
    }

    public static string ClassOf(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static RECT Frame(IntPtr h)
    {
        RECT r;
        if (DwmGetWindowAttribute(h, 9, out r, 16) == 0 && r.R > r.L) return r;
        GetWindowRect(h, out r);
        return r;
    }
}
'@

[void][W]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$T = 5
$script:failures = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS  " + $name) -ForegroundColor Green }
    else { Write-Host ("  FAIL  " + $name + "  " + $detail) -ForegroundColor Red; $script:failures++ }
}

function Get-Strips {
    $h = [W]::ByClass('ActiveBorderOverlay')
    $rects = @()
    foreach ($x in $h) { $r = New-Object W+RECT; [void][W]::GetWindowRect($x, [ref]$r); $rects += $r }
    return , $rects
}

function Expected($f, $t) {
    return @(
        [pscustomobject]@{ N = 'top';    L = $f.L;      T = $f.T;      R = $f.R;      B = $f.T + $t }
        [pscustomobject]@{ N = 'bottom'; L = $f.L;      T = $f.B - $t; R = $f.R;      B = $f.B }
        [pscustomobject]@{ N = 'left';   L = $f.L;      T = $f.T + $t; R = $f.L + $t; B = $f.B - $t }
        [pscustomobject]@{ N = 'right';  L = $f.R - $t; T = $f.T + $t; R = $f.R;      B = $f.B - $t }
    )
}

function Verify-Border($label, $hwnd) {
    Write-Host ""
    Write-Host ("== " + $label) -ForegroundColor Cyan

    # Hold the foreground for every step, not just the first.
    if ([W]::GetForegroundWindow() -ne $hwnd) {
        [W]::ForceForeground($hwnd)
        Start-Sleep -Milliseconds 400
    }
    if ([W]::GetForegroundWindow() -ne $hwnd) {
        Write-Host ("  SKIP  focus was stolen by " + [W]::ClassOf([W]::GetForegroundWindow())) -ForegroundColor Yellow
        return
    }

    $frame = [W]::Frame($hwnd)
    $strips = Get-Strips
    Write-Host ("  target frame : " + $frame)
    Write-Host ("  strips found : " + $strips.Count + "  -> " + (($strips | ForEach-Object { $_.ToString() }) -join ' | '))

    Check "exactly 4 visible overlay strips" ($strips.Count -eq 4) ("got " + $strips.Count)
    if ($strips.Count -ne 4) { return }

    foreach ($e in (Expected $frame $T)) {
        $match = $strips | Where-Object { $_.L -eq $e.L -and $_.T -eq $e.T -and $_.R -eq $e.R -and $_.B -eq $e.B }
        Check ("strip " + $e.N + " at " + $e.L + "," + $e.T + " " + ($e.R - $e.L) + "x" + ($e.B - $e.T)) `
              ($null -ne $match) "no strip at that rect"
    }
}

# ----------------------------------------------------------------------
$exe = (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe')
Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 400
Write-Host "Starting ActiveBorder..." -ForegroundColor Yellow
$app = Start-Process -FilePath $exe -PassThru -WindowStyle Minimized
Start-Sleep -Milliseconds 1500

Write-Host "Starting test window..." -ForegroundColor Yellow
$helper = Start-Process pwsh -PassThru `
    -ArgumentList '-NoProfile', '-File', "$PSScriptRoot\_testwin.ps1"

$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 60 -and $hwnd -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 250
    $hwnd = [W]::ByTitle('FOCUSBORDER-TEST-WINDOW')
}

if ($hwnd -eq [IntPtr]::Zero) {
    Write-Host "Could not create the test window." -ForegroundColor Red
    $app.Kill(); exit 2
}

[W]::ForceForeground($hwnd)
Start-Sleep -Milliseconds 900

$fg = [W]::GetForegroundWindow()
Write-Host ("Foreground is test window: " + ($fg -eq $hwnd))
if ($fg -ne $hwnd) {
    Write-Host "Test window did not take foreground; results below are not meaningful." -ForegroundColor Yellow
}

Verify-Border "initial position (primary monitor)" $hwnd

# Move onto the monitor at negative X.
[void][W]::SetWindowPos($hwnd, [IntPtr]::Zero, -1500, 250, 700, 500, 0x0014)
Start-Sleep -Milliseconds 900
Verify-Border "moved + resized onto the left monitor (negative X)" $hwnd

# Resize only.
[void][W]::SetWindowPos($hwnd, [IntPtr]::Zero, -1500, 250, 400, 300, 0x0014)
Start-Sleep -Milliseconds 900
Verify-Border "resized in place at negative X" $hwnd

# Back to the primary monitor.
[void][W]::SetWindowPos($hwnd, [IntPtr]::Zero, 700, 300, 900, 600, 0x0014)
Start-Sleep -Milliseconds 900
Verify-Border "moved back to the primary monitor" $hwnd

# Maximize.
[void][W]::ShowWindow($hwnd, 3)
Start-Sleep -Milliseconds 900
Verify-Border "maximized" $hwnd

[void][W]::ShowWindow($hwnd, 9)   # restore
Start-Sleep -Milliseconds 900
Verify-Border "restored" $hwnd

# Minimize: the border must leave this window.
$frameBeforeMinimize = [W]::Frame($hwnd)
[void][W]::ShowWindow($hwnd, 6)
Start-Sleep -Milliseconds 900
Write-Host ""
Write-Host "== minimized" -ForegroundColor Cyan
$strips = Get-Strips
$fgAfter = [W]::GetForegroundWindow()
$fgEligible = ($fgAfter -ne [IntPtr]::Zero) -and ([W]::ClassOf($fgAfter) -notin @('Progman','WorkerW'))
Write-Host ("  after minimize the foreground is " + [W]::ClassOf($fgAfter))
if ($fgEligible) {
    # Minimizing hands focus to another application, which correctly gets the
    # border. What matters is that it is no longer on our window.
    $onOurWindow = $strips | Where-Object { $_.L -eq $frameBeforeMinimize.L -and $_.T -eq $frameBeforeMinimize.T }
    Check "border left the minimized window" ($null -eq $onOurWindow) "still on the minimized window"
} else {
    Check "no visible strips while target is minimized" ($strips.Count -eq 0) ("got " + $strips.Count)
}

Write-Host ""
Write-Host "Cleaning up..." -ForegroundColor Yellow
[void][W]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 500
try { $helper.Kill() } catch {}
try { $app.Kill() } catch {}

Write-Host ""
if ($script:failures -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ($script:failures.ToString() + " CHECK(S) FAILED") -ForegroundColor Red
exit 1
