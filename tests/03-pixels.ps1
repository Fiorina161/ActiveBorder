# Verifies the pixels that actually reach the screen: a solid 5 px border in
# the Windows accent colour on all four edges, an untouched interior, and no
# border left behind on a window that loses focus.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public static class W4 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
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
  public static IntPtr ByTitle(string t){IntPtr res=IntPtr.Zero;
    EnumWindows((h,l)=>{var sb=new StringBuilder(512);GetWindowTextW(h,sb,sb.Capacity);
      if(sb.ToString()==t&&IsWindowVisible(h)){res=h;return false;}return true;},IntPtr.Zero);return res;}
  public static void ForceForeground(IntPtr h){
    uint me=GetCurrentThreadId(); uint fg=GetWindowThreadProcessId(GetForegroundWindow(),IntPtr.Zero);
    if(fg!=0&&fg!=me)AttachThreadInput(me,fg,true);
    ShowWindow(h,9); BringWindowToTop(h); SetForegroundWindow(h);
    if(fg!=0&&fg!=me)AttachThreadInput(me,fg,false);}
  public static RECT Frame(IntPtr h){ RECT r; DwmGetWindowAttribute(h,9,out r,16); return r; }
}
'@
[void][W4]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$failures = 0
function Check($n, $c, $d) {
    if ($c) { Write-Host ("  PASS  " + $n) -ForegroundColor Green }
    else { Write-Host ("  FAIL  " + $n + "  " + $d) -ForegroundColor Red; $script:failures++ }
}

# The border is whatever the personalisation accent currently is, so the
# expected colour has to come from where the utility reads it:
# HKCU\...\Explorer\Accent\AccentColorMenu, stored as 0xAABBGGRR.
function Get-AccentRgb {
    $raw = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name AccentColorMenu).AccentColorMenu
    $b = [BitConverter]::GetBytes([uint32]($raw -band 0xFFFFFFFFL))
    return "" + $b[0] + "," + $b[1] + "," + $b[2]
}

