#requires -Version 5.1
param([switch]$NoShow, [string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. "$PSScriptRoot/UiSupport.ps1"
[Windows.Forms.Application]::EnableVisualStyles()
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

$form = New-Object Windows.Forms.Form
$form.Text = 'Database Refresh Utility'; $form.Size = New-Object Drawing.Size(980,700)
$form.MinimumSize = New-Object Drawing.Size(800,560)
$form.StartPosition = 'CenterScreen'; $form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.BackColor = [Drawing.Color]::White

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(18)
$layout.ColumnCount=1; $layout.RowCount=8
foreach ($height in @(38,38,34,44,40)) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height))) }
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,34)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,38)))
$form.Controls.Add($layout)

$title=New-Object Windows.Forms.Label
$title.Text='Database Refresh Utility'; $title.Font=New-Object Drawing.Font('Segoe UI',18,[Drawing.FontStyle]::Bold)
$title.Dock='Fill'; $layout.Controls.Add($title,0,0)
$target=New-Object Windows.Forms.Label; $target.Dock='Fill'; $target.AutoEllipsis=$true
$target.Text='Configure config/database.json and config/credentials.json.'
try {
    $db=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $ProjectRoot 'config/database.json')))
    $target.Text="Target: $($db.tnsAlias)  |  DB: $($db.expectedTarget.dbUniqueName)  |  PDB: $($db.expectedTarget.conName)"
} catch { }
$layout.Controls.Add($target,0,1)
$label=New-Object Windows.Forms.Label; $label.Dock='Fill'; $label.Text='Snapshot for preflight, restore and validation:'
$label.TextAlign='MiddleLeft'; $layout.Controls.Add($label,0,2)

$picker=New-Object Windows.Forms.TableLayoutPanel; $picker.Dock='Fill'; $picker.ColumnCount=2
[void]$picker.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
[void]$picker.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,115)))
$snapshotBox=New-Object Windows.Forms.TextBox; $snapshotBox.Dock='Fill'; $snapshotBox.AccessibleName='Path to snapshot.json'
$browse=New-Object Windows.Forms.Button; $browse.Text='Browse...'; $browse.Dock='Fill'
$picker.Controls.Add($snapshotBox,0,0); $picker.Controls.Add($browse,1,0); $layout.Controls.Add($picker,0,3)

$buttons=New-Object Windows.Forms.TableLayoutPanel; $buttons.Dock='Fill'; $buttons.ColumnCount=4
$actionButtons=@{}
foreach ($definition in @(@('capture','1. Capture'),@('preflight','2. Preflight'),@('restore','3. Restore'),@('validate','4. Validate'))) {
    [void]$buttons.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,25)))
    $button=New-Object Windows.Forms.Button; $button.Text=$definition[1]; $button.Tag=$definition[0]; $button.Dock='Fill'
    $buttons.Controls.Add($button); $actionButtons[$definition[0]]=$button
}
$layout.Controls.Add($buttons,0,4)
$log=New-Object Windows.Forms.RichTextBox; $log.Dock='Fill'; $log.ReadOnly=$true
$log.Font=New-Object Drawing.Font('Consolas',10); $log.BackColor=[Drawing.Color]::FromArgb(245,247,249)
$log.WordWrap=$false; $log.DetectUrls=$false; $log.AccessibleName='Operation log'
$layout.Controls.Add($log,0,5)
$status=New-Object Windows.Forms.Label; $status.Dock='Fill'; $status.Text='Ready'; $status.TextAlign='MiddleLeft'
$layout.Controls.Add($status,0,6)
$footer=New-Object Windows.Forms.FlowLayoutPanel; $footer.Dock='Fill'; $footer.FlowDirection='LeftToRight'
$save=New-Object Windows.Forms.Button; $save.Text='Save log'; $save.AutoSize=$true
$clear=New-Object Windows.Forms.Button; $clear.Text='Clear log'; $clear.AutoSize=$true
$progress=New-Object Windows.Forms.ProgressBar; $progress.Width=200; $progress.Height=24; $progress.Style='Marquee'; $progress.Visible=$false
$footer.Controls.AddRange(@($save,$clear,$progress)); $layout.Controls.Add($footer,0,7)

$timer=New-Object Windows.Forms.Timer; $timer.Interval=200
$ui=@{Form=$form;Root=$ProjectRoot;Snapshot=$snapshotBox;Browse=$browse;Buttons=$actionButtons;Log=$log;Status=$status;Progress=$progress;Timer=$timer;Job=$null;Clear=$clear;Save=$save}

