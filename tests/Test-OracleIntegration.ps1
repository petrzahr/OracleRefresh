#requires -Version 5.1
param([string]$Config = $env:ORACLE_REFRESH_INTEGRATION_CONFIG)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/OracleRefresh.ps1"
if (-not $Config) { Write-Host 'SKIP: 8 Oracle integration scenarios; set ORACLE_REFRESH_INTEGRATION_CONFIG for a disposable ORF_TEST_* schema.'; exit 0 }
$settings = Read-OrfJson ([IO.Path]::GetFullPath($Config))
$account = $settings['account']; $db = $settings['database']
$user = Get-OrfIdentifier $account['username']
if (-not $user.StartsWith('ORF_TEST_', [StringComparison]::Ordinal)) { throw 'Integration account must be a disposable ORF_TEST_* schema' }
if (-not $db.Contains('sqlplusPath')) { $db['sqlplusPath']='sqlplus.exe' }
if (-not $db.Contains('timeoutSeconds')) { $db['timeoutSeconds']=300 }
$db['schemaOrder']=@($user)
$script:IntegrationFailures=@()

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
        @{type='replaceTable';table=$Fixture.Parent}, @{type='replaceTable';table=$Fixture.Child},
        @{type='restoreRows';table=$Fixture.Settings;key=@('ID');columns=@('V','NV','AMOUNT','D','TS','TZ');allRows=$true},
        @{type='insert';table=$Fixture.Insert;match=@{SOURCE='PROD';STATUS='PENDING'};maxInsertRows=10;expectedRows=1},
        @{type='update';table=$Fixture.Fixed;key=@('ID');match=@{STATE='TEST'};set=@{STATE='TEST';V=$Fixture.Text;NVAL=$null};expectedRows=1},
        @{type='update';table=$Fixture.Fixed;key=@('ID');match=@{STATE='PROD'};set=@{STATE='TEST';V='Český text'};expectedRows=1},
        @{type='delete';table=$Fixture.Fixed;match=@{STATE='DELETE'};maxDeleteRows=1})
    Write-OrfText (Join-Path $Fixture.Root 'config/database.json') (ConvertTo-OrfJson $db)
    $users = [ordered]@{}; $users[$user]=$account
    Write-OrfText (Join-Path $Fixture.Root 'config/credentials.json') (ConvertTo-OrfJson @{users=$users})
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
    Assert-Integration ($insertStep['key'][0] -eq 'ID') 'Primary key not discovered'
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
Test-Integration 'Wrong PDB rejected before query' {
    param($f)
    $wrong=Copy-OrfValue $db; $wrong['expectedTarget']['conName']='INTENTIONALLY_WRONG'
    $caught=$false; try { $null=Invoke-OrfSqlPlus $wrong $account "SELECT 1 FROM dual;`n" } catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'ORA-20010') 'Wrong target guard error' }
    Assert-Integration $caught 'Expected target failure'
}
Test-Integration 'Filtered DELETE ceiling blocks before any write' {
    param($f)
    Invoke-FixtureSql "INSERT INTO $($f.Fixed) VALUES (4, 'DELETE', 'p', NULL);`nCOMMIT;"
    $caught=$false; try { Invoke-OrfRestore $f.Configuration $f.Snapshot $f.State } catch { $caught=$true; Assert-Integration ($_.Exception.Message -match 'maxDeleteRows') 'Wrong delete limit error' }
    Assert-Integration $caught 'Expected delete limit failure'; Assert-Integration (-not (Test-Path -LiteralPath $f.State)) 'Restore wrote a plan'
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
if ($script:IntegrationFailures.Count -gt 0) { throw "$($script:IntegrationFailures.Count) integration failures" }
Write-Host '8/8 Oracle integration scenarios passed'
