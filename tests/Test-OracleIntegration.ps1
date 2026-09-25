#requires -Version 5.1
param([string]$Config = $env:ORACLE_REFRESH_INTEGRATION_CONFIG, [string]$Scenario = '*')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/OracleRefresh.ps1"
if (-not $Config) { Write-Host 'SKIP: 10 Oracle integration scenarios; set ORACLE_REFRESH_INTEGRATION_CONFIG for a disposable ORF_TEST_* schema.'; exit 0 }
$settings = Read-OrfJson ([IO.Path]::GetFullPath($Config))
$db = Copy-OrfValue $settings
if ($db['schemaOrder'].Count -ne 1) { throw 'Integration config requires exactly one disposable schema' }
$account = $db['users'][$db['schemaOrder'][0]]
$db.Remove('users')
$user = Get-OrfIdentifier $account['username']
if (-not $user.StartsWith('ORF_TEST_', [StringComparison]::Ordinal)) { throw 'Integration account must be a disposable ORF_TEST_* schema' }
if (-not $db.Contains('sqlplusPath')) { $db['sqlplusPath']='sqlplus.exe' }
if (-not $db.Contains('timeoutSeconds')) { $db['timeoutSeconds']=300 }
$db['schemaOrder']=@($user)
$script:IntegrationFailures=@()
$script:IntegrationCount=0

