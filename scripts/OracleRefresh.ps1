#requires -Version 5.1
# Shared implementation. Dot-source from the four public entry points.
$script:OrfUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:OrfKinds = @('restoreRows', 'replaceTable', 'update', 'delete', 'insert', 'backupTable')

function ConvertTo-OrfMap($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($property in $Value.PSObject.Properties) { $result.Add($property.Name, (ConvertTo-OrfMap $property.Value)) }
        return ,$result
    }
    if ($Value -is [array]) {
        $result = @(); foreach ($item in $Value) { $result += ,(ConvertTo-OrfMap $item) }
        return ,$result
    }
    return $Value
}

function ConvertFrom-OrfJson([string]$Text) {
    # PS 5.1 keeps ISO date strings intact. Newer PS supports an explicit policy.
    $options = @{ InputObject = $Text; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
    ConvertTo-OrfMap (ConvertFrom-Json @options)
}

function ConvertTo-OrfJson($Value) {
    # Canonical, ordinal, culture-independent JSON for hashes and exact comparisons.
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) {
        $escaped = [regex]::Replace($Value, '[\x00-\x1f"\\]', {
            param($m)
            switch ([int][char]$m.Value) {
                34 { '\"'; break } 92 { '\\'; break }
                default { '\u{0:x4}' -f [int][char]$m.Value }
            }
        })
        return '"' + $escaped + '"'
    }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [System.Collections.IDictionary]) {
        [string[]]$names = @($Value.Keys); [array]::Sort($names, [StringComparer]::Ordinal)
        $parts = foreach ($name in $names) { (ConvertTo-OrfJson $name) + ':' + (ConvertTo-OrfJson $Value[$name]) }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) { ConvertTo-OrfJson $item }
        return '[' + ($parts -join ',') + ']'
    }
    if ($Value -is [ValueType] -and $Value -isnot [datetime]) {
        $number = [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($number -notmatch '^-?\d+(\.\d+)?([eE][+-]?\d+)?$') { throw 'Unsupported JSON number' }
        return $number
    }
    throw 'Unsupported JSON value'
}

