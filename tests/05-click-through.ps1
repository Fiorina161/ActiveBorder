$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;
public static class W7 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool at);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,IntPtr p);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int a,out RECT v,int s);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; public POINT(int x,int y){X=x;Y=y;} }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B;
    public override string ToString(){return L+","+T+" "+(R-L)+"x"+(B-T);} }
  public static string ClassOf(IntPtr h){var sb=new StringBuilder(256);GetClassNameW(h,sb,sb.Capacity);return sb.ToString();}
  public static IntPtr ByTitle(string t){IntPtr res=IntPtr.Zero;
    EnumWindows((h,l)=>{var sb=new StringBuilder(512);GetWindowTextW(h,sb,sb.Capacity);
      if(sb.ToString()==t&&IsWindowVisible(h)){res=h;return false;}return true;},IntPtr.Zero);return res;}
  public static void ForceForeground(IntPtr h){
    uint me=GetCurrentThreadId(); uint fg=GetWindowThreadProcessId(GetForegroundWindow(),IntPtr.Zero);
    if(fg!=0&&fg!=me)AttachThreadInput(me,fg,true);
    ShowWindow(h,9); BringWindowToTop(h); SetForegroundWindow(h);
    if(fg!=0&&fg!=me)AttachThreadInput(me,fg,false);}
  public static RECT Frame(IntPtr h){ RECT r; DwmGetWindowAttribute(h,9,out r,16); return r; }
  // GA_ROOT = 2
  public static IntPtr TopLevelAt(int x,int y){ return GetAncestor(WindowFromPoint(new POINT(x,y)), 2); }
}
'@
[void][W7]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$failures = 0
function Check($n,$c,$d){ if($c){Write-Host ("  PASS  "+$n) -ForegroundColor Green} else {Write-Host ("  FAIL  "+$n+"  "+$d) -ForegroundColor Red; $script:failures++} }

# Pin the appearance so this suite is deterministic even on a machine that
# has the AB_* overrides set in the environment.
foreach ($n in 'AB_COLOR_1', 'AB_COLOR2', 'AB_WIDTH')
{
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}

Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 400
$app = Start-Process (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe') -PassThru -WindowStyle Minimized
Start-Sleep -Milliseconds 1200
$h = Start-Process pwsh -PassThru -ArgumentList '-NoProfile','-File',"$PSScriptRoot\_testwin2.ps1",'-Title','FB-CLICK','-X','600','-Y','400'
Start-Sleep -Milliseconds 3000

$t = [W7]::ByTitle('FB-CLICK')
[W7]::ForceForeground($t)
Start-Sleep -Milliseconds 1200
$f = [W7]::Frame($t)
Write-Host ("target " + $t + " frame " + $f.ToString())

# Hit-test straight through the border pixels. WindowFromPoint honours
# WS_EX_TRANSPARENT / HTTRANSPARENT, so it must report the target, never a strip.
$probes = @(
    @{ N = 'top edge';    X = ($f.L + 200); Y = ($f.T + 1) },
    @{ N = 'left edge';   X = ($f.L + 1);   Y = ($f.T + 150) },
    @{ N = 'right edge';  X = ($f.R - 2);   Y = ($f.T + 150) },
    @{ N = 'bottom edge'; X = ($f.L + 200); Y = ($f.B - 2) }
)
foreach ($p in $probes) {
    $hit = [W7]::TopLevelAt($p.X, $p.Y)
    $cls = [W7]::ClassOf($hit)
    Write-Host ("  probe " + $p.N + " at " + $p.X + "," + $p.Y + " -> " + $cls)
    Check ("click passes through the " + $p.N) ($cls -ne 'ActiveBorderOverlay') ("hit " + $cls)
    Check ("click lands on the target at the " + $p.N) ($hit -eq $t) ("hit " + $cls)
}

[void][W7]::PostMessageW($t, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 500
try { $h.Kill() } catch {}
try { $app.Kill() } catch {}

Write-Host ""
if ($failures -eq 0) { Write-Host "ALL CLICK-THROUGH CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ("$failures CHECK(S) FAILED") -ForegroundColor Red
exit 1
