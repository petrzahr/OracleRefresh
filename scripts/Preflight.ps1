param([Parameter(Mandatory=$true)][string]$Snapshot)
$ErrorActionPreference = 'Stop'
& python "$PSScriptRoot/config_data.py" preflight --snapshot $Snapshot
if ($LASTEXITCODE -ne 0) { throw 'Preflight failed; do not run restore.' }
