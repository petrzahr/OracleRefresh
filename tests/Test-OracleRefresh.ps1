#requires -Version 5.1
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/OracleRefresh.ps1"
$script:TestCount = 0; $script:TestFailures = @()
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('orf-ps-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:TestRoot)

function Assert-True($Condition, [string]$Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Assert-Equal($Actual, $Expected) { if (-not (Test-OrfEqual $Actual $Expected)) { throw "Expected $(ConvertTo-OrfJson $Expected), got $(ConvertTo-OrfJson $Actual)" } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $caught = $false
    try { & $Body } catch { $caught = $true; if ($_.Exception.Message -notmatch $Pattern) { throw } }
    if (-not $caught) { throw "Expected exception matching $Pattern" }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:TestCount++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:TestFailures += $Name; Write-Host "FAIL $Name : $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}
function New-TestLayout {
    ConvertFrom-OrfJson '{"ID":{"type":"NUMBER","bytes":22,"precision":null,"scale":null,"chars":0,"charUsed":null,"nullable":"N","identity":"NO","virtual":"NO","hidden":"NO","defaultOnNull":"NO"},"V":{"type":"VARCHAR2","bytes":400,"precision":null,"scale":null,"chars":100,"charUsed":"C","nullable":"Y","identity":"NO","virtual":"NO","hidden":"NO","defaultOnNull":"NO"}}'
}
function New-TestConfig($Steps) {
    $root = Join-Path $script:TestRoot ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'config/schemas'))
    $db = ConvertFrom-OrfJson '{"tnsAlias":"TESTDB","sqlplusPath":"sqlplus.exe","schemaOrder":["APP"],"expectedTarget":{"dbUniqueName":"TEST","serviceName":"testpdb","conName":"TESTPDB"}}'
    Write-OrfText (Join-Path $root 'config/database.json') (ConvertTo-OrfJson $db)
    Write-OrfText (Join-Path $root 'config/credentials.json') '{"users":{"APP":{"username":"APP","password":"secret&password"}}}'
    Write-OrfText (Join-Path $root 'config/schemas/APP.json') (ConvertTo-OrfJson ([ordered]@{ steps=$Steps }))
    Write-OrfText (Join-Path $root 'config/schemas/APP.example.json') '{}'
    return Get-OrfConfiguration $root
}
function New-TestSnapshot($Config) {
    $steps = Copy-OrfValue $Config.Schemas[0]['steps']; $layouts = [ordered]@{}
    foreach ($step in $steps) {
        $layouts[$step['table']] = New-TestLayout
        $step['types'] = [ordered]@{ ID='NUMBER'; V='VARCHAR2' }
        if ($step['type'] -in @('replaceTable','restoreRows')) { $step['rows'] = @([ordered]@{ ID='1'; V='original' }) }
    }
    return [ordered]@{ version=3; status='SUCCESS'; configHash=$Config.Hash; schemas=@([ordered]@{ username='APP'; definition=(Copy-OrfValue $Config.Schemas[0]['steps']); layouts=$layouts; steps=$steps }) }
}

try {
    Test-Case 'Runs on Windows PowerShell 5.1' { Assert-Equal $PSVersionTable.PSVersion.Major 5; Assert-Equal $PSVersionTable.PSVersion.Minor 1 }
    Test-Case 'JSON keeps arrays, nested keys, null, booleans and date strings' {
        $text = '{"many":[[101,"API_URL"],[102,"ENVIRONMENT"]],"one":[1],"empty":[],"nil":null,"flag":false,"date":"2026-09-22T10:20:30Z"}'
        $value = ConvertFrom-OrfJson $text; $roundtrip = ConvertFrom-OrfJson (ConvertTo-OrfJson $value)
        Assert-Equal $roundtrip $value; Assert-Equal $roundtrip['many'].Count 2
        Assert-True ($roundtrip['empty'] -is [array]); Assert-Equal $roundtrip['empty'].Count 0
        Assert-True ($roundtrip['date'] -is [string])
    }
    Test-Case 'JSON and hashes are case-sensitive and culture-independent' {
        Assert-True ((Get-OrfDigest @{v='A'}) -cne (Get-OrfDigest @{v='a'}))
        $before = [Threading.Thread]::CurrentThread.CurrentCulture
        try { [Threading.Thread]::CurrentThread.CurrentCulture = 'cs-CZ'; Assert-Equal (Get-OrfLiteral ([decimal]1.25) 'NUMBER') '1.25' }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $before }
    }
    Test-Case 'Example files ignored, replacement limits optional' {
        $config = New-TestConfig @(@{ type='replaceTable'; table='USERS' }, @{ type='replaceTable'; table='USERGROUPS' })
        Assert-Equal $config.Schemas.Count 1; Assert-Equal $config.Schemas[0]['steps'].Count 2
    }
    Test-Case 'Actual shipped examples load unchanged' {
        $root = Join-Path $script:TestRoot 'examples'; [void][IO.Directory]::CreateDirectory((Join-Path $root 'config/schemas'))
        $repo = Split-Path -Parent $PSScriptRoot
        foreach ($name in @('database','credentials')) { Copy-Item -LiteralPath (Join-Path $repo "config/$name.example.json") -Destination (Join-Path $root "config/$name.json") }
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo 'config/schemas') -Filter '*.example.json') {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $root ('config/schemas/' + $file.Name.Replace('.example','')))
        }
        Assert-Equal (Get-OrfConfiguration $root).Schemas.Count 3
    }
    Test-Case 'Invalid replacement limits rejected' {
        foreach ($bad in @($null,$true,-1,'100')) { Assert-Throws { $null = New-TestConfig @(@{type='replaceTable';table='T';maxDeleteRows=$bad}) } 'maxDeleteRows' }
    }
    Test-Case 'Filtered delete still requires limit' { Assert-Throws { $null = New-TestConfig @(@{type='delete';table='T';match=@{ID=1}}) } 'maxDeleteRows' }
    Test-Case 'UPDATE requires stable key and prevents changing it' {
        Assert-Throws { $null = New-TestConfig @(@{type='update';table='T';set=@{V='x'}}) } 'column names'
        Assert-Throws { $null = New-TestConfig @(@{type='update';table='T';key=@('ID');set=@{ID=2}}) } 'stable key'
    }
    Test-Case 'restoreRows keyValues nesting and optional expectedRows' {
        $c = New-TestConfig @(@{type='restoreRows';table='T';key=@('ID','V');columns=@('OTHER');keyValues=@(@(101,'API_URL'),@(102,'ENVIRONMENT'))})
        Assert-Equal $c.Schemas[0]['steps'][0]['keyValues'].Count 2
    }
    Test-Case 'Conflicting restore and fixed operations rejected' {
        Assert-Throws { $null = New-TestConfig @(@{type='replaceTable';table='T'},@{type='delete';table='T';match=@{ID=1};maxDeleteRows=1}) } 'Conflicting'
    }
    Test-Case 'SQL literal handles Czech, apostrophes, ampersand, slash, CRLF and emoji' {
        $text = "Příliš žluťoučký`n`n/`nO'Brien & čaj`r`nkonec " + [char]::ConvertFromUtf32(0x1f600)
        $sql = Get-OrfLiteral $text 'VARCHAR2'
        Assert-True ($sql.Contains('CHR(13)') -and $sql.Contains('CHR(10)'))
        Assert-True (-not $sql.Contains("`n/`n")); Assert-True ($sql.Contains("O''Brien"))
        Assert-True ((Get-OrfLiteral '漢字' 'NVARCHAR2').Contains("N'漢字'"))
    }
    Test-Case 'NUMBER precision and NULL preserved' {
        Assert-Equal (Get-OrfLiteral '12345678901234567890123456789012345678' 'NUMBER') '12345678901234567890123456789012345678'
        Assert-Equal (Get-OrfLiteral $null 'NUMBER') 'NULL'
        Assert-Throws { Get-OrfLiteral '1); DELETE FROM T;' 'NUMBER' } 'numeric'
        Assert-Equal (Get-OrfPredicate ([ordered]@{V=''}) @{V='VARCHAR2'}) 'V IS NULL'
    }
    Test-Case 'Timezone validation preserves captured offset' {
        $sql = Get-OrfPredicate ([ordered]@{TZ='2026-09-22 12:00:00.000000000 +02:00'}) @{TZ='TIMESTAMP WITH TIME ZONE'} -Captured
        Assert-True ($sql.Contains("TO_CHAR(TZ,") -and $sql.Contains('TZH:TZM'))
    }
    Test-Case 'SQLPlus credentials via stdin and same-session target guard' {
        function Invoke-OrfProcess($Executable,$Arguments,$InputText,$TimeoutSeconds) {
            Assert-Equal $Arguments '-L -S /nolog'
            Assert-True ($InputText.IndexOf('set define off') -lt $InputText.IndexOf('connect '))
            Assert-True ($InputText.IndexOf('DB_UNIQUE_NAME') -lt $InputText.IndexOf('DELETE FROM T'))
            Assert-True ($InputText.Contains('SERVICE_NAME') -and $InputText.Contains('CON_NAME'))
            Assert-True ($InputText.EndsWith("exit rollback`n"))
            return @{ExitCode=0;Output='ok'}
        }
        $c = New-TestConfig @(@{type='replaceTable';table='T'})
        Assert-Equal (Invoke-OrfSqlPlus $c.Database $c.Schemas[0] 'DELETE FROM T;') 'ok'
    }
    Test-Case 'Native errors do not disclose credentials or row values' {
        function Invoke-OrfProcess { @{ExitCode=1;Output="ORA-20010: secret&password private-data`n"} }
        $c = New-TestConfig @(@{type='replaceTable';table='T'})
        try { $null = Invoke-OrfSqlPlus $c.Database $c.Schemas[0] ''; throw 'Expected SQL error' }
        catch { Assert-True ($_.Exception.Message.Contains('ORA-20010')); Assert-True ($_.Exception.Message -notmatch 'secret|private') }
    }
    Test-Case 'Row protocol preserves zero and one row arrays and detects truncation' {
        function Invoke-OrfSqlPlus { "ROW|{`"ID`":`"1`",`"V`":null}`nCOUNT|1`n" }
        $rows = Get-OrfRows @{} @{} 'T' ([ordered]@{ID='NUMBER';V='VARCHAR2'})
        Assert-True ($rows -is [array]); Assert-Equal $rows.Count 1; Assert-Equal $rows[0]['V'] $null
        function Invoke-OrfSqlPlus { "COUNT|0`n" }
        $rows = Get-OrfRows @{} @{} 'T' ([ordered]@{ID='NUMBER'})
        Assert-True ($rows -is [array]); Assert-Equal $rows.Count 0
        function Invoke-OrfSqlPlus { "COUNT|1`n" }
        Assert-Throws { Get-OrfRows @{} @{} 'T' ([ordered]@{ID='NUMBER'}) } 'incomplete'
    }
    Test-Case 'Capture verifies snapshot and full backups with NULL and Unicode' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfRows { return ,@([ordered]@{ID='1';V="Příliš`r`n`n/`nO'Brien & čaj"}, [ordered]@{ID='2';V=$null}) }
        $c = New-TestConfig @(@{type='replaceTable';table='T'})
        $path = Invoke-OrfCapture $c; $snap = Read-OrfSnapshot $path $c
        Assert-Equal $snap['schemas'][0]['steps'][0]['rows'].Count 2
        $csvPath = Join-Path (Split-Path -Parent $path) 'APP/T.csv'
        $csv = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)
        Assert-Equal $csv[0].V "Příliš`r`n`n/`nO'Brien & čaj"; Assert-Equal $csv[1].V__IS_NULL '1'
        Write-OrfText $path (([IO.File]::ReadAllText($path)) + ' ')
        Assert-Throws { Read-OrfSnapshot $path $c } 'checksum'
    }
    Test-Case 'All four step kinds captured and empty replacement supported' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfRows($Db,$Account,$Table) { if ($Table -eq 'EMPTY') { return ,@() }; return ,@([ordered]@{ID='1';V='x'}) }
        function Get-OrfCount { 0 }
        $steps = @(@{type='restoreRows';table='R';key=@('ID');columns=@('V');allRows=$true},@{type='replaceTable';table='EMPTY'},
            @{type='update';table='U';key=@('ID');set=@{V='target'}},@{type='delete';table='D';match=@{V='x'};maxDeleteRows=5})
        $c = New-TestConfig $steps; $path = Invoke-OrfCapture $c; $snap = Read-OrfSnapshot $path $c
        Assert-Equal $snap['schemas'][0]['steps'].Count 4
        Assert-Equal $snap['schemas'][0]['steps'][1]['rows'].Count 0
        Assert-True ((Get-OrfRestoreSql $snap['schemas'][0] @{updates=@{'2'=@{rows=@(@{ID='1'})}}} $false).Contains('DELETE FROM EMPTY;'))
    }
    Test-Case 'Failed capture never leaves a successful snapshot' {
        function Get-OrfLayout { throw 'simulated capture failure' }
        $c = New-TestConfig @(@{type='replaceTable';table='T'})
        Assert-Throws { Invoke-OrfCapture $c } 'simulated'
        $path = @(Get-ChildItem -LiteralPath (Join-Path $c.Root 'snapshots') -Recurse -Filter snapshot.json)[0].FullName
        Assert-Equal (Read-OrfJson $path)['status'] 'FAILED'
        Assert-Throws { Read-OrfSnapshot $path $c } 'Incomplete'
    }
    Test-Case 'Old Python snapshot rejected before database work' {
        $c = New-TestConfig @(@{type='replaceTable';table='T'}); $snap = New-TestSnapshot $c
        $snap['version']=2; Write-OrfSnapshot $c.Root $snap
        Assert-Throws { Read-OrfSnapshot (Join-Path $c.Root 'snapshot.json') $c } 'version 3'
    }
    Test-Case 'Changing configuration invalidates an existing snapshot' {
        $c=New-TestConfig @(@{type='replaceTable';table='T'}); $s=New-TestSnapshot $c
        Write-OrfSnapshot $c.Root $s; $c.Hash='changed'
        Assert-Throws { Read-OrfSnapshot (Join-Path $c.Root 'snapshot.json') $c } 'configuration'
    }
    Test-Case 'Explicit composite keys capture with exactly one row per tuple' {
        function Invoke-OrfSqlPlus($Db,$Account,$Sql) {
            if ($Sql.Contains('ID = 101')) { return "ROW|{`"ID`":`"101`",`"K`":`"API_URL`",`"V`":`"test`"}`nCOUNT|1`n" }
            return "ROW|{`"ID`":`"102`",`"K`":`"ENVIRONMENT`",`"V`":null}`nCOUNT|1`n"
        }
        $step=@{table='T';key=@('ID','K')}; $types=[ordered]@{ID='NUMBER';K='VARCHAR2';V='VARCHAR2'}
        $rows=Get-OrfSelectedRows @{} @{} $step $types @(@(101,'API_URL'),@(102,'ENVIRONMENT'))
        Assert-Equal $rows.Count 2; Assert-Equal $rows[1]['V'] $null
    }
    Test-Case 'Preflight unlimited replacement is read-only and skips row ceiling count' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfCount($Db,$Account,$Query) { Assert-True ($Query.Contains('user_triggers')); return 0 }
        function Invoke-OrfSqlPlus($Db,$Account,$Sql) { Assert-True ($Sql.Contains('dba_constraints')); return '' }
        $c = New-TestConfig @(@{type='replaceTable';table='USERS'},@{type='replaceTable';table='USERGROUPS'})
        $snap = New-TestSnapshot $c; $state = Join-Path $c.Root 'restore-plan.json'
        $plan = Invoke-OrfPreflight $c $snap $state; Assert-True (-not (Test-Path -LiteralPath $state))
        $sql = Get-OrfRestoreSql $snap['schemas'][0] $plan['schemas'][0] $true
        Assert-True ($sql.IndexOf('DELETE FROM USERGROUPS') -lt $sql.IndexOf('DELETE FROM USERS'))
        Assert-True ($sql.IndexOf('INSERT INTO USERS') -lt $sql.IndexOf('INSERT INTO USERGROUPS'))
        Assert-True (-not $sql.Contains('TRUNCATE')); Assert-True (-not $sql.Contains('maxDeleteRows exceeded'))
        Assert-Equal ([regex]::Matches($sql,'COMMIT;').Count) 1
        Assert-True ($sql.IndexOf('replacement value mismatch') -lt $sql.IndexOf('COMMIT;'))
        Assert-True ($sql.Contains('EXCEPTION WHEN OTHERS THEN ROLLBACK;'))
    }
    Test-Case 'FK parent-child accepted and external reference rejected' {
        $c = New-TestConfig @(@{type='replaceTable';table='USERS'},@{type='replaceTable';table='USERGROUPS'}); $s = New-TestSnapshot $c
        function Invoke-OrfSqlPlus { "FK|APP|USERGROUPS|USERS`n" }
        Assert-OrfDependencies $c.Database $c.Schemas[0] $s['schemas'][0]
        function Invoke-OrfSqlPlus { "FK|OTHER|USERGROUPS|USERS`n" }
        Assert-Throws { Assert-OrfDependencies $c.Database $c.Schemas[0] $s['schemas'][0] } 'FK requires'
    }
    Test-Case 'Layout narrowing stops preflight before writes' {
        function Get-OrfLayout { $l=New-TestLayout; $l['V']['chars']=20; return $l }
        function Invoke-OrfSqlPlus { throw 'unexpected database write' }
        $c = New-TestConfig @(@{type='replaceTable';table='T'}); $s = New-TestSnapshot $c
        Assert-Throws { Invoke-OrfPreflight $c $s } 'layout changed'
    }
    Test-Case 'Identity columns and enabled triggers block preflight' {
        function Get-OrfLayout { $l=New-TestLayout; $l['ID']['identity']='YES'; return $l }
        function Get-OrfCount { 0 }; function Invoke-OrfSqlPlus { '' }
        $c=New-TestConfig @(@{type='replaceTable';table='T'}); $s=New-TestSnapshot $c
        $s['schemas'][0]['layouts']['T']['ID']['identity']='YES'
        Assert-Throws { Invoke-OrfPreflight $c $s } 'identity'
        function Get-OrfLayout { New-TestLayout }; function Get-OrfCount { 1 }
        $s=New-TestSnapshot $c
        Assert-Throws { Invoke-OrfPreflight $c $s } 'triggers'
    }
    Test-Case 'UPDATE checks precision byte length and NOT NULL before writes' {
        $layout=New-TestLayout; $layout['ID']['precision']=3; $layout['ID']['scale']=2
        $layout['V']['charUsed']='B'; $layout['V']['bytes']=1; $layout['V']['nullable']='N'
        $sql=Get-OrfValueChecks @{table='T';set=[ordered]@{ID='1.234';V='č'}} $layout
        Assert-True ($sql.Contains('NUMBER(3,2)')); Assert-True ($sql.Contains('LENGTHB')); Assert-True ($sql.Contains('IS NULL'))
    }
    Test-Case 'Overlapping UPDATE keys rejected' {
        function Get-OrfLayout { New-TestLayout }; function Get-OrfCount { 0 }; function Invoke-OrfSqlPlus { '' }
        function Get-OrfRows { return ,@([ordered]@{ID='1'}) }
        $c=New-TestConfig @(@{type='update';table='T';key=@('ID');set=@{V='A'}},@{type='update';table='T';key=@('ID');set=@{V='B'}})
        $s=New-TestSnapshot $c; Assert-Throws { Invoke-OrfPreflight $c $s } 'overlapping'
    }
    Test-Case 'DELETE that would remove an UPDATE row is rejected' {
        function Get-OrfLayout { New-TestLayout }; function Invoke-OrfSqlPlus { '' }
        function Get-OrfRows { return ,@([ordered]@{ID='1'}) }
        function Get-OrfCount($Db,$Account,$Query) { if ($Query.Contains('WHERE ID = 1 AND')) { return 1 }; return 0 }
        $c=New-TestConfig @(@{type='update';table='T';key=@('ID');set=@{V='A'}},@{type='delete';table='T';match=@{V='A'};maxDeleteRows=10})
        $s=New-TestSnapshot $c; Assert-Throws { Invoke-OrfPreflight $c $s } 'overlaps'
    }
    Test-Case 'Explicit replacement ceiling retained' {
        function Get-OrfLayout { New-TestLayout }
        function Invoke-OrfSqlPlus { '' }
        function Get-OrfCount($Db,$Account,$Query) { if ($Query.Contains('user_triggers')) { return 0 }; return 11 }
        $c = New-TestConfig @(@{type='replaceTable';table='T';maxDeleteRows=10}); $s = New-TestSnapshot $c
        Assert-Throws { Invoke-OrfPreflight $c $s } 'maxDeleteRows'
        Assert-True ((Get-OrfRestoreSql $s['schemas'][0] @{updates=@{}} $true).Contains('SQL%ROWCOUNT > 10'))
    }
    Test-Case 'Missing restore key is skipped with a warning' {
        function Get-OrfLayout { New-TestLayout }; function Get-OrfCount { 0 }
        function Get-OrfRows { return ,@() }
        $c = New-TestConfig @(@{type='restoreRows';table='T';key=@('ID');columns=@('V');allRows=$true}); $s=New-TestSnapshot $c
        $output = @(& { Invoke-OrfPreflight $c $s } 3>&1)
        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $plan = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
        Assert-True ($warnings.Count -gt 0) 'Missing key warning not emitted'
        $sql = Get-OrfRestoreSql $s['schemas'][0] $plan['schemas'][0] $true
        Assert-True ($sql.Contains('SQL%ROWCOUNT > 1'))
        Assert-True (-not $sql.Contains('SQL%ROWCOUNT <> 1'))
        Assert-True ($sql.Contains('IF v_count = 1 THEN'))
        Assert-True (-not $sql.Contains('INSERT INTO'))
        Assert-True (-not $sql.Contains('DELETE FROM'))
    }
    Test-Case 'Restore selects only captured keys and tolerates missing keys' {
        function Get-OrfRows($Db,$Account,$Table,$Types,$MaxRows,$Where) {
            if ($Where -eq 'ID = 1') { return ,@([ordered]@{ID='1';V='refreshed'}) }
            if ($Where -eq 'ID = 2') { return ,@() }
            throw 'Unexpected key selected'
        }
        $step = @{table='T';key=@('ID')}; $types=@{ID='NUMBER';V='VARCHAR2'}
        $rows = Get-OrfSelectedRows @{} @{} $step $types @(@('1'),@('2')) -AllowMissing -WarningAction SilentlyContinue
        Assert-Equal $rows.Count 1
        Assert-Equal $rows[0]['ID'] '1'
        Assert-Throws { Get-OrfSelectedRows @{} @{} $step $types @(@('2')) } 'missing'
        function Get-OrfRows { return ,@(@{ID='1'},@{ID='1'}) }
        Assert-Throws { Get-OrfSelectedRows @{} @{} $step $types @(@('1')) -AllowMissing } 'duplicate'
    }
    Test-Case 'Skipped updates generate guarded full-row recovery from verified CSV' {
        $c=New-TestConfig @(@{type='restoreRows';table='T';key=@('ID');columns=@('V');allRows=$true})
        $s=New-TestSnapshot $c; $entry=$s['schemas'][0]
        $directory=Join-Path $c.Root 'backup'; [void][IO.Directory]::CreateDirectory((Join-Path $directory 'APP'))
        $entry['layouts']['T']['EXTRA']=Copy-OrfValue $entry['layouts']['T']['V']
        $types=Get-OrfTypes $entry['layouts']['T']
        $full=[ordered]@{ID='1';V="O'Brien`r`nvalue";EXTRA=$null}
        $entry['steps'][0]['rows'][0]['V']=$full['V']
        $csv=Join-Path $directory 'APP/T.csv'
        Write-OrfText $csv (Get-OrfCsv @($types.Keys) @($full))
        Write-OrfText (Join-Path $directory 'backups.sha256') ((Get-OrfHash ([IO.File]::ReadAllBytes($csv))) + '  APP/T.csv')
        $report=Join-Path $directory 'report'
        Write-OrfSkippedRecovery $entry $c.Database $c.Schemas[0] 'ORF_SKIP|0|0' $directory $report
        $log=Read-OrfJson (Join-Path $report 'APP.skipped-updates.json')
        Assert-Equal $log[0]['key']['ID'] '1'
        $sql=[IO.File]::ReadAllText((Join-Path $report 'APP.missing-rows.insert.sql'))
        Assert-True ($sql.Contains('EXTRA')) 'Full backup columns missing'
        Assert-True ($sql.Contains('NULL')) 'NULL not restored'
        Assert-True ($sql.Contains("O''Brien")) 'Quote not escaped'
        Assert-True ($sql.Contains('CHR(13)')) 'Newline not preserved'
        Assert-True ($sql.Contains('WHERE NOT EXISTS')) 'Retry guard missing'
        Assert-True ($sql.Contains('SYS_CONTEXT')) 'Target guard missing'
        Assert-True (-not ($sql -match '(?m)^COMMIT;')) 'Unexpected automatic commit'
        Write-OrfText $csv 'tampered'
        $bad=Join-Path $directory 'bad'
        Assert-Throws { Write-OrfSkippedRecovery $entry $c.Database $c.Schemas[0] 'ORF_SKIP|0|0' $directory $bad } 'checksum'
        Assert-True (Test-Path (Join-Path $bad 'APP.skipped-updates.json')) 'Audit lost on generation failure'
        Assert-True (-not (Test-Path (Join-Path $bad 'APP.missing-rows.insert.sql'))) 'Partial SQL published'
        $empty=Join-Path $directory 'empty'
        Write-OrfSkippedRecovery $entry $c.Database $c.Schemas[0] '' $directory $empty
        Assert-True (-not (Test-Path (Join-Path $empty 'APP.missing-rows.insert.sql')))
        $restoreSql=Get-OrfRestoreSql $entry @{updates=@{}} $true
        Assert-True ($restoreSql.Contains("SQL%ROWCOUNT = 0 THEN DBMS_OUTPUT.PUT_LINE('ORF_SKIP|0|0')"))
    }
    Test-Case 'UPDATE stable keys persisted before failure and reused on retry' {
        function Get-OrfLayout { New-TestLayout }; function Get-OrfCount { 0 }
        function Get-OrfRows { return ,@([ordered]@{ID='42'}) }
        $c = New-TestConfig @(@{type='update';table='T';key=@('ID');match=@{V='TEST'};set=@{V='TEST'};expectedRows=1})
        $s=New-TestSnapshot $c; $state=Join-Path $c.Root 'restore-plan.json'
        function Invoke-OrfSqlPlus($Db,$Account,$Sql) {
            if ($Sql.Contains('COMMIT;')) { Assert-True (Test-Path -LiteralPath $state); throw 'simulated lost acknowledgement' }; return ''
        }
        Assert-Throws { Invoke-OrfRestore $c $s $state } 'simulated'
        function Invoke-OrfSqlPlus($Db,$Account,$Sql) {
            if ($Sql.Contains('COMMIT;')) {
                Assert-True ($Sql.Contains('WHERE ID = 42')); Assert-True (-not $Sql.Contains('selection changed since preflight'))
            }; return ''
        }
        Invoke-OrfRestore $c $s $state; Invoke-OrfValidate $c $s $state
        $raw = Read-OrfJson $state; $raw['plan']['snapshotHash']='wrong'; Write-OrfText $state (ConvertTo-OrfJson $raw)
        Assert-Throws { Read-OrfPlan $state $s $c.Database } 'mismatch'
    }
    Test-Case 'UPDATE expectedRows zero valid and wrong count rejected' {
        $step = @{table='T';expectedRows=0;match=@{V='x'}}
        Assert-OrfUpdateCount $step 0; Assert-Throws { Assert-OrfUpdateCount $step 1 } 'count'
    }
    Test-Case 'Separate UPDATE validation requires saved plan' {
        function Get-OrfLayout { New-TestLayout }
        $c=New-TestConfig @(@{type='update';table='T';key=@('ID');set=@{V='x'}}); $s=New-TestSnapshot $c
        Assert-Throws { Invoke-OrfValidate $c $s (Join-Path $c.Root 'missing.json') } 'saved restore plan'
    }
    Test-Case 'Direct native UTF-8 transport drains stdout and stderr and times out' {
        # Built-in Windows PowerShell child emulates SQL*Plus pipes, not Oracle.
        $fake = Join-Path $script:TestRoot 'fake-sqlplus.ps1'
        $source = @'
$utf8 = New-Object Text.UTF8Encoding($false)
$reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$data = $reader.ReadToEnd()
$out = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$err = New-Object IO.StreamWriter([Console]::OpenStandardError(), $utf8)
$err.Write(('e' * 100000)); $err.Flush()
$out.Write($data); $out.Flush()
'@
        Write-OrfText $fake $source
        $native = Join-Path $PSHOME 'powershell.exe'
        $text = ("Příliš žluťoučký`r`n" * 10000)
        $result = Invoke-OrfProcess $native ('-NoProfile -File "' + $fake + '"') $text 20
        Assert-Equal $result.ExitCode 0; Assert-Equal $result.Output ($text + ('e' * 100000))
        Assert-Throws { Invoke-OrfProcess $native '-NoProfile -Command "Start-Sleep -Seconds 10"' 'x' 1 } 'timeout'
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($script:TestRoot)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^orf-ps-tests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "$($script:TestCount - $script:TestFailures.Count)/$script:TestCount tests passed on PowerShell $($PSVersionTable.PSVersion)"
if ($script:TestFailures.Count -gt 0) { exit 1 }
