param([Parameter(Mandatory=$true)][string]$Snapshot)
$ErrorActionPreference = 'Stop'
& python "$PSScriptRoot/config_data.py" validate --snapshot $Snapshot
if ($LASTEXITCODE -ne 0) { throw 'Validation failed.' }