function Read-OrfJson([string]$Path) { ConvertFrom-OrfJson ([IO.File]::ReadAllText($Path, $script:OrfUtf8)) }
function Write-OrfText([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $script:OrfUtf8) }
function Get-OrfHash([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Get-OrfDigest($Value) { Get-OrfHash ($script:OrfUtf8.GetBytes((ConvertTo-OrfJson $Value))) }
function Copy-OrfValue($Value) { ConvertFrom-OrfJson (ConvertTo-OrfJson $Value) }
function Test-OrfEqual($Left, $Right) { (ConvertTo-OrfJson $Left) -ceq (ConvertTo-OrfJson $Right) }

function Get-OrfIdentifier($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z][A-Za-z0-9_$#]*$') { throw 'Invalid Oracle identifier' }
    return $Value.ToUpperInvariant()
}
function Get-OrfQuoted($Value) {
    if ($Value -isnot [string] -or $Value.IndexOf([char]0) -ge 0) { throw 'Invalid SQL string' }
    return "'" + $Value.Replace("'", "''") + "'"
}
function Get-OrfType([string]$Value) { $Value -replace '^TIMESTAMP\(\d\)', 'TIMESTAMP' }
function Test-OrfInteger($Value) { $Value -is [int] -or $Value -is [long] -or $Value -is [int16] }
function Get-OrfNames($Value) {
    if ($Value -isnot [array] -or $Value.Count -eq 0) { throw 'Expected a nonempty list of column names' }
    $seen = @{}; $names = @()
    foreach ($name in $Value) {
        $id = Get-OrfIdentifier $name
        if ($seen.ContainsKey($id)) { throw 'Duplicate column name' }
        $seen[$id] = $true; $names += $id
    }
    return ,$names
}
function Get-OrfMapping($Value) {
    if ($Value -isnot [System.Collections.IDictionary] -or $Value.Count -eq 0) { throw 'Expected a nonempty column/value object' }
    $result = [ordered]@{}
    foreach ($name in $Value.Keys) {
        $id = Get-OrfIdentifier $name
        if ($result.Contains($id)) { throw 'Duplicate column name after normalization' }
        $v = $Value[$name]
        if ($null -ne $v -and $v -isnot [string] -and -not (Test-OrfInteger $v) -and $v -isnot [double] -and $v -isnot [decimal]) {
            throw 'Column values must be strings, numbers or null'
        }
        $result[$id] = $v
    }
    return ,$result
}

function Get-OrfConnectIdentifier($Db) {
    $hostValue = $Db['host']
    if ($Db.Contains('serviceName')) {
        if ($hostValue -isnot [string] -or $hostValue -notmatch '\A(?:[A-Za-z0-9_][A-Za-z0-9_.-]*|\[[0-9A-Fa-f:]+\])\z') { throw 'Invalid host name for direct connection' }
        if ($Db['serviceName'] -isnot [string] -or $Db['serviceName'] -notmatch '\A[A-Za-z0-9_][A-Za-z0-9_.$#-]*\z') { throw 'Invalid serviceName' }
        $port = 1521; if ($Db.Contains('port')) { $port = $Db['port'] }
        if (-not (Test-OrfInteger $port) -or $port -lt 1 -or $port -gt 65535) { throw 'Invalid Oracle port' }
        return ('//{0}:{1}/{2}' -f $hostValue,$port,$Db['serviceName'])
    }
    if ($Db.Contains('port')) { throw 'serviceName is required when port is specified; a TNS alias already defines its port and service' }
    if ($hostValue -isnot [string] -or $hostValue -notmatch '\A(?:[A-Za-z0-9_][A-Za-z0-9_.-]*|(?://)?(?:[A-Za-z0-9_][A-Za-z0-9_.-]*|\[[0-9A-Fa-f:]+\])(?::[0-9]{1,5})?/[A-Za-z0-9_][A-Za-z0-9_.$#-]*)\z') { throw 'Invalid host; use a TNS alias or host:port/service_name' }
    if ($hostValue -match ':([0-9]+)/' -and ([int]$Matches[1] -lt 1 -or [int]$Matches[1] -gt 65535)) { throw 'Invalid Oracle port' }
    return $hostValue
}

function Get-OrfConfiguration([string]$ProjectRoot) {
    $db = Read-OrfJson (Join-Path $ProjectRoot 'config/database.json')
    $null = Get-OrfConnectIdentifier $db
    $users = $db['users']
    if ($users -isnot [System.Collections.IDictionary] -or $users.Count -eq 0) { throw 'database.json requires a nonempty users object' }
    $db.Remove('users')
    if (-not $db.Contains('timeoutSeconds')) { $db['timeoutSeconds'] = 300 }
    if (-not (Test-OrfInteger $db['timeoutSeconds']) -or $db['timeoutSeconds'] -le 0 -or $db['timeoutSeconds'] -gt 2147483) { throw 'Invalid timeoutSeconds' }
    if (-not $db.Contains('sqlplusPath')) { $db['sqlplusPath'] = 'sqlplus.exe' }
    foreach ($legacy in @('fullTableRestoreOrder','updateOrder','deleteOrder')) {
        if ($db.Contains($legacy)) { throw 'Use schemaOrder and steps instead of legacy order fields' }
    }
    $order = Get-OrfNames $db['schemaOrder']; $db['schemaOrder'] = $order
    $files = @{}; $schemas = @(); $publicSchemas = @()
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'config/schemas') -Filter '*.json') {
        if ($file.Name.EndsWith('.example.json', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $id = Get-OrfIdentifier $file.BaseName
        if ($files.ContainsKey($id)) { throw 'Duplicate schema filename' }
        $files[$id] = $file.FullName
    }
    if ($files.Count -ne $order.Count) { throw 'schemaOrder must list every configured schema once' }
    foreach ($user in $order) {
        if (-not $files.ContainsKey($user)) { throw "Missing schema configuration: $user" }
        $raw = Read-OrfJson $files[$user]
        foreach ($forbidden in @('username','password','objects','fullTables','updates','deletes')) {
            if ($raw.Contains($forbidden)) { throw 'Schema configuration requires steps; credentials belong in database.json' }
        }
        if ($raw['steps'] -isnot [array] -or $raw['steps'].Count -eq 0) { throw 'Expected nonempty steps array' }
        $account = $users[$user]
        if ($null -eq $account -or $account['username'] -cne $user -or $account['password'] -isnot [string] -or
            $account['password'].Length -eq 0 -or $account['password'] -match '[\r\n\x00]') { throw "Invalid credentials for $user" }
        $steps = @(); $primary = @{}; $fixed = @{}; $tableKeys = @{}
        foreach ($rawStep in $raw['steps']) {
            $step = Copy-OrfValue $rawStep
            $kind = $step['type']; $table = Get-OrfIdentifier $step['table']; $step['table'] = $table
            if ($script:OrfKinds -cnotcontains $kind) { throw 'Unsupported step type' }
            $allowed = @('type','table','allRows','match')
            if ($kind -ne 'replaceTable') { $allowed += 'key' }
            if ($kind -eq 'restoreRows') { $allowed += 'columns' }
            if ($kind -eq 'update') { $allowed += 'set' }
            foreach ($field in $step.Keys) {
                if ($field -notin $allowed) { throw "Unsupported step field '$field'; use explicit key with match or allRows; keyValues and all max*/expectedRows fields were removed" }
            }
            if ($step.Contains('match') -eq $step.Contains('allRows')) { throw 'Specify exactly one of match or allRows: true' }
            if ($step.Contains('allRows') -and ($step['allRows'] -isnot [bool] -or -not $step['allRows'])) { throw 'allRows must be true' }
            $all = $step.Contains('allRows')
            if ($kind -eq 'replaceTable' -and -not $all) { throw 'replaceTable requires allRows: true' }
            $needsKey = -not $all -or $kind -in @('restoreRows','insert','update')
            if ($needsKey) { $step['key'] = Get-OrfNames $step['key'] }
            elseif ($step.Contains('key')) { throw "$kind with allRows does not use key" }
            if (-not $all) {
                if ($step['match'] -isnot [array] -or $step['match'].Count -eq 0) { throw 'match must be a nonempty array of key objects' }
                $matches = @(); $seenMatches = @{}
                foreach ($item in $step['match']) {
                    $item = Get-OrfMapping $item
                    if ($item.Count -ne $step['key'].Count) { throw 'Each match must contain exactly the key columns' }
                    foreach ($col in $step['key']) {
                        if (-not $item.Contains($col)) { throw 'Each match must contain exactly the key columns' }
                        if ($kind -in @('restoreRows','insert') -and ($null -eq $item[$col] -or ($item[$col] -is [string] -and $item[$col].Length -eq 0))) { throw 'Match key values must be non-null and nonempty' }
                    }
                    $item = Select-OrfMap $item $step['key']
                    $digest = Get-OrfDigest $item
                    if (-not $seenMatches.ContainsKey($digest)) { $matches += ,$item; $seenMatches[$digest] = $true }
                }
                $step['match'] = $matches
            }
            if ($kind -in @('replaceTable','restoreRows','insert','backupTable')) {
                if ($primary.ContainsKey($table) -or $fixed.ContainsKey($table)) { throw 'Conflicting table operations' }
                $primary[$table] = $true
            } else {
                if ($primary.ContainsKey($table)) { throw 'Conflicting table operations' }
                $fixed[$table] = $true
            }
            if ($kind -eq 'update') {
                $step['set'] = Get-OrfMapping $step['set']
                foreach ($key in $step['key']) { if ($step['set'].Contains($key)) { throw 'UPDATE cannot modify its stable key' } }
                if ($tableKeys.ContainsKey($table) -and -not (Test-OrfEqual $tableKeys[$table] $step['key'])) { throw 'UPDATE steps must use the same stable key' }
                $tableKeys[$table] = $step['key']
            }
            if ($kind -eq 'restoreRows') {
                $step['columns'] = Get-OrfNames $step['columns']
                foreach ($key in $step['key']) { if ($step['columns'] -contains $key) { throw 'Key and restored columns cannot overlap' } }
            }
            $steps += ,$step
        }
        $publicSchemas += ,([ordered]@{ username = $user; steps = $steps })
        $schemas += ,([ordered]@{ username = $user; password = $account['password']; steps = $steps })
    }
    $fingerprint = [ordered]@{ connection = (Get-OrfConnectIdentifier $db); schemaOrder = $order; schemas = $publicSchemas }
    return @{ Database = $db; Schemas = $schemas; Hash = (Get-OrfDigest $fingerprint); Root = $ProjectRoot }
}

function Get-OrfAccountGuard($Account) {
    "BEGIN IF SYS_CONTEXT('USERENV', 'SESSION_USER') <> $(Get-OrfQuoted $Account['username']) THEN RAISE_APPLICATION_ERROR(-20010, 'Connected account mismatch'); END IF; END;`n/`n"
}

function Invoke-OrfProcess([string]$Executable, [string]$Arguments, [string]$InputText, [int]$TimeoutSeconds) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable; $start.Arguments = $Arguments
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $script:OrfUtf8; $start.StandardErrorEncoding = $script:OrfUtf8
    $start.EnvironmentVariables['NLS_LANG'] = '.AL32UTF8'; $start.EnvironmentVariables['ORA_NCHAR_LITERAL_REPLACE'] = 'TRUE'
    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew(); $timeout = $TimeoutSeconds * 1000
    try {
        try { [void]$process.Start() } catch { throw 'Cannot start SQL*Plus; check sqlplusPath and PATH' }
        # Drain both pipes while writing. Use raw UTF-8 bytes: .NET Framework
        # has no ProcessStartInfo.StandardInputEncoding property.
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $bytes = $script:OrfUtf8.GetBytes($InputText)
        $write = $process.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
        if (-not $write.Wait([Math]::Max(1, $timeout - [int]$watch.ElapsedMilliseconds))) { throw 'SQL*Plus timeout' }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit([Math]::Max(1, $timeout - [int]$watch.ElapsedMilliseconds))) { throw 'SQL*Plus timeout' }
        foreach ($task in @($stdout, $stderr)) {
            if (-not $task.Wait([Math]::Max(1, $timeout - [int]$watch.ElapsedMilliseconds))) { throw 'SQL*Plus output timeout' }
        }
        return @{ ExitCode = $process.ExitCode; Output = $stdout.Result + $stderr.Result }
    } catch {
        try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } } catch { }
        # Never forward native exception text that might contain SQL or credentials.
        if ($_.Exception.Message -like '*timeout*') { throw 'SQL*Plus timeout; schema COMMIT outcome may need verification' }
        throw 'SQL*Plus process/transport failed; check executable, encoding and connection'
    } finally { $process.Dispose() }
}

function Invoke-OrfSqlPlus($Db, $Account, [string]$Sql) {
    $connectIdentifier = Get-OrfConnectIdentifier $Db
    $password = $Account['password'].Replace('"', '""')
    $header = @"
whenever oserror exit failure rollback
whenever sqlerror exit failure rollback
set define off echo off verify off
connect $($Account['username'])/"$password"@$connectIdentifier
set heading off feedback off verify off echo off define off pagesize 0 linesize 32767 trimspool on tab off
set sqlblanklines on
set serveroutput on size unlimited format wrapped
alter session set nls_numeric_characters='.,';
alter session set nls_calendar='GREGORIAN';
"@
    $inputText = $header + "`n" + (Get-OrfAccountGuard $Account) + $Sql + "`nexit rollback`n"
    $result = Invoke-OrfProcess $Db['sqlplusPath'] '-L -S /nolog' $inputText $Db['timeoutSeconds']
    $codes = @([regex]::Matches($result.Output, '(?m)^\s*((?:ORA-|SP2-|PLS-)\d+)') | ForEach-Object { $_.Groups[1].Value })
    if ($result.ExitCode -ne 0 -or $codes.Count -gt 0) { throw "SQL*Plus failed for $($Account['username']): exit $($result.ExitCode); $($codes -join ', ')" }
    return $result.Output
}

