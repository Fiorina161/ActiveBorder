$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;
public static class W4 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
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
# The border is a 45-degree red/white hazard pattern, anchored to screen
# coordinates so the diagonals run continuously around all four edges.
# $Thickness deliberately avoids the name $T: PowerShell variables are
# case-insensitive, and $t already holds the window handle.
$Thickness = 5
$Period    = 12
$Red       = '255,0,0'
$White     = '255,255,255'

function Expected([int]$sx, [int]$sy) {
    $band = ((($sx + $sy) % $Period) + $Period) % $Period
    if ($band -lt ($Period / 2)) { return $Red }
    return $White
}

$script:redSeen = 0
$script:whiteSeen = 0

function CheckEdge($name, [int]$x0, [int]$y0, [int]$cols, [int]$rows) {
    $bad = 0
    $first = ''
    for ($dy = 0; $dy -lt $rows; $dy++) {
        for ($dx = 0; $dx -lt $cols; $dx++) {
            $x = $x0 + $dx
            $y = $y0 + $dy
            $got = Px $x $y
            $want = Expected ($f.L + $x) ($f.T + $y)
            if ($got -eq $Red)   { $script:redSeen++ }
            if ($got -eq $White) { $script:whiteSeen++ }
            if ($got -ne $want) {
                $bad++
                if (-not $first) { $first = "first mismatch at frame($x,$y): got $got want $want" }
            }
        }
    }
    Check "$name matches the hazard pattern ($cols x $rows px)" ($bad -eq 0) $first
}

$midX = [int]($w / 2)
$midY = [int]($ht / 2)
$span = $Period * 2

Write-Host "top edge, rows 0..$($Thickness-1) from x=$midX (R=red W=white .=other):"
for ($y = 0; $y -lt $Thickness; $y++) {
    $row = ''
    for ($x = $midX; $x -lt $midX + $span; $x++) {
        $c = Px $x $y
        $row += $(if ($c -eq $Red) { 'R' } elseif ($c -eq $White) { 'W' } else { '.' })
    }
    Write-Host ("   y=$y  $row")
}

CheckEdge "top edge"    $midX 0                       $span      $Thickness
CheckEdge "bottom edge" $midX ($ht - $Thickness)      $span      $Thickness
CheckEdge "left edge"   0     $midY                   $Thickness $span
CheckEdge "right edge"  ($w - $Thickness) $midY       $Thickness $span

Check "both colours are actually present" (($script:redSeen -gt 0) -and ($script:whiteSeen -gt 0)) `
      ("red=$($script:redSeen) white=$($script:whiteSeen)")

# One pixel past the border must belong to the application, proving the
# border is exactly $Thickness px and not merely at least that.
function NotBorder($c) { return ($c -ne $Red) -and ($c -ne $White) }

Check "top row $Thickness is NOT border"          (NotBorder (Px $midX $Thickness))              (Px $midX $Thickness)
Check "left col $Thickness is NOT border"         (NotBorder (Px $Thickness $midY))              (Px $Thickness $midY)
Check "bottom row -$($Thickness+1) is NOT border" (NotBorder (Px $midX ($ht-1-$Thickness)))      (Px $midX ($ht-1-$Thickness))
Check "right col -$($Thickness+1) is NOT border"  (NotBorder (Px ($w-1-$Thickness) $midY))       (Px ($w-1-$Thickness) $midY)
Check "interior is untouched"                     (NotBorder (Px $midX $midY))                   (Px $midX $midY)

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
function Px2($x, $y) { $c = $bmp2.GetPixel($x, $y); return ("" + $c.R + "," + $c.G + "," + $c.B) }
# A single pixel cannot tell "border" from "application": the unfocused
# title bar is pure white, which is half the hazard pattern. Red is the
# discriminator - the pattern always carries red bands, a title bar does not.
$redAfter = 0
for ($y = 0; $y -lt $Thickness; $y++) {
    for ($x = $midX; $x -lt $midX + $span; $x++) {
        if ((Px2 $x $y) -eq $Red) { $redAfter++ }
    }
}
Check "old window has no border once unfocused" ($redAfter -eq 0) "$redAfter red pixels still on its top edge"
$bmp2.Dispose()

[void][W4]::PostMessageW($t,  0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
[void][W4]::PostMessageW($t2, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 600
foreach ($p in @($h, $h2, $app)) { try { $p.Kill() } catch {} }

Write-Host ""
if ($failures -eq 0) { Write-Host "ALL PIXEL CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ("$failures PIXEL CHECK(S) FAILED") -ForegroundColor Red
exit 1
