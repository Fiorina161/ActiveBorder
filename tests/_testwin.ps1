# Helper: a plain resizable Win32 (WinForms) window used as a focus target.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object System.Windows.Forms.Form
$f.Text = 'FOCUSBORDER-TEST-WINDOW'
$f.Size = New-Object System.Drawing.Size(600, 400)
$f.StartPosition = 'Manual'
$f.Location = New-Object System.Drawing.Point(300, 200)
$f.Add_Shown({ $f.Activate() })
[System.Windows.Forms.Application]::Run($f)
