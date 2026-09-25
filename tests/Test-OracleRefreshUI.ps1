#requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../scripts/UiSupport.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('orf-ui-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))
$passed=0; $ui=$null; $running=$null
function Assert-Ui($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Wait-UiJob($Job) {
    $lines=@(); $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        $update=Read-OrfUiJob $Job; $lines+=@($update.Messages)
        if ($watch.Elapsed.TotalSeconds -gt 10) { throw 'UI worker did not finish' }
        if (-not $update.Completed) { Start-Sleep -Milliseconds 20 }
    } until ($update.Completed)
    return @{Update=$update;Messages=$lines}
}
try {
    $fake=@'
function Invoke-OrfAction($Action,$Snapshot,$ProjectRoot) {
    Write-Host 'WORK STARTED'
    Start-Sleep -Milliseconds 250
    if ($Action -ne 'capture' -and -not (Test-Path -LiteralPath $Snapshot -PathType Leaf)) { throw 'Snapshot not found' }
    if ($Action -eq 'restore') { throw 'SIMULATED RESTORE FAILURE' }
    if ($Action -eq 'validate') { Write-Error 'SIMULATED VALIDATION FAILURE'; return }
    if ($Action -eq 'capture') {
        $directory=Join-Path $ProjectRoot 'snapshots/test'
        [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory 'snapshot.json'),'{}')
        Write-Host "CAPTURE SUCCESS: $directory"
    } else { Write-Host 'PREFLIGHT SUCCESS' }
}
'@
    [IO.File]::WriteAllText((Join-Path $root 'scripts/OracleRefresh.ps1'),$fake)
    $running=Start-OrfUiJob $root 'capture' ''
    Assert-Ui (-not $running.Handle.IsCompleted) 'Worker did not run asynchronously'
    $result=Wait-UiJob $running; $running=$null
    Assert-Ui $result.Update.Success 'Capture worker failed'
    Assert-Ui (@($result.Messages | Where-Object { $_.Text -eq 'WORK STARTED' }).Count -eq 1) 'Progress line lost'
    $snapshot=Join-Path $result.Update.CaptureDirectory 'snapshot.json'
    Assert-Ui (Test-Path -LiteralPath $snapshot) 'Capture path not returned'; $passed++
    foreach ($action in @('restore','validate')) {
        $running=Start-OrfUiJob $root $action $snapshot
        $result=Wait-UiJob $running; $running=$null
        Assert-Ui (-not $result.Update.Success) "$action error reported as success"
        Assert-Ui (@($result.Messages | Where-Object { $_.Level -eq 'error' }).Count -gt 0) 'Error stream missing'; $passed++
    }
    $running=Start-OrfUiJob $root 'preflight' (Join-Path $root 'missing.json')
    $result=Wait-UiJob $running; $running=$null
    Assert-Ui (-not $result.Update.Success) 'Missing snapshot was accepted'; $passed++
    # Create real Windows Forms controls without showing a window or touching Oracle.
    $ui=. "$PSScriptRoot/../scripts/Start-OracleRefreshUI.ps1" -NoShow -ProjectRoot $root
    Assert-Ui ($ui.Buttons.Count -eq 4) 'Expected four operation buttons'
    $ui.Form.CreateControl(); $ui.Form.PerformLayout()
    $clickMethod=$ui.Buttons.capture.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$clickMethod.Invoke($ui.Buttons.capture,@([EventArgs]::Empty))
    Assert-Ui (-not $ui.Buttons.restore.Enabled) 'Concurrent restore button not disabled'
    $closing=New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::UserClosing,$false)
    $closeArguments=New-Object object[] 1; $closeArguments[0]=$closing.PSObject.BaseObject
    [void]$ui.Form.GetType().GetMethod('OnFormClosing',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($ui.Form,$closeArguments)
    Assert-Ui $closing.Cancel 'Closing was allowed while a job was running'
    $original=$ui.Job; Start-OrfUiAction $ui 'restore'
    Assert-Ui ([object]::ReferenceEquals($original,$ui.Job)) 'Concurrent job started'
    $deadline=[datetime]::Now.AddSeconds(10)
    while ($null -ne $ui.Job -and [datetime]::Now -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
    Assert-Ui ($null -eq $ui.Job) 'UI did not finish polling'
    Assert-Ui $ui.Buttons.restore.Enabled 'Buttons not re-enabled'
    Assert-Ui ($ui.Snapshot.Text -eq $snapshot) 'New snapshot not selected'
    Assert-Ui ($ui.Log.Text.Contains('CAPTURE SUCCESS')) 'Progress not shown in log'; $passed++
    Start-OrfUiAction $ui 'restore'
    while ($null -ne $ui.Job -and [datetime]::Now -lt $deadline) { Update-OrfUi $ui; Start-Sleep -Milliseconds 20 }
    Assert-Ui ($ui.Status.Text.StartsWith('Error:')) 'Failed job missing error status'
    Assert-Ui ($ui.Log.Text.Contains('SIMULATED RESTORE FAILURE')) 'Failure missing from UI'; $passed++
    Write-Host "$passed/6 UI tests passed on PowerShell $($PSVersionTable.PSVersion)"
} finally {
    if ($null -ne $running -and -not $running.Finished) { $running.Worker.Stop(); $running.Worker.Dispose() }
    if ($null -ne $ui) {
        if ($null -ne $ui.Job -and -not $ui.Job.Finished) { $ui.Job.Worker.Stop(); $ui.Job.Worker.Dispose() }
        $ui.Timer.Dispose(); $ui.Form.Dispose()
    }
    $resolved=[IO.Path]::GetFullPath($root); $base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^orf-ui-tests-[a-f0-9]{32}$') { throw 'Unsafe UI test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
