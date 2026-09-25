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
    $db = ConvertFrom-OrfJson '{"host":"TESTDB","sqlplusPath":"sqlplus.exe","schemaOrder":["APP"],"users":{"APP":{"username":"APP","password":"secret&password"}}}'
    Write-OrfText (Join-Path $root 'config/database.json') (ConvertTo-OrfJson $db)
    Write-OrfText (Join-Path $root 'config/schemas/APP.json') (ConvertTo-OrfJson ([ordered]@{ steps=$Steps }))
    Write-OrfText (Join-Path $root 'config/schemas/APP.example.json') '{}'
    return Get-OrfConfiguration $root
}
function New-TestSnapshot($Config) {
    $steps = Copy-OrfValue $Config.Schemas[0]['steps']; $layouts = [ordered]@{}
    foreach ($step in $steps) {
        $layouts[$step['table']] = New-TestLayout
        $step['types'] = [ordered]@{ ID='NUMBER'; V='VARCHAR2' }
        if ($step['type'] -in @('replaceTable','restoreRows','insert')) { $step['rows'] = @([ordered]@{ ID='1'; V='original' }) }
    }
    return [ordered]@{ version=4; status='SUCCESS'; configHash=$Config.Hash; schemas=@([ordered]@{ username='APP'; definition=(Copy-OrfValue $Config.Schemas[0]['steps']); layouts=$layouts; steps=$steps }) }
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
    Test-Case 'Example files ignored and replacements use explicit allRows' {
        $config = New-TestConfig @(@{ type='replaceTable'; allRows=$true; table='USERS' }, @{ type='replaceTable'; allRows=$true; table='USERGROUPS' })
        Assert-Equal $config.Schemas.Count 1; Assert-Equal $config.Schemas[0]['steps'].Count 2
    }
    Test-Case 'Actual shipped examples load unchanged' {
        $root = Join-Path $script:TestRoot 'examples'; [void][IO.Directory]::CreateDirectory((Join-Path $root 'config/schemas'))
        $repo = Split-Path -Parent $PSScriptRoot
        Copy-Item -LiteralPath (Join-Path $repo 'config/database.example.json') -Destination (Join-Path $root 'config/database.json')
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo 'config/schemas') -Filter '*.example.json') {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $root ('config/schemas/' + $file.Name.Replace('.example','')))
        }
        Assert-Equal (Get-OrfConfiguration $root).Schemas.Count 3
    }
    Test-Case 'Removed fields are rejected explicitly' {
        foreach ($field in @('maxRows','backupMaxRows','maxDeleteRows','maxInsertRows','expectedRows','keyValues')) {
            $step=@{type='replaceTable';table='T';allRows=$true}; $step[$field]=1
            Assert-Throws { New-TestConfig @($step) } 'Unsupported step field'
        }
    }
    Test-Case 'Selection and explicit keys are mandatory and match equals key' {
        foreach ($kind in @('backupTable','restoreRows','insert','update','delete')) {
            $step=@{type=$kind;table='T';match=@(@{ID=1})}
            Assert-Throws { New-TestConfig @($step) } 'column names'
        }
        foreach ($selection in @(@{},@{allRows=$false},@{allRows=$true;match=@(@{ID=1})},@{match=@()},@{match=@{ID=1}},@{match=@(@{V='x'})},@{match=@(@{ID=$null})},@{match=@(@{ID=''})},@{match=@(@{ID=1;V='x'})})) {
            $step=@{type='insert';table='T';key=@('ID')}
            foreach ($field in $selection.Keys) { $step[$field]=$selection[$field] }
            Assert-Throws { New-TestConfig @($step) } 'match|allRows|Match'
        }
        Assert-Throws { New-TestConfig @(@{type='replaceTable';allRows=$true;table='T';key=@('ID');match=@(@{ID=1})}) } 'Unsupported|requires allRows'
    }
    Test-Case 'Backup-only exports full tables and is ignored after capture' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfRows($Db,$Account,$Table,$Types,$MaxRows,$Where) {
            Assert-Equal $Where ''; Assert-Equal $MaxRows $null
            return ,@([ordered]@{ID='1';V='original'},[ordered]@{ID='2';V=$null})
        }
        $c=New-TestConfig @(@{type='backupTable';table='ARCHIVE';allRows=$true})
        $path=Invoke-OrfCapture $c; $s=Read-OrfSnapshot $path $c; $entry=$s['schemas'][0]
        $dir=Split-Path -Parent $path
        Assert-Equal @(Import-Csv -LiteralPath (Join-Path $dir 'APP/ARCHIVE.csv')).Count 2
        $sql=[IO.File]::ReadAllText((Join-Path $dir 'APP/ARCHIVE.insert.sql'))
        Assert-Equal ([regex]::Matches($sql,'INSERT INTO APP.ARCHIVE').Count) 2
        function Get-OrfLayout { throw 'Backup table must not be inspected after capture' }
        function Get-OrfCount { throw 'Backup table must not be queried after capture' }
        function Invoke-OrfSqlPlus($Db,$Account,$Sql) { Assert-True (-not $Sql.Contains('ARCHIVE')) }
        $plan=Invoke-OrfPreflight $c $s
        Assert-Equal (Get-OrfValidationSql $entry $plan['schemas'][0]) ''
        Assert-True (-not (Get-OrfRestoreSql $entry $plan['schemas'][0] $true).Contains('ARCHIVE'))
        Invoke-OrfValidate $c $s ''
        $entry['steps'] += ConvertFrom-OrfJson '{"type":"delete","table":"OTHER","key":["ID"],"match":[{"ID":1}],"types":{"ID":"NUMBER"}}'
        $restore=Get-OrfRestoreSql $entry $plan['schemas'][0] $true
        Assert-True ($restore.Contains('LOCK TABLE OTHER') -and $restore.Contains('DELETE FROM OTHER') -and -not $restore.Contains('ARCHIVE'))
    }
    Test-Case 'Backup-only accepts empty tables and rejects conflicts' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfRows { return ,@() }
        $c=New-TestConfig @(@{type='backupTable';table='T';allRows=$true})
        $path=Invoke-OrfCapture $c
        Assert-Equal @(Import-Csv -LiteralPath (Join-Path (Split-Path -Parent $path) 'APP/T.csv')).Count 0
        foreach ($steps in @(@(@{type='backupTable';table='T';allRows=$true},@{type='replaceTable';table='T';allRows=$true}),@(@{type='replaceTable';table='T';allRows=$true},@{type='backupTable';table='T';allRows=$true}))) {
            Assert-Throws { New-TestConfig $steps } 'Conflicting'
        }
    }
    Test-Case 'AllRows key requirements and table conflicts' {
        foreach ($kind in @('restoreRows','insert','update')) {
            Assert-Throws { New-TestConfig @(@{type=$kind;table='T';allRows=$true}) } 'column names'
        }
        foreach ($kind in @('backupTable','delete','replaceTable')) {
            $c=New-TestConfig @(@{type=$kind;table='T';allRows=$true})
            Assert-True (-not $c.Schemas[0]['steps'][0].Contains('key'))
            Assert-Throws { New-TestConfig @(@{type=$kind;table='T';allRows=$true;key=@('ID')}) } 'key'
        }
        Assert-Throws { New-TestConfig @(@{type='insert';table='T';key=@('ID');allRows=$true},@{type='delete';table='T';allRows=$true}) } 'Conflicting'
    }
    Test-Case 'INSERT capture exports selected full rows using only explicit keys' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfCount { 0 }
        function Invoke-OrfSqlPlus($Db,$Account,$Sql) { throw 'Automatic primary-key discovery is forbidden' }
        function Get-OrfRows($Db,$Account,$Table,$Types,$MaxRows,$Where) {
            Assert-Equal $Where '((ID = 7))'; Assert-Equal $MaxRows $null; Assert-Equal @($Types.Keys) @('ID','V')
            return ,@([ordered]@{ID='7';V=$null})
        }
        $c=New-TestConfig @(@{type='insert';table='T';key=@('ID');match=@(@{ID=7})})
        $path=Invoke-OrfCapture $c; $s=Read-OrfSnapshot $path $c; $step=$s['schemas'][0]['steps'][0]
        Assert-Equal $step['key'] @('ID'); Assert-Equal $step['rows'] @([ordered]@{ID='7';V=$null})
        $sql=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $path) 'APP/T.insert.sql'))
        Assert-Equal ([regex]::Matches($sql,'INSERT INTO').Count) 1
        Assert-True ($sql.Contains('INSERT INTO APP.T (ID, V)')); Assert-True ($sql.Contains('NULL'))
        $restore=Get-OrfRestoreSql $s['schemas'][0] @{updates=@{}} $true
        Assert-True ($restore.Contains('WHERE NOT EXISTS (SELECT 1 FROM T WHERE ID = 7)'))
        Assert-True (-not $restore.Contains('DELETE FROM T'))
        Assert-True ($restore.IndexOf('insert key conflicts') -lt $restore.IndexOf('INSERT INTO T'))
    }
    Test-Case 'INSERT empty selection stays empty' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfCount { 0 }
        function Get-OrfRows { return ,@() }
        $c=New-TestConfig @(@{type='insert';table='T';match=@(@{ID=1});key=@('ID')})
        $path=Invoke-OrfCapture $c; $s=Read-OrfSnapshot $path $c
        Assert-Equal $s['schemas'][0]['steps'][0]['rows'].Count 0
        Assert-True (-not (Get-OrfRestoreSql $s['schemas'][0] @{updates=@{}} $true).Contains('INSERT INTO'))
    }
    Test-Case 'INSERT rejects unsupported columns and unknown explicit keys' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfCount { 0 }
        $c=New-TestConfig @(@{type='insert';table='T';match=@(@{UNKNOWN=1});key=@('UNKNOWN')})
        Assert-Throws { Invoke-OrfCapture $c } 'Missing column'
        function Get-OrfLayout { $l=New-TestLayout; $l['ID']['identity']='YES'; return $l }
        $c=New-TestConfig @(@{type='insert';table='T';match=@(@{ID=1});key=@('ID')})
        Assert-Throws { Invoke-OrfCapture $c } 'identity/invisible'
    }
    Test-Case 'UPDATE requires stable key and prevents changing it' {
        Assert-Throws { $null = New-TestConfig @(@{type='update';table='T';allRows=$true;set=@{V='x'}}) } 'column names'
        Assert-Throws { $null = New-TestConfig @(@{type='update';table='T';key=@('ID');allRows=$true;set=@{ID=2}}) } 'stable key'
    }
    Test-Case 'Composite match normalizes names and deduplicates exact keys' {
        $c=New-TestConfig @(@{type='restoreRows';table='T';key=@('id','v');columns=@('OTHER');match=@(@{id=101;v='API_URL'},@{V='ENVIRONMENT';ID=102},@{ID=101;V='API_URL'})})
        $step=$c.Schemas[0]['steps'][0]
        Assert-Equal $step['key'] @('ID','V'); Assert-Equal $step['match'].Count 2
        Assert-Equal (Get-OrfSelection $step @{ID='NUMBER';V='VARCHAR2'}) "((ID = 101 AND V = ('API_URL')) OR (ID = 102 AND V = ('ENVIRONMENT')))"
    }
    Test-Case 'Conflicting restore and fixed operations rejected' {
        Assert-Throws { $null = New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'},@{type='delete';table='T';key=@('ID');match=@(@{ID=1})}) } 'Conflicting'
    }
    Test-Case 'Every documented JSON example loads with the new format' {
        $doc=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../CONFIG_EXAMPLES.md'))
        $blocks=[regex]::Matches($doc,'(?s)```json\s*(.*?)\s*```')
        Assert-Equal $blocks.Count 14
        foreach ($block in $blocks) {
            $example=ConvertFrom-OrfJson $block.Groups[1].Value
            $null=New-TestConfig $example['steps']
        }
    }
    Test-Case 'Filtered backup exports selected rows and never discovers a primary key' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfCount { 0 }
        function Invoke-OrfSqlPlus { throw 'No primary-key discovery or writes during backup' }
        function Get-OrfRows($Db,$Account,$Table,$Types,$MaxRows,$Where) {
            Assert-Equal $Where '((ID = 101) OR (ID = 102))'
            Assert-Equal @($Types.Keys) @('ID','V')
            return ,@([ordered]@{ID='101';V='one'},[ordered]@{ID='102';V='two'})
        }
        $c=New-TestConfig @(@{type='backupTable';table='T';key=@('ID');match=@(@{ID=101},@{ID=102})})
        $path=Invoke-OrfCapture $c; $s=Read-OrfSnapshot $path $c
        $csv=@(Import-Csv -LiteralPath (Join-Path (Split-Path -Parent $path) 'APP/T.csv'))
        Assert-Equal $csv.Count 2; Assert-Equal $csv[1].V 'two'
        Assert-Equal (Get-OrfValidationSql $s['schemas'][0] @{updates=@{}}) ''
    }
    Test-Case 'Composite restore capture selects by OR and restores per-key original values' {
        function Get-OrfLayout {
            $l=New-TestLayout; $l['TENANT_ID']=$l['ID']; $l.Remove('ID')
            $l['CONFIG_KEY']=Copy-OrfValue $l['V']; return $l
        }
        function Get-OrfCount { 0 }
        function Get-OrfRows($Db,$Account,$Table,$Types,$MaxRows,$Where) {
            if ($Where) { Assert-Equal $Where "((TENANT_ID = 10 AND CONFIG_KEY = ('API_URL')) OR (TENANT_ID = 20 AND CONFIG_KEY = ('API_URL')))" }
            return ,@([ordered]@{TENANT_ID='10';CONFIG_KEY='API_URL';V='test10'},[ordered]@{TENANT_ID='20';CONFIG_KEY='API_URL';V='test20'})
        }
        $c=New-TestConfig @(@{type='restoreRows';table='TENANT_CONFIG';key=@('TENANT_ID','CONFIG_KEY');match=@(@{TENANT_ID=10;CONFIG_KEY='API_URL'},@{TENANT_ID=20;CONFIG_KEY='API_URL'});columns=@('V')})
        $path=Invoke-OrfCapture $c; $s=Read-OrfSnapshot $path $c
        $sql=Get-OrfRestoreSql $s['schemas'][0] @{updates=@{}} $true
        Assert-True ($sql.Contains("UPDATE TENANT_CONFIG SET V = ('test10') WHERE TENANT_ID = 10 AND CONFIG_KEY = ('API_URL');"))
        Assert-True ($sql.Contains("UPDATE TENANT_CONFIG SET V = ('test20') WHERE TENANT_ID = 20 AND CONFIG_KEY = ('API_URL');"))
        Assert-True (-not $sql.Contains('DELETE FROM TENANT_CONFIG'))
        Assert-True (-not $sql.Contains('INSERT INTO TENANT_CONFIG'))
    }
    Test-Case 'Empty restore selection is valid and allRows insert captures full rows' {
        function Get-OrfLayout { New-TestLayout }; function Get-OrfCount { 0 }
        function Get-OrfRows($Db,$Account,$Table,$Types,$MaxRows,$Where) {
            if ($Where) { return ,@() }
            return ,@([ordered]@{ID='1';V='original'})
        }
        $c=New-TestConfig @(@{type='restoreRows';table='R';key=@('ID');match=@(@{ID=99});columns=@('V')},@{type='insert';table='I';key=@('ID');allRows=$true})
        $path=Invoke-OrfCapture $c; $s=Read-OrfSnapshot $path $c
        Assert-Equal $s['schemas'][0]['steps'][0]['rows'].Count 0
        Assert-Equal $s['schemas'][0]['steps'][1]['rows'].Count 1
        $sql=Get-OrfRestoreSql $s['schemas'][0] @{updates=@{}} $true
        Assert-True (-not $sql.Contains('UPDATE R SET')); Assert-True ($sql.Contains('INSERT INTO I'))
    }
    Test-Case 'Duplicate and null explicit keys fail capture and delete preflight' {
        function Get-OrfLayout { New-TestLayout }
        function Get-OrfCount($Db,$Account,$Query) {
            if ($Query.Contains('GROUP BY')) { return 1 }; return 0
        }
        function Get-OrfRows { return ,@() }
        foreach ($kind in @('restoreRows','insert','update','delete','backupTable')) {
            $step=@{type=$kind;table='T';key=@('ID');match=@(@{ID=1})}
            if ($kind -eq 'restoreRows') { $step['columns']=@('V') }
            if ($kind -eq 'update') { $step['set']=@{V='new'} }
            $c=New-TestConfig @($step)
            Assert-Throws { Invoke-OrfCapture $c } 'unique and non-null'
            if ($kind -eq 'delete') { Assert-Throws { Invoke-OrfPreflight $c (New-TestSnapshot $c) } 'unique and non-null' }
        }
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
    Test-Case 'Timezone literals require canonical timestamp and signed numeric offset' {
        foreach ($bad in @('2026-09-22 12:00:00.000000000 Europe/Prague','2026-09-22 12:00:00.000000000 02:00',"2026-09-22 12:00:00.000000000 +02:00'",42)) {
            Assert-Throws { Get-OrfLiteral $bad 'TIMESTAMP WITH TIME ZONE' } 'Invalid timestamp with time zone'
        }
        Assert-Equal (Get-OrfLiteral $null 'TIMESTAMP WITH TIME ZONE') 'NULL'
    }
    Test-Case 'Unified configuration supports TNS and direct connections with validated port' {
        Assert-Equal (Get-OrfConnectIdentifier @{host='TESTDB'}) 'TESTDB'
        Assert-Equal (Get-OrfConnectIdentifier @{host='db.example.cz';port=1522;serviceName='testpdb.example.cz'}) '//db.example.cz:1522/testpdb.example.cz'
        Assert-Equal (Get-OrfConnectIdentifier @{host='localhost';serviceName='XEPDB1'}) '//localhost:1521/XEPDB1'
        Assert-Equal (Get-OrfConnectIdentifier @{host='//localhost:1521/XEPDB1'}) '//localhost:1521/XEPDB1'
        foreach ($bad in @("TESTDB`nDELETE FROM T",'host/service as sysdba','host@other','host/service;','')) {
            Assert-Throws { Get-OrfConnectIdentifier @{host=$bad} } 'Invalid host'
        }
        foreach ($bad in @(0,65536,$true,'1521',$null)) {
            Assert-Throws { Get-OrfConnectIdentifier @{host='localhost';port=$bad;serviceName='XEPDB1'} } 'Invalid Oracle port'
        }
        Assert-Throws { Get-OrfConnectIdentifier @{host='TESTDB';port=1521} } 'serviceName is required'
        Assert-Throws { Get-OrfConnectIdentifier @{host='localhost';serviceName="XEPDB1`nexit"} } 'Invalid serviceName'
    }
    Test-Case 'Unified config excludes secrets from fingerprint and binds port and service' {
        $c=New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'})
        Assert-True (-not (Test-Path (Join-Path $c.Root 'config/credentials.json')))
        Assert-True (-not $c.Database.Contains('users'))
        $path=Join-Path $c.Root 'config/database.json'; $raw=Read-OrfJson $path
        $raw['users']['APP']['password']='rotated-password'; Write-OrfText $path (ConvertTo-OrfJson $raw)
        Assert-Equal (Get-OrfConfiguration $c.Root).Hash $c.Hash
        $raw['host']='localhost'; $raw['port']=1521; $raw['serviceName']='XEPDB1'; Write-OrfText $path (ConvertTo-OrfJson $raw)
        $first=Get-OrfConfiguration $c.Root
        $raw['port']=1522; Write-OrfText $path (ConvertTo-OrfJson $raw)
        Assert-True ((Get-OrfConfiguration $c.Root).Hash -cne $first.Hash)
        $raw['port']=1521; $raw['serviceName']='OTHER'; Write-OrfText $path (ConvertTo-OrfJson $raw)
        Assert-True ((Get-OrfConfiguration $c.Root).Hash -cne $first.Hash)
    }
    Test-Case 'SQLPlus credentials via stdin and same-session account guard' {
        function Invoke-OrfProcess($Executable,$Arguments,$InputText,$TimeoutSeconds) {
            Assert-Equal $Arguments '-L -S /nolog'
            Assert-True ($InputText.IndexOf('set define off') -lt $InputText.IndexOf('connect '))
            Assert-True ($InputText.IndexOf('SESSION_USER') -lt $InputText.IndexOf('DELETE FROM T'))
            Assert-True (-not $InputText.Contains('DB_UNIQUE_NAME'))
            Assert-True ($InputText.Contains('@//localhost:1522/XEPDB1'))
            Assert-True ($InputText.EndsWith("exit rollback`n"))
            return @{ExitCode=0;Output='ok'}
        }
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'})
        $c.Database['host']='localhost'; $c.Database['port']=1522; $c.Database['serviceName']='XEPDB1'
        Assert-Equal (Invoke-OrfSqlPlus $c.Database $c.Schemas[0] 'DELETE FROM T;') 'ok'
    }
    Test-Case 'Native errors do not disclose credentials or row values' {
        function Invoke-OrfProcess { @{ExitCode=1;Output="ORA-20010: secret&password private-data`n"} }
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'})
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
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'})
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
        $steps = @(@{type='restoreRows';table='R';key=@('ID');columns=@('V');allRows=$true},@{type='replaceTable';allRows=$true;table='EMPTY'},
            @{type='update';table='U';key=@('ID');allRows=$true;set=@{V='target'}},@{type='delete';table='D';key=@('ID');match=@(@{ID=1})})
        $c = New-TestConfig $steps; $path = Invoke-OrfCapture $c; $snap = Read-OrfSnapshot $path $c
        Assert-Equal $snap['schemas'][0]['steps'].Count 4
        Assert-Equal $snap['schemas'][0]['steps'][1]['rows'].Count 0
        Assert-True ((Get-OrfRestoreSql $snap['schemas'][0] @{updates=@{'2'=@{rows=@(@{ID='1'})}}} $false).Contains('DELETE FROM EMPTY;'))
    }
    Test-Case 'Failed capture never leaves a successful snapshot' {
        function Get-OrfLayout { throw 'simulated capture failure' }
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'})
        Assert-Throws { Invoke-OrfCapture $c } 'simulated'
        $path = @(Get-ChildItem -LiteralPath (Join-Path $c.Root 'snapshots') -Recurse -Filter snapshot.json)[0].FullName
        Assert-Equal (Read-OrfJson $path)['status'] 'FAILED'
        Assert-Throws { Read-OrfSnapshot $path $c } 'Incomplete'
    }
    Test-Case 'All old snapshot versions rejected before database work' {
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'}); $snap = New-TestSnapshot $c
        foreach ($version in @(1,2,3)) {
            $snap['version']=$version; Write-OrfSnapshot $c.Root $snap
            Assert-Throws { Read-OrfSnapshot (Join-Path $c.Root 'snapshot.json') $c } 'version 4'
        }
    }
    Test-Case 'Changing configuration invalidates an existing snapshot' {
        $c=New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'}); $s=New-TestSnapshot $c
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
        function Invoke-OrfSqlPlus($Db,$Account,$Sql) { Assert-True ($Sql.Contains('all_constraints')); Assert-True (-not $Sql.Contains('dba_constraints')); return '' }
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='USERS'},@{type='replaceTable';allRows=$true;table='USERGROUPS'})
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
    Test-Case 'FK parent-child accepted and visible external reference rejected' {
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='USERS'},@{type='replaceTable';allRows=$true;table='USERGROUPS'}); $s = New-TestSnapshot $c
        function Invoke-OrfSqlPlus { "FK|APP|USERGROUPS|USERS`n" }
        Assert-OrfDependencies $c.Database $c.Schemas[0] $s['schemas'][0]
        function Invoke-OrfSqlPlus { "FK|OTHER|USERGROUPS|USERS`n" }
        Assert-Throws { Assert-OrfDependencies $c.Database $c.Schemas[0] $s['schemas'][0] } 'FK requires'
    }
    Test-Case 'FK unconfigured children self references and reversed order rejected' {
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='USERS'},@{type='replaceTable';allRows=$true;table='USERGROUPS'}); $s = New-TestSnapshot $c
        foreach ($line in @('FK|APP|OTHER_CHILD|USERS','FK|APP|USERS|USERS','FK|APP|USERS|USERGROUPS')) {
            function Invoke-OrfSqlPlus { return $line }
            Assert-Throws { Assert-OrfDependencies $c.Database $c.Schemas[0] $s['schemas'][0] } 'FK requires'
        }
    }
    Test-Case 'Layout narrowing stops preflight before writes' {
        function Get-OrfLayout { $l=New-TestLayout; $l['V']['chars']=20; return $l }
        function Invoke-OrfSqlPlus { throw 'unexpected database write' }
        $c = New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'}); $s = New-TestSnapshot $c
        Assert-Throws { Invoke-OrfPreflight $c $s } 'layout changed'
    }
    Test-Case 'Identity columns and enabled triggers block preflight' {
        function Get-OrfLayout { $l=New-TestLayout; $l['ID']['identity']='YES'; return $l }
        function Get-OrfCount { 0 }; function Invoke-OrfSqlPlus { '' }
        $c=New-TestConfig @(@{type='replaceTable';allRows=$true;table='T'}); $s=New-TestSnapshot $c
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
        $c=New-TestConfig @(@{type='update';table='T';key=@('ID');allRows=$true;set=@{V='A'}},@{type='update';table='T';key=@('ID');allRows=$true;set=@{V='B'}})
        $s=New-TestSnapshot $c; Assert-Throws { Invoke-OrfPreflight $c $s } 'overlapping'
    }
    Test-Case 'DELETE that would remove an UPDATE row is rejected' {
        function Get-OrfLayout { New-TestLayout }; function Invoke-OrfSqlPlus { '' }
        function Get-OrfRows { return ,@([ordered]@{ID='1'}) }
        function Get-OrfCount($Db,$Account,$Query) { if ($Query.Contains('WHERE ID = 1 AND')) { return 1 }; return 0 }
        $c=New-TestConfig @(@{type='update';table='T';key=@('ID');allRows=$true;set=@{V='A'}},@{type='delete';table='T';key=@('ID');match=@(@{ID=1})})
        $s=New-TestSnapshot $c; Assert-Throws { Invoke-OrfPreflight $c $s } 'overlaps'
    }
    Test-Case 'DELETE allRows has no key or row ceiling and validates empty table' {
        $c=New-TestConfig @(@{type='delete';table='T';allRows=$true}); $s=New-TestSnapshot $c
        $sql=Get-OrfRestoreSql $s['schemas'][0] @{updates=@{}} $true
        Assert-True ($sql.Contains('DELETE FROM T;'))
        Assert-True ($sql.Contains('SELECT 1 FROM T WHERE 1=1'))
        Assert-True (-not $sql.Contains('SQL%ROWCOUNT >'))
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
        Assert-True ($sql.Contains('SESSION_USER')) 'Account guard missing'
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
        $c = New-TestConfig @(@{type='update';table='T';key=@('ID');match=@(@{ID=42});set=@{V='TEST'}})
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
    Test-Case 'Empty UPDATE selection is planned and remains valid on retry' {
        function Get-OrfLayout { New-TestLayout }; function Get-OrfCount { 0 }; function Invoke-OrfSqlPlus { '' }
        function Get-OrfRows { return ,@() }
        $c=New-TestConfig @(@{type='update';table='T';key=@('ID');match=@(@{ID=99});set=@{V='x'}}); $s=New-TestSnapshot $c
        $plan=Invoke-OrfPreflight $c $s
        Assert-Equal $plan['schemas'][0]['updates']['0']['rows'].Count 0
        $sql=Get-OrfRestoreSql $s['schemas'][0] $plan['schemas'][0] $true
        Assert-True (-not $sql.Contains('UPDATE T SET'))
    }
    Test-Case 'Separate UPDATE validation requires saved plan' {
        function Get-OrfLayout { New-TestLayout }
        $c=New-TestConfig @(@{type='update';table='T';key=@('ID');allRows=$true;set=@{V='x'}}); $s=New-TestSnapshot $c
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
