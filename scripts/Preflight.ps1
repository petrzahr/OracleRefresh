#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Snapshot)
$ErrorActionPreference = 'Stop'
try {
    . "$PSScriptRoot/OracleRefresh.ps1"
    Invoke-OrfAction -Action preflight -Snapshot $Snapshot
} catch { Write-Error ("PREFLIGHT FAILED: " + $_.Exception.Message) -ErrorAction Continue; exit 1 }
