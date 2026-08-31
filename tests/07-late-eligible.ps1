# Regression test for: a window that becomes the foreground window while it
# is still ineligible (hidden / cloaked / unsized, as happens for a window
# being created) and only becomes eligible afterwards, with no further
# foreground change to announce it.
#
# This is what made a freshly launched application get no border until the
# user clicked another window and back.
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public static class L1 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public delegate IntPtr WndProcD(IntPtr h, uint m, IntPtr w, IntPtr l);

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct WNDCLASSEXW {
    public uint CbSize; public uint Style; public IntPtr WndProc; public int ClsExtra; public int WndExtra;
    public IntPtr HInstance; public IntPtr HIcon; public IntPtr HCursor; public IntPtr HbrBackground;
    [MarshalAs(UnmanagedType.LPWStr)] public string MenuName;
    [MarshalAs(UnmanagedType.LPWStr)] public string ClassName; public IntPtr HIconSm; }

  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MSG {
    public IntPtr Hwnd; public uint Message; public IntPtr WParam; public IntPtr LParam;
    public uint Time; public POINT Pt; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B;
    public override string ToString(){return L+","+T+" "+(R-L)+"x"+(B-T);} }

  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool at);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern ushort RegisterClassExW(ref WNDCLASSEXW c);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowExW(int ex,
    [MarshalAs(UnmanagedType.LPWStr)] string cls,[MarshalAs(UnmanagedType.LPWStr)] string name,
    int style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr inst,IntPtr p);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr DefWindowProcW(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool PeekMessageW(out MSG m,IntPtr h,uint a,uint b,uint r);
  [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr DispatchMessageW(ref MSG m);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr GetModuleHandleW(string n);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int a,out RECT v,int s);

  public static WndProcD Keep;
  public static string ClassOf(IntPtr h){var sb=new StringBuilder(256);GetClassNameW(h,sb,sb.Capacity);return sb.ToString();}

  public static List<RECT> Strips() {
    var list = new List<RECT>();
    EnumWindows((h,l)=>{ if(ClassOf(h)=="ActiveBorderOverlay" && IsWindowVisible(h)) {
      RECT r; GetWindowRect(h, out r); list.Add(r); } return true; }, IntPtr.Zero);
    return list;
  }

  public static RECT Frame(IntPtr h){ RECT r; if(DwmGetWindowAttribute(h,9,out r,16)==0 && r.R>r.L) return r; GetWindowRect(h,out r); return r; }

  // Created WITHOUT WS_VISIBLE: a plain popup that exists but is not yet on
  // screen, exactly like a window mid-creation.
  public static IntPtr CreateHidden(int x,int y,int w,int h)
  {
    Keep = (a,m,b,c) => DefWindowProcW(a,m,b,c);
    var cls = new WNDCLASSEXW();
    cls.CbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>();
    cls.WndProc = Marshal.GetFunctionPointerForDelegate(Keep);
    cls.HInstance = GetModuleHandleW(null);
    cls.ClassName = "LateEligibleTestWindow";
    RegisterClassExW(ref cls);
    return CreateWindowExW(0, "LateEligibleTestWindow", "late-eligible",
        unchecked((int)0x80000000), x, y, w, h,
        IntPtr.Zero, IntPtr.Zero, GetModuleHandleW(null), IntPtr.Zero);
  }

  public static bool ForceForeground(IntPtr h)
  {
    uint me = GetCurrentThreadId();
    uint fgt = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    if (fgt != 0 && fgt != me) AttachThreadInput(me, fgt, true);
    BringWindowToTop(h);
    bool ok = SetForegroundWindow(h);
    if (fgt != 0 && fgt != me) AttachThreadInput(me, fgt, false);
    return ok;
  }

  public static void Pump()
  {
    MSG m;
    while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
  }
}
'@

[void][L1]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$failures = 0
function Check($n, $c, $d) {
    if ($c) { Write-Host ("  PASS  " + $n) -ForegroundColor Green }
    else { Write-Host ("  FAIL  " + $n + "  " + $d) -ForegroundColor Red; $script:failures++ }
}

$T = 5
$exe = (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe')
# Pin the appearance so this suite is deterministic even on a machine that
# has the AB_* overrides set in the environment.
foreach ($n in 'AB_COLOR_1', 'AB_COLOR2', 'AB_WIDTH')
{
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}

Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 500
$app = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 2

# 1. A window that exists but is not yet on screen takes the foreground.
$hwnd = [L1]::CreateHidden(400, 300, 600, 420)
Check "test window created" ($hwnd -ne [IntPtr]::Zero) "CreateWindowEx failed"
if ($hwnd -eq [IntPtr]::Zero) { $app.Kill(); exit 2 }

$took = [L1]::ForceForeground($hwnd)
[L1]::Pump()
Start-Sleep -Milliseconds 800
[L1]::Pump()

Write-Host ""
Write-Host "== foreground taken while still hidden" -ForegroundColor Cyan
Write-Host ("   foreground is the test window: " + ([L1]::GetForegroundWindow() -eq $hwnd) + "  visible=" + [L1]::IsWindowVisible($hwnd))
Check "the hidden window did take the foreground" ([L1]::GetForegroundWindow() -eq $hwnd) "could not take foreground"
Check "no border while the window is not on screen" (@([L1]::Strips()).Count -eq 0) ("strips = " + @([L1]::Strips()).Count)

# 2. Become eligible WITHOUT another foreground change: SW_SHOWNA shows the
#    window without activating it, so no EVENT_SYSTEM_FOREGROUND is emitted.
Write-Host ""
Write-Host "== now shown, with no new foreground event" -ForegroundColor Cyan
[void][L1]::ShowWindow($hwnd, 8)   # SW_SHOWNA
[L1]::Pump()

$sw = [Diagnostics.Stopwatch]::StartNew()
$strips = @()
while ($sw.ElapsedMilliseconds -lt 4000) {
    [L1]::Pump()
    Start-Sleep -Milliseconds 50
    $strips = @([L1]::Strips())
    if ($strips.Count -eq 4) { break }
}
$elapsed = $sw.ElapsedMilliseconds

Write-Host ("   still foreground: " + ([L1]::GetForegroundWindow() -eq $hwnd) + "  visible=" + [L1]::IsWindowVisible($hwnd))
Write-Host ("   border appeared after " + $elapsed + " ms; strips = " + $strips.Count)

Check "foreground never changed (so only the retry path could recover)" `
      ([L1]::GetForegroundWindow() -eq $hwnd) "foreground moved elsewhere"
Check "border appears without any focus change" ($strips.Count -eq 4) ("strips = " + $strips.Count)
Check "border appears promptly (under 1s)" ($strips.Count -eq 4 -and $elapsed -lt 1000) ($elapsed.ToString() + " ms")

if ($strips.Count -eq 4) {
    $f = [L1]::Frame($hwnd)
    $ok = $false
    foreach ($s in $strips) {
        if ($s.L -eq $f.L -and $s.T -eq $f.T -and $s.R -eq $f.R -and $s.B -eq ($f.T + $T)) { $ok = $true }
    }
    Write-Host ("   frame " + $f.ToString() + "  top strip present: " + $ok)
    Check "border is positioned on the newly shown window" $ok "no top strip on the frame"
}

[void][L1]::DestroyWindow($hwnd)
[L1]::Pump()
Start-Sleep -Milliseconds 400
try { $app.Kill() } catch {}

Write-Host ""
if ($failures -eq 0) { Write-Host "ALL LATE-ELIGIBLE CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ("$failures CHECK(S) FAILED") -ForegroundColor Red
exit 1
