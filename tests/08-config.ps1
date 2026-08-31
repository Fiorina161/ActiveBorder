# Verifies the AB_COLOR_1 / AB_COLOR_2 / AB_WIDTH environment overrides, and
# that anything missing, malformed or out of range falls back to the default.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public static class C8 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool at);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,IntPtr p);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int a,out RECT v,int s);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B;
    public override string ToString(){return L+","+T+" "+(R-L)+"x"+(B-T);} }
  public static string ClassOf(IntPtr h){var sb=new StringBuilder(256);GetClassNameW(h,sb,sb.Capacity);return sb.ToString();}
  public static List<RECT> Strips(){var l=new List<RECT>();
    EnumWindows((h,x)=>{ if(ClassOf(h)=="ActiveBorderOverlay" && IsWindowVisible(h)){RECT r;GetWindowRect(h,out r);l.Add(r);} return true;},IntPtr.Zero);
    return l;}
  public static IntPtr ByTitle(string t){IntPtr r=IntPtr.Zero;
    EnumWindows((h,l)=>{var sb=new StringBuilder(512);GetWindowTextW(h,sb,sb.Capacity);
      if(sb.ToString()==t&&IsWindowVisible(h)){r=h;return false;}return true;},IntPtr.Zero);return r;}
  public static void ForceForeground(IntPtr h){
    uint me=GetCurrentThreadId(); uint fg=GetWindowThreadProcessId(GetForegroundWindow(),IntPtr.Zero);
    if(fg!=0&&fg!=me)AttachThreadInput(me,fg,true);
    ShowWindow(h,9); BringWindowToTop(h); SetForegroundWindow(h);
    if(fg!=0&&fg!=me)AttachThreadInput(me,fg,false);}
  public static RECT Frame(IntPtr h){ RECT r; if(DwmGetWindowAttribute(h,9,out r,16)==0 && r.R>r.L) return r; GetWindowRect(h,out r); return r; }
}
'@

[void][C8]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$failures = 0
function Check($n, $c, $d) {
    if ($c) { Write-Host ("    PASS  " + $n) -ForegroundColor Green }
    else { Write-Host ("    FAIL  " + $n + "  " + $d) -ForegroundColor Red; $script:failures++ }
}

$exe = (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe')
$PERIOD = 12

function Set-Env($c1, $c2, $wd) {
    foreach ($n in 'AB_COLOR_1', 'AB_COLOR_2', 'AB_WIDTH') {
        Remove-Item "Env:$n" -ErrorAction SilentlyContinue
    }
    if ($null -ne $c1) { $env:AB_COLOR_1 = $c1 }
    if ($null -ne $c2) { $env:AB_COLOR_2 = $c2 }
    if ($null -ne $wd) { $env:AB_WIDTH = $wd }
}

# One scenario: launch with the current environment, measure what is drawn.
function Run-Case($label, $c1, $c2, $wd, $wantRgb1, $wantRgb2, $wantWidth) {
    Write-Host ""
    Write-Host ("== " + $label) -ForegroundColor Cyan
    Write-Host ("   AB_COLOR_1='$c1' AB_COLOR_2='$c2' AB_WIDTH='$wd'  ->  expect $wantRgb1 / $wantRgb2 at ${wantWidth}px")

    Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    Start-Sleep -Milliseconds 500
    Set-Env $c1 $c2 $wd

    $app = Start-Process $exe -PassThru
    Start-Sleep -Seconds 2

    $win = Start-Process pwsh -PassThru -ArgumentList '-NoProfile','-File',
        (Join-Path $PSScriptRoot '_testwin2.ps1'),'-Title','FB-CONFIG','-X','500','-Y','350'
    Start-Sleep -Seconds 3

    $t = [C8]::ByTitle('FB-CONFIG')
    if ($t -eq [IntPtr]::Zero) {
        Check "$label - test window created" $false "no window"
        try { $win.Kill() } catch {}; try { $app.Kill() } catch {}
        return
    }
    [C8]::ForceForeground($t)
    Start-Sleep -Milliseconds 1200

    $f = [C8]::Frame($t)
    $strips = [C8]::Strips()

    # Thickness is observable directly from the strip geometry.
    $top = $strips | Where-Object { $_.L -eq $f.L -and $_.T -eq $f.T -and $_.R -eq $f.R }
    $measured = if ($top) { $top.B - $top.T } else { -1 }
    Check "$label - border is ${wantWidth}px thick" ($measured -eq $wantWidth) "measured $measured"

    # And the two colours from the pixels themselves.
    $span = $PERIOD * 2
    $x0 = $f.L + 60
    $bmp = New-Object System.Drawing.Bitmap($span, $wantWidth)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x0, $f.T, 0, 0, (New-Object System.Drawing.Size($span, $wantWidth)))
    $g.Dispose()

    $bad = 0; $row = ''
    for ($y = 0; $y -lt $wantWidth; $y++) {
        for ($dx = 0; $dx -lt $span; $dx++) {
            $c = $bmp.GetPixel($dx, $y)
            $got = "{0:X2}{1:X2}{2:X2}" -f $c.R, $c.G, $c.B
            $band = ((($x0 + $dx + $f.T + $y) % $PERIOD) + $PERIOD) % $PERIOD
            $want = if ($band -lt ($PERIOD / 2)) { $wantRgb1 } else { $wantRgb2 }
            if ($got -ne $want) { $bad++ }
            if ($y -eq 0) { $row += $(if ($got -eq $wantRgb1) { '1' } elseif ($got -eq $wantRgb2) { '2' } else { '.' }) }
        }
    }
    Write-Host ("   top row: $row   (1=$wantRgb1 2=$wantRgb2 .=other)")
    Check "$label - colours are $wantRgb1 / $wantRgb2" ($bad -eq 0) "$bad mismatching pixels"
    $bmp.Dispose()

    [void][C8]::PostMessageW($t, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    try { $win.Kill() } catch {}
    try { $app.Kill() } catch {}
}

try {
    Run-Case "defaults (no variables set)"      $null      $null      $null  'FF0000' 'FFFFFF' 5
    Run-Case "all three overridden"             '00A0FF'   '202020'   '9'    '00A0FF' '202020' 9
    Run-Case "leading # tolerated"              '#00FF00'  '#000080'  '7'    '00FF00' '000080' 7
    Run-Case "malformed colours fall back"      'nothex'   'FFF'      '6'    'FF0000' 'FFFFFF' 6
    Run-Case "out-of-range width falls back"    '123456'   'ABCDEF'   '999'  '123456' 'ABCDEF' 5
    Run-Case "non-numeric width falls back"     '123456'   'ABCDEF'   'wide' '123456' 'ABCDEF' 5
}
finally {
    Set-Env $null $null $null
    Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
}

Write-Host ""
if ($failures -eq 0) { Write-Host "ALL CONFIG CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ("$failures CONFIG CHECK(S) FAILED") -ForegroundColor Red
exit 1
