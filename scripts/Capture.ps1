#requires -Version 5.1
$ErrorActionPreference = 'Stop'
try {
    . "$PSScriptRoot/OracleRefresh.ps1"
    Invoke-OrfAction -Action capture
} catch { Write-Error ("CAPTURE FAILED: " + $_.Exception.Message) -ErrorAction Continue; exit 1 }
