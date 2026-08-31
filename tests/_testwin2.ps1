param([string]$Title = 'FB-TEST', [int]$X = 300, [int]$Y = 200)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object System.Windows.Forms.Form
$f.Text = $Title
$f.Size = New-Object System.Drawing.Size(500, 350)
$f.StartPosition = 'Manual'
$f.Location = New-Object System.Drawing.Point($X, $Y)
[System.Windows.Forms.Application]::Run($f)
