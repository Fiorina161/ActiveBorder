# Verifies that the border is drawn in the Windows personalisation accent
# colour, that it is 5 physical pixels thick, and that changing the accent
# repaints a running instance without restarting it.
#
# The live-update case has to change the accent for real, so this suite writes
# HKCU\...\Explorer\Accent\AccentColorMenu and broadcasts the same
# WM_SETTINGCHANGE that the Settings app does. The original value is saved up
# front and put back in the finally block, including on Ctrl+C, and no other
# personalisation value is touched.
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
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,string l,uint f,uint t,out IntPtr r);
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
  // HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG - exactly what the
  // Settings app sends after it writes the new accent to the registry.
  public static void BroadcastColorChange(){ IntPtr r;
    SendMessageTimeoutW(new IntPtr(0xFFFF), 0x001A, IntPtr.Zero, "ImmersiveColorSet", 0x0002, 200, out r); }
}
'@

[void][C8]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$failures = 0
function Check($n, $c, $d) {
    if ($c) { Write-Host ("    PASS  " + $n) -ForegroundColor Green }
    else { Write-Host ("    FAIL  " + $n + "  " + $d) -ForegroundColor Red; $script:failures++ }
}

$ACCENT_PATH = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
$ACCENT_NAME = 'AccentColorMenu'
$THICKNESS = 5

# AccentColorMenu is a DWORD laid out 0xAABBGGRR, so the low byte is red.
# Deliberately untyped: depending on the value, the registry provider hands
# back either a signed Int32 or a widened Int64 for the same DWORD.
function Get-AccentRaw { return (Get-ItemProperty $ACCENT_PATH -Name $ACCENT_NAME).$ACCENT_NAME }

function RawToRgb($raw) {
    $b = [BitConverter]::GetBytes([uint32]($raw -band 0xFFFFFFFFL))
    return "{0:X2}{1:X2}{2:X2}" -f $b[0], $b[1], $b[2]
}

function RgbToRaw([string]$rgb) {
    $r = [Convert]::ToInt32($rgb.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($rgb.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($rgb.Substring(4, 2), 16)
    return [BitConverter]::ToUInt32([byte[]]@($r, $g, $b, 0xFF), 0)
}

function Set-Accent([string]$rgb) {
    Set-ItemProperty $ACCENT_PATH -Name $ACCENT_NAME -Value (RgbToRaw $rgb) -Type DWord
    [C8]::BroadcastColorChange()
}

# Sample the middle of the top edge, one row inside it, as RRGGBB.
function Sample($frame) {
    $x = $frame.L + [int](($frame.R - $frame.L) / 2)
    $bmp = New-Object System.Drawing.Bitmap(1, 1)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $frame.T + 2, 0, 0, (New-Object System.Drawing.Size(1, 1)))
    $g.Dispose()
    $c = $bmp.GetPixel(0, 0)
    $bmp.Dispose()
    return "{0:X2}{1:X2}{2:X2}" -f $c.R, $c.G, $c.B
}

$exe = (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe')
$original = Get-AccentRaw
$originalRgb = RawToRgb $original

# Any colour the current accent is not; the border has to visibly move to it.
$alternateRgb = if ($originalRgb -eq '00A0FF') { 'FF00FF' } else { '00A0FF' }

Write-Host ("current accent: #" + $originalRgb + "   test accent: #" + $alternateRgb) -ForegroundColor Cyan

$app = $null
$win = $null
$target = [IntPtr]::Zero

try {
    Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    Start-Sleep -Milliseconds 500

    $app = Start-Process $exe -PassThru
    Start-Sleep -Seconds 2

    $win = Start-Process pwsh -PassThru -ArgumentList '-NoProfile','-File',
        (Join-Path $PSScriptRoot '_testwin2.ps1'),'-Title','FB-ACCENT','-X','500','-Y','350'
    Start-Sleep -Seconds 3

    $target = [C8]::ByTitle('FB-ACCENT')
    if ($target -eq [IntPtr]::Zero) { throw "the test window never appeared" }

    [C8]::ForceForeground($target)
    Start-Sleep -Milliseconds 1200

    $frame = [C8]::Frame($target)
    Write-Host ""
    Write-Host "== thickness" -ForegroundColor Cyan

    $strips = [C8]::Strips()
    $top = $strips | Where-Object { $_.L -eq $frame.L -and $_.T -eq $frame.T -and $_.R -eq $frame.R }
    $left = $strips | Where-Object { $_.L -eq $frame.L -and $_.T -eq ($frame.T + $THICKNESS) }

    Check "four strips are visible" ($strips.Count -eq 4) ("found " + $strips.Count)
    Check "top strip is $THICKNESS px tall"  ($top -and ($top.B - $top.T) -eq $THICKNESS)    ("measured " + $(if ($top) { $top.B - $top.T } else { 'no strip' }))
    Check "left strip is $THICKNESS px wide" ($left -and ($left.R - $left.L) -eq $THICKNESS) ("measured " + $(if ($left) { $left.R - $left.L } else { 'no strip' }))

    Write-Host ""
    Write-Host "== colour at start-up" -ForegroundColor Cyan
    $seen = Sample $frame
    Check "border is the accent colour #$originalRgb" ($seen -eq $originalRgb) "measured #$seen"

    Write-Host ""
    Write-Host "== live update to #$alternateRgb (no restart)" -ForegroundColor Cyan
    Set-Accent $alternateRgb
    Start-Sleep -Seconds 3
    $seen = Sample $frame
    Check "running instance repainted to #$alternateRgb" ($seen -eq $alternateRgb) "measured #$seen"

    $stillFour = ([C8]::Strips()).Count
    Check "still exactly four strips after the change" ($stillFour -eq 4) "found $stillFour"

    Write-Host ""
    Write-Host "== live update back to #$originalRgb" -ForegroundColor Cyan
    Set-Accent $originalRgb
    Start-Sleep -Seconds 3
    $seen = Sample $frame
    Check "running instance repainted to #$originalRgb" ($seen -eq $originalRgb) "measured #$seen"
}
finally {
    # Put the accent back exactly as it was, whatever happened above, and tell
    # everything else on the desktop to re-read it.
    Set-ItemProperty $ACCENT_PATH -Name $ACCENT_NAME -Value $original -Type DWord
    [C8]::BroadcastColorChange()

    if ($target -ne [IntPtr]::Zero) {
        [void][C8]::PostMessageW($target, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 400
    }
    if ($win) { try { $win.Kill() } catch {} }
    if ($app) { try { $app.Kill() } catch {} }
    Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
}

Write-Host ""
if ($failures -eq 0) { Write-Host "ALL ACCENT CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ("$failures ACCENT CHECK(S) FAILED") -ForegroundColor Red
exit 1