$Accent = Get-AccentRgb
Write-Host ("accent colour (R,G,B): " + $Accent) -ForegroundColor Cyan

Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 400
$app = Start-Process (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe') -PassThru -WindowStyle Minimized
Start-Sleep -Milliseconds 1200
$h = Start-Process pwsh -PassThru -ArgumentList '-NoProfile','-File',"$PSScriptRoot\_testwin2.ps1",'-Title','FB-PIX','-X','500','-Y','350'
Start-Sleep -Milliseconds 3000

$t = [W4]::ByTitle('FB-PIX')
[W4]::ForceForeground($t)
Start-Sleep -Milliseconds 1200

$f = [W4]::Frame($t)
Write-Host ("frame: " + $f.ToString())

$w = $f.R - $f.L; $ht = $f.B - $f.T
$bmp = New-Object System.Drawing.Bitmap($w, $ht)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($f.L, $f.T, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
$g.Dispose()
$bmp.Save("$PSScriptRoot\capture.png", [System.Drawing.Imaging.ImageFormat]::Png)

function Px($x, $y) { $c = $bmp.GetPixel($x, $y); return ("" + $c.R + "," + $c.G + "," + $c.B) }

# $Thickness deliberately avoids the name $T: PowerShell variables are
# case-insensitive, and $t already holds the window handle.
$Thickness = 5
$span = 24

function CheckEdge($name, [int]$x0, [int]$y0, [int]$cols, [int]$rows) {
    $bad = 0
    $first = ''
    for ($dy = 0; $dy -lt $rows; $dy++) {
        for ($dx = 0; $dx -lt $cols; $dx++) {
            $x = $x0 + $dx
            $y = $y0 + $dy
            $got = Px $x $y
            if ($got -ne $Accent) {
                $bad++
                if (-not $first) { $first = "first mismatch at frame($x,$y): got $got want $Accent" }
            }
        }
    }
    Check "$name is solid accent ($cols x $rows px)" ($bad -eq 0) $first
}

$midX = [int]($w / 2)
$midY = [int]($ht / 2)

Write-Host "top edge, rows 0..$($Thickness-1) from x=$midX (A=accent .=other):"
for ($y = 0; $y -lt $Thickness; $y++) {
    $row = ''
    for ($x = $midX; $x -lt $midX + $span; $x++) {
        $row += $(if ((Px $x $y) -eq $Accent) { 'A' } else { '.' })
    }
    Write-Host ("   y=$y  $row")
}

CheckEdge "top edge"    $midX 0                  $span      $Thickness
CheckEdge "bottom edge" $midX ($ht - $Thickness) $span      $Thickness
CheckEdge "left edge"   0     $midY              $Thickness $span
CheckEdge "right edge"  ($w - $Thickness) $midY  $Thickness $span

# Thickness comes from the strip windows rather than from the pixel one past
# the border. With "show accent colour on title bars" switched on, that pixel
# is legitimately allowed to be the accent colour as well, so it cannot tell
# border from title bar - whereas a strip window is exactly as thick as the
# border it paints, and UpdateLayeredWindow cannot paint outside it.
$strips = [W4]::Strips()
Check "four strips are visible" ($strips.Count -eq 4) ("found " + $strips.Count)

$top = $strips | Where-Object { $_.L -eq $f.L -and $_.T -eq $f.T -and $_.R -eq $f.R }
$left = $strips | Where-Object { $_.L -eq $f.L -and $_.T -eq ($f.T + $Thickness) }
Check "top strip is exactly $Thickness px tall"  ($top -and ($top.B - $top.T) -eq $Thickness)    ("measured " + $(if ($top) { $top.B - $top.T } else { 'no strip' }))
Check "left strip is exactly $Thickness px wide" ($left -and ($left.R - $left.L) -eq $Thickness) ("measured " + $(if ($left) { $left.R - $left.L } else { 'no strip' }))

Check "interior is untouched" ((Px $midX $midY) -ne $Accent) (Px $midX $midY)

$bmp.Dispose()

# Now focus something else: the border must leave this window entirely.
Write-Host ""
Write-Host "Switching focus away..." -ForegroundColor Cyan
$h2 = Start-Process pwsh -PassThru -ArgumentList '-NoProfile','-File',"$PSScriptRoot\_testwin2.ps1",'-Title','FB-PIX2','-X','1500','-Y','350'
Start-Sleep -Milliseconds 3000
$t2 = [W4]::ByTitle('FB-PIX2')
[W4]::ForceForeground($t2)
Start-Sleep -Milliseconds 1200

$bmp2 = New-Object System.Drawing.Bitmap($w, $ht)
$g2 = [System.Drawing.Graphics]::FromImage($bmp2)
$g2.CopyFromScreen($f.L, $f.T, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
$g2.Dispose()
$bmp2.Save("$PSScriptRoot\capture-unfocused.png", [System.Drawing.Imaging.ImageFormat]::Png)
$bmp2.Dispose()

# The strips themselves are the witness here rather than a pixel: an
# unfocused window's own chrome may or may not be accent-tinted, so counting
# accent pixels along its top edge would be reading the title bar.
$stripsAfter = [W4]::Strips()
$stillOnOld = $stripsAfter | Where-Object { $_.L -eq $f.L -and $_.T -eq $f.T }
Check "old window has no border once unfocused" (-not $stillOnOld) "a strip is still sitting on its frame"

[void][W4]::PostMessageW($t,  0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
[void][W4]::PostMessageW($t2, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 600
foreach ($p in @($h, $h2, $app)) { try { $p.Kill() } catch {} }

Write-Host ""
if ($failures -eq 0) { Write-Host "ALL PIXEL CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ("$failures PIXEL CHECK(S) FAILED") -ForegroundColor Red
exit 1
