$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class W2
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
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

    public static string ClassOf(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    // Windows refuses SetForegroundWindow from a process that does not own
    // the foreground. Attaching to the foreground thread lifts that block,
    // which is exactly what a test harness needs.
    public static void ForceForeground(IntPtr h)
    {
        uint me = GetCurrentThreadId();
        uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        if (fg != 0 && fg != me) AttachThreadInput(me, fg, true);
        ShowWindow(h, 9);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (fg != 0 && fg != me) AttachThreadInput(me, fg, false);
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

[void][W2]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$T = 5
$script:failures = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS  " + $name) -ForegroundColor Green }
    else { Write-Host ("  FAIL  " + $name + "  " + $detail) -ForegroundColor Red; $script:failures++ }
}

function Strip-Rects {
    $rects = @()
    foreach ($x in [W2]::ByClass('ActiveBorderOverlay')) {
        $r = New-Object W2+RECT; [void][W2]::GetWindowRect($x, [ref]$r); $rects += $r
    }
    return , $rects
}

function StripAt($strips, [int]$l, [int]$tp, [int]$r, [int]$b) {
    foreach ($s in $strips) {
        if ($s.L -eq $l -and $s.T -eq $tp -and $s.R -eq $r -and $s.B -eq $b) { return $true }
    }
    return $false
}

function HugsInts($strips, [int]$fl, [int]$ft, [int]$fr, [int]$fb, [int]$t) {
    if ($strips.Count -ne 4) { return $false }
    if (-not (StripAt $strips $fl $ft $fr ($ft + $t))) { return $false }          # top
    if (-not (StripAt $strips $fl ($fb - $t) $fr $fb)) { return $false }          # bottom
    if (-not (StripAt $strips $fl ($ft + $t) ($fl + $t) ($fb - $t))) { return $false }  # left
    if (-not (StripAt $strips ($fr - $t) ($ft + $t) $fr ($fb - $t))) { return $false }  # right
    return $true
}

$exe = (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe')
# A previous aborted run can leave an instance behind, and two instances
# draw two identical borders. Start from a clean slate.
Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 400

Write-Host "Starting ActiveBorder..." -ForegroundColor Yellow
$app = Start-Process -FilePath $exe -PassThru -WindowStyle Minimized
Start-Sleep -Milliseconds 1500

Write-Host "Starting two test windows..." -ForegroundColor Yellow
$h1 = Start-Process pwsh -PassThru -ArgumentList '-NoProfile','-File',"$PSScriptRoot\_testwin2.ps1",'-Title','FB-ALPHA','-X','200','-Y','150'
Start-Sleep -Milliseconds 2500
$h2 = Start-Process pwsh -PassThru -ArgumentList '-NoProfile','-File',"$PSScriptRoot\_testwin2.ps1",'-Title','FB-BETA','-X','1200','-Y','500'
Start-Sleep -Milliseconds 2500

$a = [W2]::ByTitle('FB-ALPHA')
$b = [W2]::ByTitle('FB-BETA')
Write-Host ("  alpha=" + $a + "  beta=" + $b)
if ($a -eq [IntPtr]::Zero -or $b -eq [IntPtr]::Zero) {
    Write-Host "Could not create both test windows." -ForegroundColor Red
    $app.Kill(); exit 2
}

Write-Host ""
Write-Host "== focus switching (10 alternations)" -ForegroundColor Cyan
$switchOk = 0; $switchTotal = 0; $stripCountBad = 0
for ($i = 0; $i -lt 10; $i++) {
    $target = if ($i % 2 -eq 0) { $a } else { $b }
    $name = if ($i % 2 -eq 0) { 'ALPHA' } else { 'BETA' }
    [W2]::ForceForeground($target)
    Start-Sleep -Milliseconds 450

    if ([W2]::GetForegroundWindow() -ne $target) { Write-Host ("  (skip $name - not foreground)"); continue }
    $switchTotal++
    $strips = Strip-Rects
    if ($strips.Count -ne 4) { $stripCountBad++ }
    $frame = [W2]::Frame($target)
    if (HugsInts $strips $frame.L $frame.T $frame.R $frame.B $T) {
        $switchOk++
        Write-Host ("  " + $name + " ok, frame " + $frame.ToString())
    } else {
        Write-Host ("  mismatch on " + $name + ": frame " + $frame.ToString() + " strips " + (($strips | ForEach-Object { $_.ToString() }) -join ' | '))
    }
}
Check "border followed every focus switch" ($switchOk -eq $switchTotal -and $switchTotal -ge 8) ("$switchOk/$switchTotal")
Check "never more or fewer than 4 strips" ($stripCountBad -eq 0) ("$stripCountBad bad samples")

Write-Host ""
Write-Host "== z-order: strips sit directly above the focused window" -ForegroundColor Cyan
[W2]::ForceForeground($a)
Start-Sleep -Milliseconds 700
# Walk upward past the invisible bookkeeping windows (IME hosts and the
# like) that legitimately live in the z-order between real windows.
$af = [W2]::Frame($a)
$walk = $a; $chain = @(); $foundStrip = $false
for ($i = 0; $i -lt 16; $i++) {
    $walk = [W2]::GetWindow($walk, 3)   # GW_HWNDPREV
    if ($walk -eq [IntPtr]::Zero) { break }
    $cls = [W2]::ClassOf($walk)
    $r = New-Object W2+RECT; [void][W2]::GetWindowRect($walk, [ref]$r)
    $vis = [W2]::IsWindowVisible($walk)
    $chain += ("$cls[" + $(if ($vis) {'v'} else {'h'}) + " " + $r.ToString() + "]")
    if ($cls -eq 'ActiveBorderOverlay') { $foundStrip = $true; break }
    # Only a visible window that actually overlaps the target counts as an
    # obstruction; the topmost taskbar and 0x0 helpers do not.
    $overlaps = $vis -and $r.R -gt $r.L -and $r.B -gt $r.T -and
                $r.L -lt $af.R -and $r.R -gt $af.L -and $r.T -lt $af.B -and $r.B -gt $af.T
    if ($overlaps) { break }
}
Write-Host ("  z-order above target: " + ($chain -join ' -> '))
Check "an overlay strip is above the target, nothing real in between" $foundStrip "see chain above" 

Write-Host ""
Write-Host "== overlay never becomes foreground" -ForegroundColor Cyan
$fgBad = 0
for ($i = 0; $i -lt 12; $i++) {
    if ([W2]::ClassOf([W2]::GetForegroundWindow()) -eq 'ActiveBorderOverlay') { $fgBad++ }
    Start-Sleep -Milliseconds 200
}
Check "overlay was never the foreground window" ($fgBad -eq 0) ("$fgBad samples")

Write-Host ""
Write-Host "== idle CPU over 20s" -ForegroundColor Cyan
$p = Get-Process -Id $app.Id
$p.Refresh()
$t0 = $p.TotalProcessorTime
$w0 = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds 20
$p.Refresh()
$cpuMs = ($p.TotalProcessorTime - $t0).TotalMilliseconds
$pct = 100.0 * $cpuMs / $w0.Elapsed.TotalMilliseconds
$ws = [math]::Round($p.WorkingSet64 / 1MB, 1)
$priv = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
Write-Host ("  cpu " + [math]::Round($cpuMs, 1) + " ms over 20s = " + [math]::Round($pct, 3) + "% of one core")
Write-Host ("  working set " + $ws + " MB, private " + $priv + " MB, handles " + $p.HandleCount)
Check "idle CPU under 0.5% of one core" ($pct -lt 0.5) ([math]::Round($pct,3).ToString() + "%")
Check "working set under 40 MB" ($ws -lt 40) ("$ws MB")

Write-Host ""
Write-Host "Cleaning up..." -ForegroundColor Yellow
[void][W2]::PostMessageW($a, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
[void][W2]::PostMessageW($b, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 700
foreach ($x in @($h1, $h2, $app)) { try { $x.Kill() } catch {} }

Write-Host ""
if ($script:failures -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ($script:failures.ToString() + " CHECK(S) FAILED") -ForegroundColor Red
exit 1
