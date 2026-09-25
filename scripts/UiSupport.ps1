#requires -Version 5.1
# The worker has its own runspace; the UI thread only polls its streams.
function Start-OrfUiJob {
    param([string]$ProjectRoot, [ValidateSet('capture','preflight','restore','validate')][string]$Action, [string]$Snapshot)
    $engine = Join-Path $ProjectRoot 'scripts/OracleRefresh.ps1'
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw 'Missing scripts/OracleRefresh.ps1.' }
    $worker = [PowerShell]::Create()
    $code = {
        param($Engine, $Action, $Snapshot, $Root)
        $ErrorActionPreference = 'Stop'
        try {
            . $Engine
            Invoke-OrfAction -Action $Action -Snapshot $Snapshot -ProjectRoot $Root
            [pscustomobject]@{ OrfUiResult=$true; Success=$true }
        } catch {
            Write-Error $_.Exception.Message -ErrorAction Continue
            [pscustomobject]@{ OrfUiResult=$true; Success=$false }
        }
    }
    try {
        [void]$worker.AddScript($code.ToString()).AddArgument($engine).AddArgument($Action).AddArgument($Snapshot).AddArgument($ProjectRoot)
        $handle = $worker.BeginInvoke()
        return @{ Worker=$worker; Handle=$handle; Action=$Action; Started=[datetime]::Now; Finished=$false; HadErrors=$false; Success=$false; CaptureDirectory=$null }
    } catch { $worker.Dispose(); throw }
}

function Read-OrfUiJob {
    param($Job)
    $messages = New-Object 'System.Collections.Generic.List[object]'
    if ($Job.Finished) { return @{Messages=@();Completed=$true;Success=$Job.Success;CaptureDirectory=$Job.CaptureDirectory} }
    $completed = $Job.Handle.IsCompleted
    $result = @()
    if ($completed) {
        try { $result = @($Job.Worker.EndInvoke($Job.Handle)) }
        catch { $Job.HadErrors=$true; $messages.Add(@{Level='error';Text=$_.Exception.Message}) }
    }
    foreach ($record in $Job.Worker.Streams.Information.ReadAll()) {
        $text = [string]$record.MessageData
        $messages.Add(@{Level='info';Text=$text})
        if ($text -match '^CAPTURE SUCCESS: (.+)$') { $Job.CaptureDirectory=$Matches[1] }
    }
    foreach ($record in $Job.Worker.Streams.Warning.ReadAll()) { $messages.Add(@{Level='warning';Text=[string]$record.Message}) }
    foreach ($record in $Job.Worker.Streams.Error.ReadAll()) {
        $Job.HadErrors=$true; $messages.Add(@{Level='error';Text=[string]$record})
    }
    if ($completed) {
        $markers = @($result | Where-Object { $_.PSObject.Properties['OrfUiResult'] -and $_.OrfUiResult })
        $Job.Success = -not $Job.HadErrors -and $markers.Count -eq 1 -and $markers[0].Success
        $Job.Finished=$true; $Job.Worker.Dispose()
    }
    return @{Messages=$messages.ToArray();Completed=$completed;Success=$Job.Success;CaptureDirectory=$Job.CaptureDirectory}
}
