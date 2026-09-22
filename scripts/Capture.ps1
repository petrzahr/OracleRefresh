$ErrorActionPreference = 'Stop'
& python "$PSScriptRoot/config_data.py" capture
if ($LASTEXITCODE -ne 0) { throw 'Capture failed; do not refresh the database.' }