function Add-OrfUiLine($Ui, [string]$Text, [string]$Level='info') {
    $Ui.Log.SelectionStart=$Ui.Log.TextLength
    $Ui.Log.SelectionColor=switch ($Level) { 'error' {[Drawing.Color]::Firebrick} 'success' {[Drawing.Color]::DarkGreen} default {[Drawing.Color]::FromArgb(35,45,55)} }
    $Ui.Log.AppendText(('[' + [datetime]::Now.ToString('HH:mm:ss') + '] ' + $Text + [Environment]::NewLine))
    $Ui.Log.ScrollToCaret()
}
function Set-OrfUiBusy($Ui, [bool]$Busy) {
    foreach ($button in $Ui.Buttons.Values) { $button.Enabled=-not $Busy }
    $Ui.Browse.Enabled=-not $Busy; $Ui.Snapshot.Enabled=-not $Busy; $Ui.Clear.Enabled=-not $Busy
    $Ui.Progress.Visible=$Busy
}
function Start-OrfUiAction($Ui, [string]$Action) {
    if ($null -ne $Ui.Job) { return }
    try {
        $path=$Ui.Snapshot.Text.Trim()
        if ($Action -ne 'capture') {
            if (-not $path) { throw 'Select snapshot.json.' }
            if (-not [IO.Path]::IsPathRooted($path)) { $path=Join-Path $Ui.Root $path }
            $path=[IO.Path]::GetFullPath($path)
        }
        $Ui.Job=Start-OrfUiJob -ProjectRoot $Ui.Root -Action $Action -Snapshot $path
        Set-OrfUiBusy $Ui $true
        $Ui.Status.Text="Running: $Action"
        Add-OrfUiLine $Ui "Starting $Action."
        $Ui.Timer.Start()
    } catch { $Ui.Status.Text='Unable to start operation'; Add-OrfUiLine $Ui $_.Exception.Message 'error' }
}
function Update-OrfUi($Ui) {
    if ($null -eq $Ui.Job) { return }
    $update=Read-OrfUiJob $Ui.Job
    foreach ($message in $update.Messages) { Add-OrfUiLine $Ui $message.Text $message.Level }
    $elapsed=[datetime]::Now - $Ui.Job.Started
    $Ui.Status.Text="Running: $($Ui.Job.Action) — $($elapsed.ToString('hh\:mm\:ss'))"
    if ($update.Completed) {
        $action=$Ui.Job.Action; $Ui.Timer.Stop(); $Ui.Job=$null; Set-OrfUiBusy $Ui $false
        if ($update.Success) {
            $Ui.Status.Text="Completed: $action"; Add-OrfUiLine $Ui "Operation $action completed successfully." 'success'
            if ($action -eq 'capture' -and $update.CaptureDirectory) {
                $candidate=Join-Path $update.CaptureDirectory 'snapshot.json'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $Ui.Snapshot.Text=$candidate }
            }
        } else { $Ui.Status.Text="Error: $action — see log for details"; Add-OrfUiLine $Ui "Operation $action failed." 'error' }
    }
}

$browse.Add_Click({
    $dialog=New-Object Windows.Forms.OpenFileDialog
    $dialog.Title='Select snapshot'; $dialog.Filter='Snapshot (snapshot.json)|snapshot.json|JSON (*.json)|*.json'; $dialog.CheckFileExists=$true
    $initial=Join-Path $ui.Root 'snapshots'; if (Test-Path -LiteralPath $initial) { $dialog.InitialDirectory=$initial }
    try { if ($dialog.ShowDialog($ui.Form) -eq 'OK') { $ui.Snapshot.Text=$dialog.FileName } } finally { $dialog.Dispose() }
}.GetNewClosure())
foreach ($button in $actionButtons.Values) { $button.Add_Click({ param($sender,$eventArgs) Start-OrfUiAction $ui ([string]$sender.Tag) }.GetNewClosure()) }
$clear.Add_Click({ $ui.Log.Clear() }.GetNewClosure())
$save.Add_Click({
    $dialog=New-Object Windows.Forms.SaveFileDialog; $dialog.Title='Save log'; $dialog.Filter='Text (*.txt)|*.txt'; $dialog.FileName='database-refresh-utility-' + [datetime]::Now.ToString('yyyyMMdd-HHmmss') + '.txt'
    try { if ($dialog.ShowDialog($ui.Form) -eq 'OK') { [IO.File]::WriteAllText($dialog.FileName,$ui.Log.Text,(New-Object Text.UTF8Encoding($true))) } }
    catch { Add-OrfUiLine $ui $_.Exception.Message 'error' } finally { $dialog.Dispose() }
}.GetNewClosure())
$timer.Add_Tick({ Update-OrfUi $ui }.GetNewClosure())
$form.Add_FormClosing({ param($sender,$eventArgs)
    if ($null -ne $ui.Job) {
        $eventArgs.Cancel=$true
        Add-OrfUiLine $ui 'An operation is still running. You can close this window when it finishes.'
    }
}.GetNewClosure())
$form.Add_FormClosed({ $ui.Timer.Stop(); $ui.Timer.Dispose() }.GetNewClosure())
Add-OrfUiLine $ui 'Ready. Run Capture before the DBA refresh; run Preflight and Restore afterwards.'
if ($NoShow) { return $ui }
try { [void]$form.ShowDialog() } finally { $timer.Dispose(); $form.Dispose() }
