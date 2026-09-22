#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Snapshot)
$ErrorActionPreference = 'Stop'
try {
    . "$PSScriptRoot/OracleRefresh.ps1"
    Invoke-OrfAction -Action validate -Snapshot $Snapshot
} catch { Write-Error ("VALIDATION FAILED: " + $_.Exception.Message) -ErrorAction Continue; exit 1 }