function Get-OrfLiteral($Value, [string]$Type) {
    if ($null -eq $Value) { return 'NULL' }
    if ($Type -eq 'NUMBER') {
        $text = [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($text -notmatch '^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$') { throw 'Invalid numeric value' }
        return $text
    }
    if ($Type -eq 'TIMESTAMP WITH TIME ZONE') {
        if ($Value -isnot [string] -or $Value -notmatch '\A([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{9}) ([+-][0-9]{2}:[0-9]{2})\z') { throw 'Invalid timestamp with time zone; expected YYYY-MM-DD HH:MM:SS.FFFFFFFFF +/-HH:MM' }
        $timestamp = $Matches[1]; $offset = $Matches[2]
        # Parse the signed offset separately: FX with TZH rejects +02:00 on Oracle 21c.
        return "FROM_TZ($(Get-OrfLiteral $timestamp 'TIMESTAMP'), $(Get-OrfQuoted $offset))"
    }
    $formats = @{ DATE=@('TO_DATE','FXYYYY-MM-DD HH24:MI:SS'); TIMESTAMP=@('TO_TIMESTAMP','FXYYYY-MM-DD HH24:MI:SS.FF9') }
    if ($formats.ContainsKey($Type)) {
        return "$($formats[$Type][0])($(Get-OrfLiteral $Value 'VARCHAR2'), '$($formats[$Type][1])')"
    }
    if ($Value -isnot [string]) { throw 'Character value must be a string or null' }
    $parts = New-Object 'System.Collections.Generic.List[string]'; $prefix = ''; $chr = 'CHR'
    if ($Type -in @('NCHAR','NVARCHAR2')) { $prefix = 'N'; $chr = 'NCHR' }
    foreach ($piece in [regex]::Split($Value, '([\r\n])')) {
        if ($piece -ceq "`r" -or $piece -ceq "`n") { $parts.Add("$chr($([int][char]$piece))"); continue }
        for ($i=0; $i -lt $piece.Length;) {
            $length = [Math]::Min(200, $piece.Length - $i)
            if ($i + $length -lt $piece.Length -and [char]::IsHighSurrogate($piece[$i + $length - 1])) { $length-- }
            $parts.Add($prefix + (Get-OrfQuoted $piece.Substring($i, $length))); $i += $length
        }
    }
    if ($parts.Count -eq 0) { return 'NULL' }
    $result = '(' + ($parts -join "`n || ") + ')'
    if ($parts.Count -gt 1 -and $Type -in @('CHAR','NCHAR')) {
        $cast = "NCHAR($($Value.Length))"; if ($Type -eq 'CHAR') { $cast = "CHAR($($Value.Length) CHAR)" }
        $result = "CAST($result AS $cast)"
    }
    return $result
}

function Get-OrfExpression([string]$Column, [string]$Type) {
    switch ($Type) {
        'NUMBER' { return "TO_CHAR($Column, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''')" }
        'DATE' { return "TO_CHAR($Column, 'YYYY-MM-DD HH24:MI:SS')" }
        'TIMESTAMP' { return "TO_CHAR($Column, 'YYYY-MM-DD HH24:MI:SS.FF9')" }
        'TIMESTAMP WITH TIME ZONE' { return "TO_CHAR($Column, 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM')" }
        default { return $Column }
    }
}

function Get-OrfPredicate($Values, $Types, [switch]$Captured) {
    $terms = foreach ($column in $Values.Keys) {
        $value = $Values[$column]; $type = $Types[$column]
        if ($null -eq $value -or ($value -is [string] -and $value.Length -eq 0)) { "$column IS NULL"; continue }
        $expression = $column
        if ($Captured) {
            $expression = Get-OrfExpression $column $type
            if ($type -notin @('CHAR','VARCHAR2','NCHAR','NVARCHAR2')) { $type = 'VARCHAR2' }
        }
        "$expression = $(Get-OrfLiteral $value $type)"
    }
    return $terms -join ' AND '
}

function Select-OrfMap($Value, $Names) {
    $result = [ordered]@{}
    foreach ($name in $Names) {
        if (-not $Value.Contains($name)) { throw "Missing column: $name" }
        $result[$name] = $Value[$name]
    }
    return ,$result
}

function Get-OrfLayout($Db, $Account, [string]$Table) {
    $fields = [ordered]@{ name='column_name'; type='data_type'; bytes='data_length'; precision='data_precision'; scale='data_scale'; chars='char_length'; charUsed='char_used'; nullable='nullable'; identity='identity_column'; virtual='virtual_column'; hidden='hidden_column'; defaultOnNull='default_on_null' }
    $pairs = foreach ($key in $fields.Keys) { "'$key' VALUE $($fields[$key])" }
    $sql = "SELECT 'LAYOUT|' || JSON_OBJECT($($pairs -join ', ') NULL ON NULL) FROM user_tab_cols WHERE table_name = $(Get-OrfQuoted $Table) AND user_generated = 'YES' ORDER BY internal_column_id;`n"
    $result = [ordered]@{}
    foreach ($line in (Invoke-OrfSqlPlus $Db $Account $sql) -split '\r?\n') {
        if ($line.Trim().StartsWith('LAYOUT|')) {
            $row = ConvertFrom-OrfJson $line.Trim().Substring(7); $name = Get-OrfIdentifier $row['name']
            $row.Remove('name'); $result[$name] = $row
        }
    }
    if ($result.Count -eq 0) { throw "$Table layout is missing" }
    return ,$result
}

function Get-OrfTypes($Layout) {
    $result = [ordered]@{}
    foreach ($name in $Layout.Keys) {
        $column = $Layout[$name]
        if ($column['virtual'] -eq 'YES' -or $column['hidden'] -eq 'YES') { continue }
        $type = Get-OrfType $column['type']
        if ($type -notin @('CHAR','VARCHAR2','NCHAR','NVARCHAR2','NUMBER','DATE','TIMESTAMP','TIMESTAMP WITH TIME ZONE')) { throw "Unsupported type for $name" }
        $result[$name] = $type
    }
    if ($result.Count -eq 0) { throw 'No supported visible columns' }
    return ,$result
}

function Get-OrfRows($Db, $Account, [string]$Table, $Types, $MaxRows=$null, [string]$Where='') {
    $fields = foreach ($column in $Types.Keys) { "$(Get-OrfQuoted $column) VALUE $(Get-OrfExpression $column $Types[$column])" }
    $clause = ''; if ($Where) { $clause = " WHERE $Where" }
    $limit = ''; if ($null -ne $MaxRows) { $limit = "IF v_count > $MaxRows THEN RAISE_APPLICATION_ERROR(-20004, 'maxRows exceeded'); END IF;" }
    $sql = @"
DECLARE v_count NUMBER := 0; v_json VARCHAR2(32767); BEGIN
FOR r IN (SELECT JSON_OBJECT($($fields -join ', ') NULL ON NULL RETURNING CLOB) AS j FROM $Table$clause) LOOP
v_count := v_count + 1;
$limit
IF DBMS_LOB.GETLENGTH(r.j) > 32763 THEN RAISE_APPLICATION_ERROR(-20005, 'JSON row too large'); END IF;
v_json := DBMS_LOB.SUBSTR(r.j, 32763, 1);
IF LENGTHB(v_json) > 32763 OR LENGTH(v_json) <> DBMS_LOB.GETLENGTH(r.j) THEN RAISE_APPLICATION_ERROR(-20005, 'JSON row too large'); END IF;
DBMS_OUTPUT.PUT_LINE('ROW|' || v_json);
END LOOP;
DBMS_OUTPUT.PUT_LINE('COUNT|' || v_count); END;
/
"@
    $rows = @(); $counts = @()
    foreach ($line in (Invoke-OrfSqlPlus $Db $Account $sql) -split '\r?\n') {
        $line = $line.Trim()
        if ($line.StartsWith('ROW|')) { $rows += ,(ConvertFrom-OrfJson $line.Substring(4)) }
        if ($line.StartsWith('COUNT|')) { $counts += [long]$line.Substring(6) }
    }
    if ($counts.Count -ne 1 -or $counts[0] -ne $rows.Count) { throw "$Table incomplete row output" }
    return ,$rows
}

function Get-OrfCount($Db, $Account, [string]$Query) {
    $output = Invoke-OrfSqlPlus $Db $Account "SELECT 'CHECK|' || ($Query) FROM dual;`n"
    $values = @($output -split '\r?\n' | Where-Object { $_.Trim().StartsWith('CHECK|') } | ForEach-Object { [long]$_.Trim().Substring(6) })
    if ($values.Count -ne 1) { throw 'Missing or ambiguous count' }
    return $values[0]
}

function Assert-OrfKeys($Db, $Account, $Step, $Types) {
    $keys = $Step['key']; $nulls = @($keys | ForEach-Object { "$_ IS NULL" }) -join ' OR '
    $where = Get-OrfSelection $Step $Types
    if ((Get-OrfCount $Db $Account "SELECT COUNT(*) FROM (SELECT $($keys -join ', ') FROM $($Step['table']) WHERE $where GROUP BY $($keys -join ', ') HAVING COUNT(*) > 1 OR $nulls)") -ne 0) { throw "$($Step['table']): selected keys must be unique and non-null" }
}

function Get-OrfSelection($Step, $Types) {
    if ($Step['allRows']) { return '1=1' }
    $terms = foreach ($item in $Step['match']) { '(' + (Get-OrfPredicate (Select-OrfMap $item $Step['key']) $Types) + ')' }
    return '(' + ($terms -join ' OR ') + ')'
}

function Get-OrfInsertChecks($Step, [switch]$AllowMissing) {
    $statements = @()
    foreach ($row in $Step['rows']) {
        $keyWhere = Get-OrfPredicate (Select-OrfMap $row $Step['key']) $Step['types']
        $where = Get-OrfPredicate $row $Step['types'] -Captured
        $statements += "SELECT COUNT(*) INTO v_count FROM $($Step['table']) WHERE $keyWhere;"
        if ($AllowMissing) {
            $statements += "IF v_count > 1 THEN RAISE_APPLICATION_ERROR(-20016, 'Duplicate insert key'); END IF;"
            $statements += 'IF v_count = 1 THEN'
        } else {
            $statements += "IF v_count <> 1 THEN RAISE_APPLICATION_ERROR(-20016, 'Missing or duplicate insert key'); END IF;"
        }
        $statements += Get-OrfCountAssertion "SELECT 1 FROM $($Step['table']) WHERE $keyWhere AND $where" 1 "$($Step['table']) insert key conflicts with captured values"
        if ($AllowMissing) { $statements += 'END IF;' }
    }
    return $statements -join "`n"
}

function Get-OrfSelectedRows($Db, $Account, $Step, $Types, $KeyValues, [switch]$AllowMissing) {
    $rows = @()
    foreach ($tuple in $KeyValues) {
        $values = [ordered]@{}; for ($i=0; $i -lt $Step['key'].Count; $i++) { $values[$Step['key'][$i]] = $tuple[$i] }
        $found = Get-OrfRows $Db $Account $Step['table'] $Types 1 (Get-OrfPredicate $values $Types)
        if ($found.Count -eq 0 -and $AllowMissing) {
            Write-Warning "$($Step['table']): skipping missing key $(ConvertTo-OrfJson $values)"
            continue
        }
        if ($found.Count -ne 1) { throw "$($Step['table']): missing or duplicate key" }
        $rows += ,$found[0]
    }
    return ,$rows
}

function Get-OrfInsertBackup([string]$User, [string]$Table, $Types, $Rows) {
    $lines = @("-- Captured rows for $User.$Table; manual recovery aid, target must not already contain these rows.",
        'WHENEVER SQLERROR EXIT FAILURE ROLLBACK', 'SET DEFINE OFF', 'SET SQLBLANKLINES ON',
        "ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,';", "ALTER SESSION SET NLS_CALENDAR='GREGORIAN';")
    foreach ($row in $Rows) {
        $values = foreach ($column in $Types.Keys) { Get-OrfLiteral $row[$column] $Types[$column] }
        $lines += "INSERT INTO $User.$Table ($(@($Types.Keys) -join ', ')) VALUES (`n$($values -join ",`n"));"
    }
    $lines += '-- Review the result and COMMIT explicitly; otherwise ROLLBACK.'
    return ($lines -join "`n") + "`n"
}

function Get-OrfCsv([string[]]$Names, $Rows) {
    $header = @($Names) + @($Names | ForEach-Object { $_ + '__IS_NULL' })
    if (($header | Select-Object -Unique).Count -ne $header.Count) { throw 'CSV null flag column name collision' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add((@($header | ForEach-Object { '"' + $_.Replace('"', '""') + '"' }) -join ','))
    foreach ($row in $Rows) {
        $fields = @(); $flags = @()
        foreach ($name in $Names) {
            $text = ''; $flag = '1'
            if ($null -ne $row[$name]) { $text = [string]$row[$name]; $flag = '0' }
            $fields += '"' + $text.Replace('"', '""') + '"'; $flags += '"' + $flag + '"'
        }
        $lines.Add((($fields + $flags) -join ','))
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Write-OrfSnapshot([string]$Directory, $Snapshot) {
    $path = Join-Path $Directory 'snapshot.json'
    Write-OrfText $path (ConvertTo-OrfJson $Snapshot)
    Write-OrfText (Join-Path $Directory 'snapshot.sha256') ((Get-OrfHash ([IO.File]::ReadAllBytes($path))) + "`n")
}

function Read-OrfSnapshot([string]$Path, $Configuration) {
    $directory = Split-Path -Parent $Path
    $expected = [IO.File]::ReadAllText((Join-Path $directory 'snapshot.sha256')).Trim()
    if ((Get-OrfHash ([IO.File]::ReadAllBytes($Path))) -cne $expected) { throw 'Snapshot checksum mismatch' }
    $snapshot = Read-OrfJson $Path
    if ($snapshot['version'] -ne 5) { throw 'PowerShell requires a new version 5 capture before DBA refresh; old snapshots cannot be used' }
    if ($snapshot['status'] -cne 'SUCCESS' -or $snapshot['configHash'] -cne $Configuration.Hash) { throw 'Incomplete snapshot or changed configuration' }
    if ($snapshot['schemas'].Count -ne $Configuration.Schemas.Count) { throw 'Snapshot schema count mismatch' }
    for ($i=0; $i -lt $Configuration.Schemas.Count; $i++) {
        $entry = $snapshot['schemas'][$i]; $cfg = $Configuration.Schemas[$i]
        if ($entry['username'] -cne $cfg['username'] -or -not (Test-OrfEqual $entry['definition'] $cfg['steps'])) { throw 'Snapshot steps/schema mismatch' }
        if ($entry['steps'].Count -ne $cfg['steps'].Count) { throw 'Snapshot step count mismatch' }
        for ($j=0; $j -lt $cfg['steps'].Count; $j++) {
            $step = $entry['steps'][$j]; $current = $cfg['steps'][$j]
            foreach ($key in $current.Keys) {
                if (-not (Test-OrfEqual $step[$key] $current[$key])) { throw 'Snapshot operation mismatch' }
            }
        }
    }
    return ,$snapshot
}

function Test-OrfCaptureFiles([string]$Directory, $Configuration, $Snapshot, $Inventory) {
    $read = Read-OrfSnapshot (Join-Path $Directory 'snapshot.json') $Configuration
    if (-not (Test-OrfEqual $read $Snapshot)) { throw 'Snapshot read-back mismatch' }
    $expectedFiles = @{}
    foreach ($backup in $Inventory) {
        $csv = Join-Path $Directory ($backup.User + '/' + $backup.Table + '.csv')
        $sql = Join-Path $Directory ($backup.User + '/' + $backup.Table + '.insert.sql')
        # Compare exact CSV bytes/text with all original values (including embedded
        # CRLF and NULL flags), not just the checksum written alongside the file.
        if ([IO.File]::ReadAllText($csv, $script:OrfUtf8) -cne (Get-OrfCsv @($backup.Types.Keys) $backup.Rows)) { throw 'CSV read-back mismatch' }
        if ([IO.File]::ReadAllText($sql, $script:OrfUtf8) -cne (Get-OrfInsertBackup $backup.User $backup.Table $backup.Types $backup.Rows)) { throw 'INSERT backup read-back mismatch' }
        foreach ($file in @($csv, $sql)) {
            $relative = $backup.User + '/' + [IO.Path]::GetFileName($file)
            $expectedFiles[$relative] = Get-OrfHash ([IO.File]::ReadAllBytes($file))
        }
    }
    $manifest = @([IO.File]::ReadAllLines((Join-Path $Directory 'backups.sha256')))
    if ($manifest.Count -ne $expectedFiles.Count) { throw 'Incomplete backup manifest' }
    foreach ($line in $manifest) {
        $parts = $line -split '  ', 2
        if ($parts.Count -ne 2 -or -not $expectedFiles.ContainsKey($parts[1]) -or $expectedFiles[$parts[1]] -cne $parts[0]) { throw 'Backup checksum mismatch' }
        $expectedFiles.Remove($parts[1])
    }
}

function Invoke-OrfCapture($Configuration) {
    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
    $directory = Join-Path $Configuration.Root ('snapshots/' + $stamp)
    if (Test-Path -LiteralPath $directory) { throw 'Snapshot directory already exists' }
    [void][IO.Directory]::CreateDirectory($directory)
    $snapshot = [ordered]@{ version=5; capturedAt=$stamp; configHash=$Configuration.Hash; status='INCOMPLETE'; schemas=@() }
    $inventory = @(); $manifest = @(); $db = $Configuration.Database
    try {
        foreach ($cfg in $Configuration.Schemas) {
            $entry = [ordered]@{ username=$cfg['username']; definition=(Copy-OrfValue $cfg['steps']); layouts=[ordered]@{}; steps=@() }
            $cache = @{}
            foreach ($definition in $cfg['steps']) {
                $step = Copy-OrfValue $definition; $table = $step['table']; $kind = $step['type']
                if (-not $cache.ContainsKey($table)) {
                    $layout = Get-OrfLayout $db $cfg $table; $types = Get-OrfTypes $layout
                    $where = ''
                    if ($step.Contains('key')) {
                        $null = Select-OrfMap $types $step['key']
                    }
                    if ($kind -eq 'insert') {
                        foreach ($col in $layout.Values) { if ($col['identity'] -eq 'YES' -or $col['hidden'] -eq 'YES') { throw "$table insert does not support identity/invisible columns" } }
                    }
                    if ($kind -in @('insert','backupTable') -and -not $step['allRows']) { $where = Get-OrfSelection $step $types }
                    $rows = Get-OrfRows $db $cfg $table $types $null $where
                    $entry['layouts'][$table] = $layout
                    $cache[$table] = @{ Types=$types; Rows=$rows }
                    $schemaDirectory = Join-Path $directory $cfg['username']; [void][IO.Directory]::CreateDirectory($schemaDirectory)
                    $csv = Join-Path $schemaDirectory ($table + '.csv'); $sql = Join-Path $schemaDirectory ($table + '.insert.sql')
                    [IO.File]::WriteAllText($csv, (Get-OrfCsv @($types.Keys) $rows), (New-Object Text.UTF8Encoding($true)))
                    Write-OrfText $sql (Get-OrfInsertBackup $cfg['username'] $table $types $rows)
                    foreach ($file in @($csv, $sql)) { $manifest += (Get-OrfHash ([IO.File]::ReadAllBytes($file))) + '  ' + $cfg['username'] + '/' + [IO.Path]::GetFileName($file) }
                    $inventory += @{ User=$cfg['username']; Table=$table; Types=$types; Rows=$rows }
                }
                $types = $cache[$table].Types; $rows = $cache[$table].Rows
                if ($step.Contains('key')) {
                    $null = Select-OrfMap $types $step['key']
                    if ($kind -in @('restoreRows','insert')) { Assert-OrfKeys $db $cfg $step $types }
                }
                switch ($kind) {
                    'backupTable' { }
                    { $_ -in @('insert','replaceTable') } { $step['types'] = $types; $step['rows'] = $rows }
                    'restoreRows' {
                        $names = @($step['key']) + @($step['columns']); $selectedTypes = Select-OrfMap $types $names
                        $selected = @()
                        if ($step['allRows']) {
                            foreach ($row in $rows) { $selected += ,(Select-OrfMap $row $names) }
                        } else {
                            $selected = Get-OrfRows $db $cfg $table $selectedTypes $null (Get-OrfSelection $step $selectedTypes)
                        }
                        $step['types'] = $selectedTypes; $step['rows'] = $selected
                    }
                    'update' { $step['types'] = Select-OrfMap $types (@($step['key']) + @($step['set'].Keys)) }
                    'delete' {
                        $step['types'] = [ordered]@{}
                        if (-not $step['allRows']) { $step['types'] = Select-OrfMap $types $step['key'] }
                    }
                }
                $entry['steps'] += ,$step
                Write-Host "$($cfg['username']).${table}: captured $($rows.Count) backup rows ($kind)"
            }
            $snapshot['schemas'] += ,$entry
        }
        $snapshot['status'] = 'SUCCESS'
        Write-OrfSnapshot $directory $snapshot
        Write-OrfText (Join-Path $directory 'backups.sha256') (($manifest -join "`n") + "`n")
        Test-OrfCaptureFiles $directory $Configuration $snapshot $inventory
        Write-Host "CAPTURE SUCCESS: $directory"
        return (Join-Path $directory 'snapshot.json')
    } catch {
        $snapshot['status'] = 'FAILED'; Write-OrfSnapshot $directory $snapshot
        throw
    }
}

function Assert-OrfDependencies($Db, $Account, $Entry) {
    $replacements = @($Entry['steps'] | Where-Object { $_['type'] -eq 'replaceTable' })
    $tables = @($replacements | ForEach-Object { $_['table'] })
    if ($tables.Count -eq 0) { return }
    # Cross-schema incoming FKs are outside the supported deployment model.
    $names = @($tables | ForEach-Object { Get-OrfQuoted $_ }) -join ','
    $sql = "SELECT 'FK|' || c.owner || '|' || c.table_name || '|' || p.table_name FROM all_constraints c JOIN user_constraints p ON p.owner=c.r_owner AND p.constraint_name=c.r_constraint_name WHERE c.constraint_type='R' AND c.status='ENABLED' AND p.owner=$(Get-OrfQuoted $Account['username']) AND p.table_name IN ($names);`n"
    foreach ($line in (Invoke-OrfSqlPlus $Db $Account $sql) -split '\r?\n') {
        if (-not $line.Trim().StartsWith('FK|')) { continue }
        $owner,$child,$parent = $line.Trim().Substring(3).Split('|')
        if ($owner -cne $Account['username'] -or $tables -cnotcontains $child -or [array]::IndexOf($tables,$child) -le [array]::IndexOf($tables,$parent)) {
            throw "${owner}.${child} -> $($Account['username']).${parent}: FK requires same-schema replacement with parents before children; DBA handling required"
        }
    }
}

function Get-OrfValueChecks($Step, $Layout) {
    $statements = @(); $table = $Step['table']
    foreach ($column in $Step['set'].Keys) {
        $info = $Layout[$column]; $type = Get-OrfType $info['type']
        $expression = Get-OrfLiteral $Step['set'][$column] $type; $bad = @()
        if ($info['nullable'] -eq 'N') { $bad += "$expression IS NULL" }
        if ($type -in @('CHAR','VARCHAR2','NCHAR','NVARCHAR2')) {
            $function = 'LENGTHB'; $size = $info['bytes']
            if ($type -in @('NCHAR','NVARCHAR2') -or $info['charUsed'] -eq 'C') { $function = 'LENGTH'; $size = $info['chars'] }
            $bad += "$function($expression) > $size"
        } elseif ($type -eq 'NUMBER' -and ($null -ne $info['precision'] -or $null -ne $info['scale'])) {
            $precision = 38; $scale = 0
            if ($null -ne $info['precision']) { $precision = $info['precision'] }
            if ($null -ne $info['scale']) { $scale = $info['scale'] }
            $bad += "CAST($expression AS NUMBER($precision,$scale)) <> $expression"
        }
        if ($bad.Count -gt 0) {
            $statements += "SELECT COUNT(*) INTO v_count FROM dual WHERE $($bad -join ' OR ');"
            $statements += "IF v_count <> 0 THEN RAISE_APPLICATION_ERROR(-20011, '$table.${column}: value does not fit'); END IF;"
        }
        $statements += "SELECT COUNT(*) INTO v_count FROM dual WHERE $expression IS NULL;"
    }
    return $statements -join "`n"
}

function Read-OrfPlan([string]$Path, $Snapshot, $Db) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $wrapper = Read-OrfJson $Path; $plan = $wrapper['plan']
    if ($wrapper['sha256'] -cne (Get-OrfDigest $plan) -or $plan['snapshotHash'] -cne (Get-OrfDigest $Snapshot) -or $plan['target'] -cne (Get-OrfConnectIdentifier $Db)) { throw 'Restore plan checksum/snapshot/target mismatch' }
    if ($plan['schemas'].Count -ne $Snapshot['schemas'].Count) { throw 'Restore plan schema count mismatch' }
    return ,$plan
}

function Write-OrfPlan([string]$Path, $Plan) {
    # Plans are immutable: retries reuse the exact selection saved before DML.
    if (Test-Path -LiteralPath $Path) {
        $existing = Read-OrfJson $Path
        if ($existing['sha256'] -cne (Get-OrfDigest $Plan) -or -not (Test-OrfEqual $existing['plan'] $Plan)) { throw 'Refusing to overwrite a different restore plan' }
        return
    }
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $bytes = $script:OrfUtf8.GetBytes((ConvertTo-OrfJson ([ordered]@{ sha256=(Get-OrfDigest $Plan); plan=$Plan })))
        $file = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($bytes,0,$bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
        [IO.File]::Move($temp,$Path)
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
}

function Get-OrfRestoreTables($Entry) {
    $Entry['steps'] | Where-Object { $_['type'] -ne 'backupTable' } | ForEach-Object { $_['table'] } | Sort-Object -Unique
}

function Invoke-OrfPreflight($Configuration, $Snapshot, [string]$StatePath='') {
    $db = $Configuration.Database; $previous = Read-OrfPlan $StatePath $Snapshot $db
    $plan = $previous
    if ($null -eq $plan) { $plan = [ordered]@{ snapshotHash=(Get-OrfDigest $Snapshot); target=(Get-OrfConnectIdentifier $db); schemas=@() } }
    for ($schemaIndex=0; $schemaIndex -lt $Configuration.Schemas.Count; $schemaIndex++) {
        $cfg = $Configuration.Schemas[$schemaIndex]; $entry = $Snapshot['schemas'][$schemaIndex]
        foreach ($table in (Get-OrfRestoreTables $entry)) {
            if (-not (Test-OrfEqual (Get-OrfLayout $db $cfg $table) $entry['layouts'][$table])) { throw "$table layout changed" }
            if ((Get-OrfCount $db $cfg "SELECT COUNT(*) FROM user_triggers WHERE table_name=$(Get-OrfQuoted $table) AND status='ENABLED'") -gt 0) { throw "$table enabled triggers require DBA handling" }
        }
        Assert-OrfDependencies $db $cfg $entry
        $schemaPlan = [ordered]@{ updates=[ordered]@{} }
        if ($null -ne $previous) { $schemaPlan = $previous['schemas'][$schemaIndex] }
        $used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        for ($index=0; $index -lt $entry['steps'].Count; $index++) {
            $step = $entry['steps'][$index]; $kind = $step['type']; $table = $step['table']; $layout = $entry['layouts'][$table]
            if ($kind -eq 'replaceTable') {
                foreach ($col in $layout.Values) { if ($col['identity'] -eq 'YES' -or $col['hidden'] -eq 'YES') { throw "$table replacement does not support identity/invisible columns" } }
            }
            if ($kind -eq 'insert') {
                foreach ($col in $layout.Values) { if ($col['identity'] -eq 'YES' -or $col['hidden'] -eq 'YES') { throw "$table insert does not support identity/invisible columns" } }
                $null = Invoke-OrfSqlPlus $db $cfg ("DECLARE v_count NUMBER; BEGIN`n" + (Get-OrfInsertChecks $step -AllowMissing) + "`nNULL; END;`n/`n")
            }
            if ($kind -eq 'restoreRows' -or $kind -eq 'update') {
                $columns = $step['columns']; if ($kind -eq 'update') { $columns = @($step['set'].Keys) }
                foreach ($column in $columns) { if ($layout[$column]['identity'] -eq 'YES' -or $layout[$column]['virtual'] -eq 'YES') { throw 'Cannot update identity or virtual columns' } }
            }
            if ($kind -eq 'restoreRows') {
                $tuples = @(); foreach ($row in $step['rows']) { $tuples += ,@($step['key'] | ForEach-Object { $row[$_] }) }
                $null = Get-OrfSelectedRows $db $cfg $step $step['types'] $tuples -AllowMissing
            }
            if ($kind -ne 'update') { continue }
            $null = Invoke-OrfSqlPlus $db $cfg ("DECLARE v_count NUMBER; BEGIN`n" + (Get-OrfValueChecks $step $layout) + "`nEND;`n/`n")
            if ($null -ne $previous) {
                if (-not $schemaPlan['updates'].Contains([string]$index)) { throw 'Missing UPDATE restore plan' }
                $rows = $schemaPlan['updates'][[string]$index]['rows']
                foreach ($group in (Get-OrfRowGroups $rows)) {
                    $where = Get-OrfPredicate $group.Row $step['types']
                    if ((Get-OrfCount $db $cfg "SELECT COUNT(*) FROM $table WHERE $where") -ne $group.Count) { throw "$table UPDATE group count changed" }
                }
            } else {
                $where = Get-OrfSelection $step $step['types']
                $rows = Get-OrfRows $db $cfg $table (Select-OrfMap $step['types'] $step['key']) $null $where
                $schemaPlan['updates'][[string]$index] = [ordered]@{ rows=$rows }
            }
            foreach ($group in (Get-OrfRowGroups $rows)) {
                $row = $group.Row
                if (-not $used.Add($table + '|' + (ConvertTo-OrfJson $row))) { throw "$table overlapping UPDATE steps" }
                foreach ($deletion in $entry['steps']) {
                    if ($deletion['type'] -ne 'delete' -or $deletion['table'] -ne $table) { continue }
                    $alternatives = @()
                    if ($deletion['allRows']) { $alternatives = @('1=1') }
                    else {
                        foreach ($item in $deletion['match']) {
                            $terms = foreach ($col in $item.Keys) {
                                $expression = $col
                                if ($step['set'].Contains($col)) { $expression = Get-OrfLiteral $step['set'][$col] $step['types'][$col] }
                                if ($null -eq $item[$col] -or $item[$col] -ceq '') { "$expression IS NULL" }
                                else { "$expression = $(Get-OrfLiteral $item[$col] $deletion['types'][$col])" }
                            }
                            $alternatives += '(' + ($terms -join ' AND ') + ')'
                        }
                    }
                    $old = Get-OrfSelection $deletion $deletion['types']; $keyWhere = Get-OrfPredicate $row $step['types']
                    if ((Get-OrfCount $db $cfg "SELECT COUNT(*) FROM $table WHERE $keyWhere AND (($old) OR ($($alternatives -join ' OR ')))") -gt 0) { throw "$table DELETE overlaps UPDATE validation rows" }
                }
            }
        }
        if ($null -eq $previous) { $plan['schemas'] += ,$schemaPlan }
    }
    Write-Host 'PREFLIGHT SUCCESS (read-only database checks)'
    return ,$plan
}

# Preserve the multiplicity of non-unique UPDATE selection values in the saved plan.
function Get-OrfRowGroups($Rows) {
    $groups = [ordered]@{}
    foreach ($row in $Rows) {
        $digest = Get-OrfDigest $row
        if (-not $groups.Contains($digest)) { $groups[$digest] = @{ Row=$row; Count=0 } }
        $groups[$digest].Count++
    }
    foreach ($group in $groups.Values) { $group }
}

function Get-OrfCountAssertion([string]$Query, [long]$Expected, [string]$Label) {
    "SELECT COUNT(*) INTO v_count FROM ($Query);`nIF v_count <> $Expected THEN RAISE_APPLICATION_ERROR(-20012, $(Get-OrfQuoted $Label)); END IF;"
}

function Get-OrfValidationSql($Entry, $SchemaPlan) {
    $statements = @()
    for ($index=0; $index -lt $Entry['steps'].Count; $index++) {
        $step = $Entry['steps'][$index]; $table = $step['table']; $types = $step['types']
        switch ($step['type']) {
            'insert' { $statements += Get-OrfInsertChecks $step }
            'restoreRows' {
                foreach ($row in $step['rows']) {
                    $where = Get-OrfPredicate $row $types -Captured
                    $keyWhere = Get-OrfPredicate (Select-OrfMap $row $step['key']) $types
                    $statements += "SELECT COUNT(*) INTO v_count FROM $table WHERE $keyWhere;"
                    $statements += "IF v_count > 1 THEN RAISE_APPLICATION_ERROR(-20014, 'Duplicate restore key'); END IF;"
                    $statements += "IF v_count = 1 THEN"
                    $statements += Get-OrfCountAssertion "SELECT 1 FROM $table WHERE $where" 1 "$table restored row mismatch"
                    $statements += 'END IF;'
                }
            }
            'replaceTable' {
                $statements += Get-OrfCountAssertion "SELECT 1 FROM $table" $step['rows'].Count "$table replacement count mismatch"
                $groups = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
                foreach ($row in $step['rows']) {
                    $encoded = ConvertTo-OrfJson $row
                    if (-not $groups.ContainsKey($encoded)) { $groups[$encoded] = 0 }; $groups[$encoded]++
                }
                foreach ($encoded in $groups.Keys) {
                    $where = Get-OrfPredicate (ConvertFrom-OrfJson $encoded) $types -Captured
                    $statements += Get-OrfCountAssertion "SELECT 1 FROM $table WHERE $where" $groups[$encoded] "$table replacement value mismatch"
                }
            }
            'delete' {
                $where = Get-OrfSelection $step $types
                $statements += Get-OrfCountAssertion "SELECT 1 FROM $table WHERE $where" 0 "$table deleted rows remain"
            }
            'update' {
                if (-not $SchemaPlan['updates'].Contains([string]$index)) { throw 'UPDATE validation requires a saved restore plan' }
                $rows = $SchemaPlan['updates'][[string]$index]['rows']
                foreach ($group in (Get-OrfRowGroups $rows)) {
                    $row = $group.Row
                    $keyWhere = Get-OrfPredicate $row $types
                    $statements += Get-OrfCountAssertion "SELECT 1 FROM $table WHERE $keyWhere" $group.Count "$table UPDATE group count changed"
                    $values = Copy-OrfValue $row
                    foreach ($key in $step['set'].Keys) { $values[$key] = $step['set'][$key] }
                    $where = Get-OrfPredicate $values $types
                    $statements += Get-OrfCountAssertion "SELECT 1 FROM $table WHERE $where" $group.Count "$table UPDATE key/value mismatch"
                }
                if ($step['allRows']) { $statements += Get-OrfCountAssertion "SELECT 1 FROM $table" $rows.Count "$table UPDATE table row count changed" }
            }
        }
    }
    return $statements -join "`n"
}

function Get-OrfRestoreSql($Entry, $SchemaPlan, [bool]$FirstAttempt) {
    $statements = @(Get-OrfRestoreTables $Entry | ForEach-Object { "LOCK TABLE $_ IN EXCLUSIVE MODE NOWAIT;" })
    if ($FirstAttempt) {
        for ($index=0; $index -lt $Entry['steps'].Count; $index++) {
            $step = $Entry['steps'][$index]; if ($step['type'] -ne 'update') { continue }
            $rows = $SchemaPlan['updates'][[string]$index]['rows']; $clause = ''
            if (-not $step['allRows']) { $clause = ' WHERE ' + (Get-OrfSelection $step $step['types']) }
            $statements += Get-OrfCountAssertion "SELECT 1 FROM $($step['table'])$clause" $rows.Count 'UPDATE selection changed since preflight'
            foreach ($group in (Get-OrfRowGroups $rows)) {
                $row = $group.Row
                $where = Get-OrfPredicate $row $step['types']
                if (-not $step['allRows']) { $where += ' AND ' + (Get-OrfSelection $step $step['types']) }
                $statements += Get-OrfCountAssertion "SELECT 1 FROM $($step['table']) WHERE $where" $group.Count 'UPDATE key selection changed'
            }
        }
    }
    for ($index=$Entry['steps'].Count-1; $index -ge 0; $index--) {
        $step = $Entry['steps'][$index]; if ($step['type'] -ne 'replaceTable') { continue }
        $statements += "DELETE FROM $($step['table']);"
    }
    for ($index=0; $index -lt $Entry['steps'].Count; $index++) {
        $step = $Entry['steps'][$index]; $table = $step['table']; $types = $step['types']
        switch ($step['type']) {
            'insert' {
                $statements += Get-OrfInsertChecks $step -AllowMissing
                foreach ($row in $step['rows']) {
                    $values = foreach ($column in $types.Keys) { Get-OrfLiteral $row[$column] $types[$column] }
                    $where = Get-OrfPredicate (Select-OrfMap $row $step['key']) $types
                    $statements += "INSERT INTO $table ($(@($types.Keys) -join ', ')) SELECT $($values -join ",`n") FROM dual WHERE NOT EXISTS (SELECT 1 FROM $table WHERE $where);"
                }
            }
            'replaceTable' {
                foreach ($row in $step['rows']) {
                    $values = foreach ($column in $types.Keys) { Get-OrfLiteral $row[$column] $types[$column] }
                    $statements += "INSERT INTO $table ($(@($types.Keys) -join ', ')) VALUES (`n$($values -join ",`n"));"
                }
            }
            'update' {
                $rows = $SchemaPlan['updates'][[string]$index]['rows']
                $assignments = foreach ($column in $step['set'].Keys) { "$column = $(Get-OrfLiteral $step['set'][$column] $types[$column])" }
                foreach ($group in (Get-OrfRowGroups $rows)) {
                    $where = Get-OrfPredicate $group.Row $types
                    $statements += "UPDATE $table SET $($assignments -join ",`n") WHERE $where;"
                    $statements += "IF SQL%ROWCOUNT <> $($group.Count) THEN RAISE_APPLICATION_ERROR(-20014, 'UPDATE group count changed'); END IF;"
                }
            }
            'restoreRows' {
                $rows = $step['rows']
                $rowIndex = -1
                foreach ($row in $rows) {
                    $rowIndex++
                    $values = Select-OrfMap $row $step['columns']
                    $assignments = foreach ($column in $values.Keys) { "$column = $(Get-OrfLiteral $values[$column] $types[$column])" }
                    $where = Get-OrfPredicate (Select-OrfMap $row $step['key']) $types
                    $statements += "UPDATE $table SET $($assignments -join ",`n") WHERE $where;"
                    $statements += "IF SQL%ROWCOUNT > 1 THEN RAISE_APPLICATION_ERROR(-20014, 'Duplicate restore key'); END IF;"
                    $statements += "IF SQL%ROWCOUNT = 0 THEN DBMS_OUTPUT.PUT_LINE('ORF_SKIP|$index|$rowIndex'); END IF;"
                }
            }
            'delete' {
                $where = Get-OrfSelection $step $types
                if ($step['allRows']) { $statements += "DELETE FROM $table;" }
                else { $statements += "DELETE FROM $table WHERE $where;" }
            }
        }
    }
    $statements += Get-OrfValidationSql $Entry $SchemaPlan
    return "DECLARE v_count NUMBER; BEGIN`n$($statements -join "`n")`nCOMMIT;`nEXCEPTION WHEN OTHERS THEN ROLLBACK; RAISE; END;`n/`n"
}

function Write-OrfSkippedRecovery($Entry, $Db, $Account, [string]$Output, [string]$SnapshotDirectory, [string]$ReportDirectory) {
    [void][IO.Directory]::CreateDirectory($ReportDirectory)
    $records = @()
    foreach ($line in $Output -split '\r?\n') {
        if ($line.Trim() -notmatch '^ORF_SKIP\|(\d+)\|(\d+)$') { continue }
        $stepIndex = [int]$Matches[1]; $rowIndex = [int]$Matches[2]
        $step = $Entry['steps'][$stepIndex]; $row = $step['rows'][$rowIndex]
        $records += [ordered]@{ schema=$Entry['username']; table=$step['table']; stepIndex=$stepIndex; key=(Select-OrfMap $row $step['key']); reason='Missing at restore'; capturedValues=$row }
    }
    $prefix = Join-Path $ReportDirectory $Entry['username']
    Write-OrfText ($prefix + '.skipped-updates.json') (ConvertTo-OrfJson $records)
    Write-Host "$($Entry['username']): $($records.Count) skipped updates; log: $prefix.skipped-updates.json"
    if ($records.Count -eq 0) { return }
    # Save the log before reading backups, so a damaged backup never loses the audit.
    $manifest = [IO.File]::ReadAllLines((Join-Path $SnapshotDirectory 'backups.sha256'))
    $cache = @{}; $sql = @('-- Review foreign-key order and captured values before running in SQL*Plus.',
        '-- Connect as the original schema. Review results and COMMIT explicitly; otherwise ROLLBACK.',
        'WHENEVER SQLERROR EXIT FAILURE ROLLBACK', 'WHENEVER OSERROR EXIT FAILURE ROLLBACK',
        'SET DEFINE OFF', 'SET SQLBLANKLINES ON', "ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,';", "ALTER SESSION SET NLS_CALENDAR='GREGORIAN';",
        (Get-OrfAccountGuard $Account))
    foreach ($record in $records) {
        $table = $record['table']; $step = $Entry['steps'][$record['stepIndex']]
        if (-not $cache.ContainsKey($table)) {
            $relative = $Entry['username'] + '/' + $table + '.csv'
            $path = Join-Path $SnapshotDirectory $relative
            $expected = @($manifest | Where-Object { ($_ -split '  ',2)[1] -ceq $relative })
            if ($expected.Count -ne 1 -or (Get-OrfHash ([IO.File]::ReadAllBytes($path))) -cne ($expected[0] -split '  ',2)[0]) { throw "$table backup checksum mismatch" }
            $layout = $Entry['layouts'][$table]; $types = Get-OrfTypes $layout
            $backupRows = @()
            foreach ($csvRow in @(Import-Csv -LiteralPath $path -Encoding UTF8)) {
                $full = [ordered]@{}
                foreach ($column in $types.Keys) {
                    $flag = $csvRow.PSObject.Properties[$column + '__IS_NULL']
                    $value = $csvRow.PSObject.Properties[$column]
                    if ($null -eq $flag -or $null -eq $value -or $flag.Value -notin @('0','1')) { throw "$table invalid backup CSV" }
                    $full[$column] = $null; if ($flag.Value -eq '0') { $full[$column] = $value.Value }
                }
                $backupRows += ,$full
            }
            $cache[$table] = @{Types=$types;Rows=$backupRows}
        }
        $backup = $cache[$table]; $matches = @($backup.Rows | Where-Object { Test-OrfEqual (Select-OrfMap $_ $step['key']) $record['key'] })
        if ($matches.Count -ne 1) { throw "$table missing or ambiguous full backup row" }
        $full = $matches[0]; $columns = @()
        foreach ($column in $backup.Types.Keys) {
            $meta = $Entry['layouts'][$table][$column]
            if ($meta['identity'] -eq 'YES') { throw "$table identity columns require manual recovery" }
            if ($meta['virtual'] -ne 'YES' -and $meta['hidden'] -ne 'YES') { $columns += $column }
        }
        $values = foreach ($column in $columns) { Get-OrfLiteral $full[$column] $backup.Types[$column] }
        $where = Get-OrfPredicate $record['key'] $backup.Types
        $sql += "INSERT INTO $($Entry['username']).$table ($($columns -join ', ')) SELECT $($values -join ', ') FROM dual WHERE NOT EXISTS (SELECT 1 FROM $($Entry['username']).$table WHERE $where);"
    }
    $sql += '-- No automatic COMMIT. Review inserted rows, then COMMIT or ROLLBACK.'
    Write-OrfText ($prefix + '.missing-rows.insert.sql') (($sql -join "`n") + "`n")
    Write-Host "Recovery SQL (not executed): $prefix.missing-rows.insert.sql"
}

function Invoke-OrfRestore($Configuration, $Snapshot, [string]$StatePath) {
    # Exclusive local lock prevents two processes from selecting different plans
    # for the same snapshot. The OS releases it even after a killed process.
    $lock = $null
    try {
        try { $lock = New-Object IO.FileStream(($StatePath + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { throw 'Another restore holds this snapshot lock, or the snapshot directory is not writable' }
        $first = -not (Test-Path -LiteralPath $StatePath)
        $plan = Invoke-OrfPreflight $Configuration $Snapshot $StatePath
        Write-OrfPlan $StatePath $plan
        $reportDirectory = Join-Path (Split-Path -Parent $StatePath) ('recovery/' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [guid]::NewGuid().ToString('N'))
        for ($i=0; $i -lt $Configuration.Schemas.Count; $i++) {
            $account = $Configuration.Schemas[$i]
            $sql = Get-OrfRestoreSql $Snapshot['schemas'][$i] $plan['schemas'][$i] $first
            $output = Invoke-OrfSqlPlus $Configuration.Database $account $sql
            Write-Host "$($account['username']): schema transaction committed and validated"
            if (@($Snapshot['schemas'][$i]['steps'] | Where-Object { $_['type'] -eq 'restoreRows' }).Count -gt 0) {
                try { Write-OrfSkippedRecovery $Snapshot['schemas'][$i] $Configuration.Database $account $output (Split-Path -Parent $StatePath) $reportDirectory }
                catch { throw "Schema $($account['username']) was committed, but recovery report failed: $($_.Exception.Message)" }
            }
        }
        Write-Host 'RESTORE SUCCESS'
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Invoke-OrfValidate($Configuration, $Snapshot, [string]$StatePath) {
    $plan = Read-OrfPlan $StatePath $Snapshot $Configuration.Database
    for ($i=0; $i -lt $Configuration.Schemas.Count; $i++) {
        $cfg = $Configuration.Schemas[$i]; $entry = $Snapshot['schemas'][$i]
        $schemaPlan = [ordered]@{ updates=[ordered]@{} }
        if ($null -ne $plan) { $schemaPlan = $plan['schemas'][$i] }
        foreach ($table in (Get-OrfRestoreTables $entry)) {
            if (-not (Test-OrfEqual (Get-OrfLayout $Configuration.Database $cfg $table) $entry['layouts'][$table])) { throw "$table layout changed" }
        }
        $sql = Get-OrfValidationSql $entry $schemaPlan
        if (-not $sql) { $sql = 'NULL;' }
        $null = Invoke-OrfSqlPlus $Configuration.Database $cfg "DECLARE v_count NUMBER; BEGIN`n$sql`nEND;`n/`n"
        Write-Host "$($cfg['username']): all configured results validated"
    }
    Write-Host 'VALIDATION SUCCESS'
}

function Invoke-OrfAction {
    param([ValidateSet('capture','preflight','restore','validate')][string]$Action,
          [string]$Snapshot, [string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))
    $configuration = Get-OrfConfiguration ([IO.Path]::GetFullPath($ProjectRoot))
    if ($Action -eq 'capture') { $null = Invoke-OrfCapture $configuration; return }
    if (-not $Snapshot) { throw 'Snapshot path is required' }
    $path = [IO.Path]::GetFullPath($Snapshot); $snap = Read-OrfSnapshot $path $configuration
    $state = Join-Path (Split-Path -Parent $path) 'restore-plan.json'
    switch ($Action) {
        'preflight' { $null = Invoke-OrfPreflight $configuration $snap $state }
        'restore' { Invoke-OrfRestore $configuration $snap $state; Invoke-OrfValidate $configuration $snap $state }
        'validate' { Invoke-OrfValidate $configuration $snap $state }
    }
}