function Assert-Integration($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-FixtureSql([string]$Sql) { $null = Invoke-OrfSqlPlus $db $account ($Sql + "`n") }
function Initialize-OracleFixture($Fixture) {
    $prefix = 'ORF_' + [guid]::NewGuid().ToString('N').Substring(0,8).ToUpperInvariant()
    $Fixture.Parent=$prefix+'_P'; $Fixture.Child=$prefix+'_C'; $Fixture.Settings=$prefix+'_V'; $Fixture.Fixed=$prefix+'_F'; $Fixture.Check=$prefix+'_CHECK'
    $Fixture.Insert=$prefix+'_I'
    $Fixture.Root = Join-Path ([IO.Path]::GetTempPath()) ('orf-ps-integration-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Fixture.Root 'config/schemas'))
    $Fixture.Text = "Příliš žluťoučký kůň`n`n/`nO'Brien & čaj`r`nkonec"
    $definitions = @(
        @($Fixture.Parent,'ID NUMBER PRIMARY KEY, V VARCHAR2(100 CHAR)'),
        @($Fixture.Child,"ID NUMBER PRIMARY KEY, PID NUMBER REFERENCES $($Fixture.Parent)(ID), V VARCHAR2(100 CHAR)"),
        @($Fixture.Settings,'ID NUMBER PRIMARY KEY, V VARCHAR2(100 CHAR), NV NVARCHAR2(100), AMOUNT NUMBER(12,2), D DATE, TS TIMESTAMP(9), TZ TIMESTAMP(9) WITH TIME ZONE'),
        @($Fixture.Fixed,'ID NUMBER PRIMARY KEY, STATE VARCHAR2(20), V VARCHAR2(100 CHAR), NVAL VARCHAR2(20)'),
        @($Fixture.Insert,'ID NUMBER PRIMARY KEY, SOURCE VARCHAR2(20), STATUS VARCHAR2(20), V VARCHAR2(100 CHAR), NV NVARCHAR2(100), AMOUNT NUMBER(12,2), D DATE, TS TIMESTAMP(9), TZ TIMESTAMP(9) WITH TIME ZONE'))
    foreach ($definition in $definitions) {
        Invoke-FixtureSql "CREATE TABLE $($definition[0]) ($($definition[1]));"
        $Fixture.Created += $definition[0]
    }
    Invoke-FixtureSql @"
INSERT INTO $($Fixture.Parent) VALUES (1, 'test');
INSERT INTO $($Fixture.Child) VALUES (1, 1, 'test');
INSERT INTO $($Fixture.Fixed) VALUES (1, 'TEST', 't', NULL);
INSERT INTO $($Fixture.Fixed) VALUES (2, 'PROD', 't', 'old');
INSERT INTO $($Fixture.Fixed) VALUES (3, 'DELETE', 't', NULL);
INSERT INTO $($Fixture.Settings) VALUES (1, $(Get-OrfLiteral $Fixture.Text 'VARCHAR2'), $(Get-OrfLiteral 'Žluťoučký 漢字' 'NVARCHAR2'), 1234567890.12,
TO_DATE('2026-09-22 14:35:02', 'YYYY-MM-DD HH24:MI:SS'),
TO_TIMESTAMP('2026-09-22 14:35:02.123456789', 'YYYY-MM-DD HH24:MI:SS.FF9'),
TO_TIMESTAMP_TZ('2026-09-22 14:35:02.123456789 +02:00', 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM'));
INSERT INTO $($Fixture.Insert) SELECT ID, 'PROD', 'PENDING', V, NV, AMOUNT, D, TS, TZ FROM $($Fixture.Settings);
INSERT INTO $($Fixture.Insert) (ID, SOURCE, STATUS, V) VALUES (2, 'TEST', 'PENDING', 'excluded');
COMMIT;
"@
    $steps = @(
        @{type='replaceTable';allRows=$true;table=$Fixture.Parent}, @{type='replaceTable';allRows=$true;table=$Fixture.Child},
        @{type='restoreRows';table=$Fixture.Settings;key=@('ID');columns=@('V','NV','AMOUNT','D','TS','TZ');allRows=$true},
        @{type='insert';table=$Fixture.Insert;key=@('ID');match=@(@{ID=1})},
        @{type='update';table=$Fixture.Fixed;key=@('ID');match=@(@{ID=1});set=@{STATE='TEST';V=$Fixture.Text;NVAL=$null}},
        @{type='update';table=$Fixture.Fixed;key=@('ID');match=@(@{ID=2});set=@{STATE='TEST';V='Český text'}},
        @{type='delete';table=$Fixture.Fixed;key=@('ID');match=@(@{ID=3})})
    $users = [ordered]@{}; $users[$user]=$account
    $connection = Copy-OrfValue $db; $connection['users']=$users
    Write-OrfText (Join-Path $Fixture.Root 'config/database.json') (ConvertTo-OrfJson $connection)
    Write-OrfText (Join-Path $Fixture.Root "config/schemas/$user.json") (ConvertTo-OrfJson @{steps=$steps})
    $Fixture.Configuration=Get-OrfConfiguration $Fixture.Root
    $Fixture.Path=Invoke-OrfCapture $Fixture.Configuration
    $Fixture.Snapshot=Read-OrfSnapshot $Fixture.Path $Fixture.Configuration
    $Fixture.State=Join-Path (Split-Path -Parent $Fixture.Path) 'restore-plan.json'
    Invoke-FixtureSql @"
DELETE FROM $($Fixture.Child);
DELETE FROM $($Fixture.Parent);
INSERT INTO $($Fixture.Parent) VALUES (2, 'prod');
INSERT INTO $($Fixture.Child) VALUES (2, 2, 'prod');
UPDATE $($Fixture.Settings) SET V='prod', NV=NULL, AMOUNT=0, D=NULL, TS=NULL, TZ=NULL;
UPDATE $($Fixture.Fixed) SET V='p', NVAL='prod';
DELETE FROM $($Fixture.Insert) WHERE ID=1;
UPDATE $($Fixture.Insert) SET V='keep after refresh' WHERE ID=2;
INSERT INTO $($Fixture.Insert) (ID, SOURCE, STATUS, V) VALUES (3, 'PROD', 'PENDING', 'new after refresh');
COMMIT;
"@
}

function Test-Integration([string]$Name, [scriptblock]$Body) {
    if ($Name -notlike $Scenario) { return }
    $script:IntegrationCount++
    $fixture = @{Created=@()}
    try { Initialize-OracleFixture $fixture; & $Body $fixture; Write-Host "PASS $Name" }
    catch { $script:IntegrationFailures += $Name; Write-Host "FAIL $Name : $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
    finally {
        for ($i=$fixture.Created.Count-1; $i -ge 0; $i--) {
            try { Invoke-FixtureSql "DROP TABLE $($fixture.Created[$i]) PURGE;" }
            catch { $script:IntegrationFailures += "$Name cleanup"; Write-Host "Cleanup failed for $($fixture.Created[$i])" }
        }
        if ($fixture.Root) {
            $resolved=[IO.Path]::GetFullPath($fixture.Root); $base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            if (-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^orf-ps-integration-[a-f0-9]{32}$') { throw 'Unsafe integration cleanup path' }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

Test-Integration 'Unicode NULL numbers timestamps FK and repeated restore' {
    param($f)
    $insertStep=@($f.Snapshot['schemas'][0]['steps'] | Where-Object { $_['type'] -eq 'insert' })[0]
    Assert-Integration ($insertStep['rows'].Count -eq 1) 'INSERT filter captured wrong rows'
    Assert-Integration ($insertStep['key'][0] -eq 'ID') 'Explicit key not preserved'
    $insertFile=Join-Path (Split-Path -Parent $f.Path) ($user+'/'+$f.Insert+'.insert.sql')
    $manual=[IO.File]::ReadAllText($insertFile)
    Assert-Integration (([regex]::Matches($manual,'INSERT INTO').Count) -eq 1) 'Filtered SQL export contains extra rows'
    $null=Invoke-OrfSqlPlus $db $account ($manual+"`nDECLARE v_count NUMBER; BEGIN`n"+(Get-OrfInsertChecks $insertStep)+"`nEND;`n/`nROLLBACK;`n")
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Insert) WHERE ID=1") -eq 0) 'Manual export committed automatically'
    $null=Invoke-OrfPreflight $f.Configuration $f.Snapshot $f.State
    Assert-Integration (-not (Test-Path -LiteralPath $f.State)) 'Preflight wrote a plan'
    Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State
    Invoke-OrfValidate $f.Configuration $f.Snapshot $f.State
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Insert)") -eq 3) 'INSERT retry duplicated rows'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Insert) WHERE ID=2 AND V='keep after refresh'") -eq 1) 'INSERT changed excluded row'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Insert) WHERE ID=3 AND V='new after refresh'") -eq 1) 'INSERT changed new matching row'
    Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State
    Invoke-OrfValidate $f.Configuration $f.Snapshot $f.State
    $types=Get-OrfTypes (Get-OrfLayout $db $account $f.Settings)
    $rows=Get-OrfRows $db $account $f.Settings $types
    Assert-Integration ($rows[0]['V'] -ceq $f.Text) 'Multiline data changed'
    Assert-Integration ($rows[0]['NV'] -ceq 'Žluťoučký 漢字') 'National characters changed'
    Assert-Integration ($rows[0]['AMOUNT'] -ceq '1234567890.12') 'NUMBER precision changed'
    Assert-Integration ($rows[0]['TZ'] -ceq '2026-09-22 14:35:02.123456789 +02:00') 'Timestamp offset or precision changed'
    foreach ($offset in @('+00:00','-03:30','+05:45')) {
        $value='2026-09-22 14:35:02.123456789 '+$offset
        $expression=Get-OrfExpression (Get-OrfLiteral $value 'TIMESTAMP WITH TIME ZONE') 'TIMESTAMP WITH TIME ZONE'
        $actual=Invoke-OrfSqlPlus $db $account "SELECT $expression FROM dual;`n"
        Assert-Integration ($actual.Trim() -ceq $value) 'Timestamp literal round trip changed offset or precision'
    }
}
Test-Integration 'Late CHECK violation rolls back all tables and retry succeeds' {
    param($f)
    Invoke-FixtureSql "ALTER TABLE $($f.Fixed) ADD CONSTRAINT $($f.Check) CHECK (LENGTH(V) <= 1);"
    $caught=$false
    try { Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State }
    catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'ORA-02290') 'Expected the late CHECK constraint error' }
    Assert-Integration $caught 'Expected restore failure'
    Assert-Integration (Test-Path -LiteralPath $f.State) 'Plan was not persisted before writes'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Parent) WHERE ID=2") -eq 1) 'Parent replacement did not roll back'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Child) WHERE ID=2") -eq 1) 'Child replacement did not roll back'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Settings) WHERE V='prod'") -eq 1) 'restoreRows did not roll back'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Insert) WHERE ID=1") -eq 0) 'INSERT did not roll back'
    Invoke-FixtureSql "ALTER TABLE $($f.Fixed) DROP CONSTRAINT $($f.Check);"
    Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State
    Invoke-OrfValidate $f.Configuration $f.Snapshot $f.State
}
Test-Integration 'Missing restore keys are skipped and extra rows preserved' {
    param($f)
    Invoke-FixtureSql "UPDATE $($f.Settings) SET ID=999, V='extra';`nCOMMIT;"
    Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State
    Invoke-OrfValidate $f.Configuration $f.Snapshot $f.State
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Settings) WHERE ID=999 AND V='extra'") -eq 1) 'Extra row changed'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Settings)") -eq 1) 'Missing row was inserted'
    $reports=@(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $f.State) 'recovery') -Recurse -Filter '*.skipped-updates.json')
    Assert-Integration ($reports.Count -eq 1) 'Missing skip report'
    $skipped=Read-OrfJson $reports[0].FullName
    Assert-Integration ($skipped.Count -eq 1 -and $skipped[0]['table'] -eq $f.Settings) 'Wrong skipped row'
    $scripts=@(Get-ChildItem -LiteralPath $reports[0].DirectoryName -Filter '*.missing-rows.insert.sql')
    Assert-Integration ($scripts.Count -eq 1) 'Missing recovery INSERT script'
}
Test-Integration 'Changed column length blocks before replacement' {
    param($f)
    Invoke-FixtureSql "ALTER TABLE $($f.Settings) MODIFY V VARCHAR2(50 CHAR);"
    $caught=$false; try { Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State } catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'layout changed') 'Wrong layout error' }
    Assert-Integration $caught 'Expected layout failure'; Assert-Integration (-not (Test-Path -LiteralPath $f.State)) 'Restore wrote a plan'
}
Test-Integration 'Wrong account assertion rejected before query' {
    param($f)
    $guard=Get-OrfAccountGuard @{username='INTENTIONALLY_WRONG'}
    $caught=$false; try { $null=Invoke-OrfSqlPlus $db $account ($guard+"SELECT 1 FROM dual;`n") } catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'ORA-20010') 'Wrong account guard error' }
    Assert-Integration $caught 'Expected account failure'
}
Test-Integration 'DELETE removes only explicit keys and preserves other rows' {
    param($f)
    Invoke-FixtureSql "INSERT INTO $($f.Fixed) VALUES (4, 'DELETE', 'p', NULL);`nCOMMIT;"
    Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State
    Invoke-OrfValidate $f.Configuration $f.Snapshot $f.State
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Fixed) WHERE ID=3") -eq 0) 'Explicit delete key remains'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Fixed) WHERE ID=4") -eq 1) 'Unselected delete row changed'
}
Test-Integration 'Unconfigured cascading child blocks replacement without deleting data' {
    param($f)
    $child=$f.Parent+'_EXT'
    Invoke-FixtureSql "CREATE TABLE $child (ID NUMBER PRIMARY KEY, PID NUMBER REFERENCES $($f.Parent)(ID) ON DELETE CASCADE);"
    $f.Created += $child
    Invoke-FixtureSql "INSERT INTO $child VALUES (1, 2);`nCOMMIT;"
    $caught=$false
    try { Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State }
    catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'FK requires') 'Expected FK preflight error' }
    Assert-Integration $caught 'Expected unconfigured child rejection'
    Assert-Integration (-not (Test-Path -LiteralPath $f.State)) 'Restore wrote a plan'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $child WHERE PID=2") -eq 1) 'Cascading child changed'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Parent) WHERE ID=2") -eq 1) 'Parent changed'
}
Test-Integration 'INSERT conflicting key blocks all writes and retry succeeds after correction' {
    param($f)
    Invoke-FixtureSql "INSERT INTO $($f.Insert) (ID, SOURCE, STATUS, V) VALUES (1, 'PROD', 'PENDING', 'conflict');`nCOMMIT;"
    $caught=$false
    try { Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State }
    catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'ORA-20012') 'Expected INSERT value conflict' }
    Assert-Integration $caught 'Conflicting insert key was accepted'
    Assert-Integration (-not (Test-Path -LiteralPath $f.State)) 'Conflict persisted a plan'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Parent) WHERE ID=2") -eq 1) 'Conflict changed earlier table'
    Invoke-FixtureSql "DELETE FROM $($f.Insert) WHERE ID=1;`nCOMMIT;"
    Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State
    Invoke-OrfValidate $f.Configuration $f.Snapshot $f.State
}
Test-Integration 'Unified variants with composite keys and allRows' {
    param($f)
    $composite=$f.Parent+'_KEYS'
    Invoke-FixtureSql "CREATE TABLE $composite (TENANT_ID NUMBER, CONFIG_KEY VARCHAR2(30), V VARCHAR2(100));"
    $f.Created += $composite
    Invoke-FixtureSql @"
INSERT INTO $composite VALUES (10, 'API_URL', 'test10');
INSERT INTO $composite VALUES (20, 'API_URL', 'test20');
INSERT INTO $composite VALUES (30, 'API_URL', 'test30');
COMMIT;
"@
    $steps=@(
        @{type='backupTable';table=$f.Parent;key=@('ID');match=@(@{ID=2})},
        @{type='restoreRows';table=$composite;key=@('TENANT_ID','CONFIG_KEY');match=@(@{TENANT_ID=10;CONFIG_KEY='API_URL'},@{TENANT_ID=20;CONFIG_KEY='API_URL'});columns=@('V')},
        @{type='insert';table=$f.Insert;key=@('ID');allRows=$true},
        @{type='update';table=$f.Fixed;key=@('ID');allRows=$true;set=@{STATE='TEST'}},
        @{type='delete';table=$f.Settings;allRows=$true})
    Write-OrfText (Join-Path $f.Root "config/schemas/$user.json") (ConvertTo-OrfJson @{steps=$steps})
    $config=Get-OrfConfiguration $f.Root
    $path=Invoke-OrfCapture $config; $snapshot=Read-OrfSnapshot $path $config
    $state=Join-Path (Split-Path -Parent $path) 'restore-plan.json'
    Assert-Integration ($snapshot['schemas'][0]['steps'][1]['rows'].Count -eq 2) 'Composite capture selected wrong rows'
    $csv=@(Import-Csv -LiteralPath (Join-Path (Split-Path -Parent $path) "$user/$($f.Parent).csv"))
    Assert-Integration ($csv.Count -eq 1 -and $csv[0].ID -eq '2') 'Key-filtered backup selected wrong rows'
    Invoke-FixtureSql @"
UPDATE $composite SET V='refreshed';
DELETE FROM $composite WHERE TENANT_ID=20;
DELETE FROM $($f.Insert) WHERE ID=2;
COMMIT;
"@
    Invoke-OrfRestore $config $snapshot $state
    Invoke-OrfValidate $config $snapshot $state
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $composite WHERE TENANT_ID=10 AND V='test10'") -eq 1) 'Composite restore did not restore original value'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $composite WHERE TENANT_ID=30 AND V='refreshed'") -eq 1) 'Composite restore changed an unselected row'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $composite WHERE TENANT_ID=20") -eq 0) 'Missing composite key was inserted'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Insert) WHERE ID=2") -eq 1) 'AllRows insert did not restore missing row'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Fixed) WHERE STATE='TEST'") -eq 3) 'AllRows update missed rows'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Settings)") -eq 0) 'AllRows delete left rows'
    Invoke-FixtureSql "INSERT INTO $($f.Settings) (ID,V) VALUES (999,'new');`nCOMMIT;"
    Invoke-OrfRestore $config $snapshot $state
    Invoke-OrfValidate $config $snapshot $state
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($f.Settings)") -eq 0) 'Repeated allRows delete kept a new row'
}
Test-Integration 'Scoped unique keys and nonunique group operations' {
    param($f)
    $names=@{}
    foreach ($kind in @('R','I','U','D','B')) {
        $table=$f.Parent+'_'+$kind; $names[$kind]=$table
        Invoke-FixtureSql "CREATE TABLE $table (ID NUMBER, V VARCHAR2(100));"
        $f.Created += $table
        Invoke-FixtureSql "INSERT INTO $table VALUES (1,'original');`nINSERT INTO $table VALUES (2,'a');`nINSERT INTO $table VALUES (2,'b');`nINSERT INTO $table VALUES (NULL,'null key');`nCOMMIT;"
    }
    $steps=@(
        @{type='restoreRows';table=$names.R;key=@('ID');match=@(@{ID=1});columns=@('V')},
        @{type='insert';table=$names.I;key=@('ID');match=@(@{ID=1})},
        @{type='update';table=$names.U;key=@('ID');match=@(@{ID=2},@{ID=$null});set=@{V='updated'}},
        @{type='delete';table=$names.D;key=@('ID');match=@(@{ID=2},@{ID=$null})},
        @{type='backupTable';table=$names.B;key=@('ID');match=@(@{ID=2},@{ID=$null})})
    $configPath=Join-Path $f.Root "config/schemas/$user.json"
    Write-OrfText $configPath (ConvertTo-OrfJson @{steps=$steps})
    $config=Get-OrfConfiguration $f.Root
    $path=Invoke-OrfCapture $config; $snapshot=Read-OrfSnapshot $path $config
    $state=Join-Path (Split-Path -Parent $path) 'restore-plan.json'
    $csv=@(Import-Csv -LiteralPath (Join-Path (Split-Path -Parent $path) "$user/$($names.B).csv"))
    Assert-Integration ($csv.Count -eq 3) 'Nonunique backup lost rows'
    Invoke-FixtureSql "UPDATE $($names.R) SET V='refreshed' WHERE ID=1;`nDELETE FROM $($names.I) WHERE ID=1;`nCOMMIT;"
    for ($run=0; $run -lt 2; $run++) {
        Invoke-OrfRestore $config $snapshot $state
        Invoke-OrfValidate $config $snapshot $state
    }
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($names.U) WHERE V='updated'") -eq 3) 'UPDATE did not change every matching row'
    Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($names.D)") -eq 1) 'DELETE did not remove every matching row'
    foreach ($kind in @('R','I')) {
        Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($names[$kind]) WHERE ID=1 AND V='original'") -eq 1) 'Selected unique key was not restored'
        Assert-Integration ((Get-OrfCount $db $account "SELECT COUNT(*) FROM $($names[$kind]) WHERE ID=2") -eq 2) 'Unselected duplicates changed'
    }
    Invoke-FixtureSql "INSERT INTO $($names.U) VALUES (2,'extra');`nCOMMIT;"
    $caught=$false
    try { $null=Invoke-OrfPreflight $config $snapshot $state } catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'group count changed') 'Wrong changed-group error' }
    Assert-Integration $caught 'Changed UPDATE group was accepted'
    Invoke-FixtureSql "DELETE FROM $($names.U) WHERE V='extra';`nINSERT INTO $($names.R) VALUES (1,'duplicate');`nCOMMIT;"
    $caught=$false
    try { $null=Invoke-OrfPreflight $config $snapshot $state } catch { $caught=$true }
    Assert-Integration $caught 'Duplicate selected restore key accepted'
    $caught=$false
    try { $null=Invoke-OrfCapture $config } catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'unique and non-null') 'Wrong selected-key error' }
    Assert-Integration $caught 'Capture accepted duplicate selected key'
    $all=@{type='restoreRows';table=$names.I;key=@('ID');allRows=$true;columns=@('V')}
    Write-OrfText $configPath (ConvertTo-OrfJson @{steps=@($all)})
    $caught=$false
    try { $null=Invoke-OrfCapture (Get-OrfConfiguration $f.Root) } catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'unique and non-null') 'Wrong allRows key error' }
    Assert-Integration $caught 'AllRows accepted duplicate/null keys'
}
if ($script:IntegrationCount -eq 0) { throw 'No integration scenario matched' }
if ($script:IntegrationFailures.Count -gt 0) { throw "$($script:IntegrationFailures.Count) integration failures" }
Write-Host "$script:IntegrationCount/$script:IntegrationCount Oracle integration scenarios passed"
