$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public static class W5 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool at);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,IntPtr p);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h,uint c);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int a,out RECT v,int s);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B;
    public override string ToString(){return L+","+T+" "+(R-L)+"x"+(B-T);} }
  public static string ClassOf(IntPtr h){var sb=new StringBuilder(256);GetClassNameW(h,sb,sb.Capacity);return sb.ToString();}
  public static List<IntPtr> ByClass(string cls){var f=new List<IntPtr>();
    EnumWindows((h,l)=>{ if(ClassOf(h)==cls && IsWindowVisible(h)) f.Add(h); return true;},IntPtr.Zero); return f;}
  public static void ForceForeground(IntPtr h){
    uint me=GetCurrentThreadId(); uint fg=GetWindowThreadProcessId(GetForegroundWindow(),IntPtr.Zero);
    if(fg!=0&&fg!=me)AttachThreadInput(me,fg,true);
    ShowWindow(h,9); BringWindowToTop(h); SetForegroundWindow(h);
    if(fg!=0&&fg!=me)AttachThreadInput(me,fg,false);}
  public static RECT Frame(IntPtr h){ RECT r; if(DwmGetWindowAttribute(h,9,out r,16)==0 && r.R>r.L) return r; GetWindowRect(h,out r); return r; }
}
'@
[void][W5]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$T = 5
$failures = 0
function Check($n, $c, $d) {
    if ($c) { Write-Host ("    PASS  " + $n) -ForegroundColor Green }
    else { Write-Host ("    FAIL  " + $n + "  " + $d) -ForegroundColor Red; $script:failures++ }
}
function Strips {
    $r = @()
    foreach ($x in [W5]::ByClass('ActiveBorderOverlay')) {
        $q = New-Object W5+RECT; [void][W5]::GetWindowRect($x, [ref]$q); $r += $q
    }
    return , $r
}
function StripAt($s, [int]$l, [int]$t, [int]$r, [int]$b) {
    foreach ($x in $s) { if ($x.L -eq $l -and $x.T -eq $t -and $x.R -eq $r -and $x.B -eq $b) { return $true } }
    return $false
}

Get-Process ActiveBorder -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 400
$app = Start-Process (Join-Path $PSScriptRoot '..\bin\Release\net8.0-windows\ActiveBorder.exe') -PassThru -WindowStyle Minimized
Start-Sleep -Milliseconds 1500

if (([W5]::ByClass('CabinetWClass')).Count -eq 0) {
    Write-Host "Opening a File Explorer window for the test..." -ForegroundColor Yellow
    Start-Process explorer.exe 'C:\dev'
    Start-Sleep -Seconds 3
}
$original = [W5]::GetForegroundWindow()

$targets = @(
  @{ Name = 'Windows Terminal';      Proc = 'WindowsTerminal' },
  @{ Name = 'Visual Studio';         Proc = 'devenv' },
  @{ Name = 'Brave (Chromium)';      Proc = 'brave' },
  @{ Name = 'Teams (Electron)';      Proc = 'ms-teams' },
  @{ Name = 'PhpStorm (JetBrains)';  Proc = 'phpstorm64' },
  @{ Name = 'Settings (WinUI/UWP)';  Proc = 'SystemSettings' },
  @{ Name = 'Windows Explorer';      Proc = 'explorer'; Class = 'CabinetWClass' }
)

foreach ($tg in $targets) {
    Write-Host ""
    if ($tg.ContainsKey('Class')) {
        $hw = [W5]::ByClass($tg.Class) | Select-Object -First 1
        if ($null -eq $hw) { $hw = [IntPtr]::Zero }
    } else {
        $p = Get-Process -Name $tg.Proc -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        $hw = if ($null -eq $p) { [IntPtr]::Zero } else { $p.MainWindowHandle }
    }
    if ($hw -eq [IntPtr]::Zero) { Write-Host ("== " + $tg.Name + " : not running, skipped") -ForegroundColor DarkGray; continue }
    if ([W5]::IsIconic($hw)) { [void][W5]::ShowWindow($hw, 9); Start-Sleep -Milliseconds 500 }
    [W5]::ForceForeground($hw)
    Start-Sleep -Milliseconds 1600

    $cls = [W5]::ClassOf($hw)
    Write-Host ("== " + $tg.Name + "  [" + $cls + "]") -ForegroundColor Cyan

    if ([W5]::GetForegroundWindow() -ne $hw) {
        Write-Host "    (could not focus, skipped)" -ForegroundColor Yellow
        continue
    }

    $f = [W5]::Frame($hw)
    $s = Strips
    Write-Host ("    frame " + $f.ToString() + "   strips " + $s.Count)

    $ok = ($s.Count -eq 4) -and
          (StripAt $s $f.L $f.T $f.R ($f.T+$T)) -and
          (StripAt $s $f.L ($f.B-$T) $f.R $f.B) -and
          (StripAt $s $f.L ($f.T+$T) ($f.L+$T) ($f.B-$T)) -and
          (StripAt $s ($f.R-$T) ($f.T+$T) $f.R ($f.B-$T))
    Check "border hugs the DWM frame" $ok (($s | ForEach-Object { $_.ToString() }) -join ' | ')

    # Pixel-sample the top edge, away from the corners.
    $w = $f.R - $f.L; $ht = $f.B - $f.T
    if ($w -gt 40 -and $ht -gt 40) {
        # Sample two full periods so the alternation itself is verified, not
        # just that something red is present.
        $span = 24
        $x0 = $f.L + [int]($w/2) - [int]($span/2)
        $bmp = New-Object System.Drawing.Bitmap($span, $T)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($x0, $f.T, 0, 0, (New-Object System.Drawing.Size($span, $T)))
        $g.Dispose()

        $bad = 0; $red = 0; $white = 0; $row = ''
        for ($y = 0; $y -lt $T; $y++) {
            for ($dx = 0; $dx -lt $span; $dx++) {
                $c = $bmp.GetPixel($dx, $y)
                $isRed   = ($c.R -eq 255 -and $c.G -eq 0   -and $c.B -eq 0)
                $isWhite = ($c.R -eq 255 -and $c.G -eq 255 -and $c.B -eq 255)
                if ($isRed)   { $red++ }
                if ($isWhite) { $white++ }
                $band = ((($x0 + $dx + $f.T + $y) % 12) + 12) % 12
                $want = ($band -lt 6)
                if (($want -and -not $isRed) -or ((-not $want) -and -not $isWhite)) { $bad++ }
                if ($y -eq 0) { $row += $(if ($isRed) { 'R' } elseif ($isWhite) { 'W' } else { '.' }) }
            }
        }
        Write-Host ("    top edge y=0: " + $row + "   (red=$red white=$white mismatches=$bad)")
        Check "hazard pattern renders correctly over $span x $T px" `
              (($bad -eq 0) -and ($red -gt 0) -and ($white -gt 0)) "$bad mismatching pixels"
        $bmp.Dispose()
    }
}

Write-Host ""
Write-Host "Restoring original foreground window..." -ForegroundColor Yellow
if ($original -ne [IntPtr]::Zero) { [W5]::ForceForeground($original) }
Start-Sleep -Milliseconds 500
try { $app.Kill() } catch {}

Write-Host ""
if ($failures -eq 0) { Write-Host "ALL APPLICATION CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host ("$failures APPLICATION CHECK(S) FAILED") -ForegroundColor Red
exit 1
