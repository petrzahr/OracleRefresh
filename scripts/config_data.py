#!/usr/bin/env python3
"""Capture, restore and validate selected Oracle TEST settings through SQL*Plus."""
import argparse
import csv
from collections import Counter
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IDENT = re.compile(r'^[A-Za-z][A-Za-z0-9_$#]*$')
TYPES = {'VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR', 'NUMBER', 'DATE', 'TIMESTAMP', 'TIMESTAMP WITH TIME ZONE', 'TIMESTAMP WITH LOCAL TIME ZONE'}

def normalized_type(value):
    match = re.fullmatch(r'TIMESTAMP\(\d\)( WITH (LOCAL )?TIME ZONE)?', value)
    return 'TIMESTAMP' + (match.group(1) or '') if match else value

def fail(message):
    raise ValueError(message)

def identifier(value):
    if not isinstance(value, str) or not IDENT.fullmatch(value):
        fail('Invalid Oracle identifier: ' + repr(value))
    return value.upper()

def quoted(value):
    if not isinstance(value, str) or '\x00' in value:
        fail('Invalid string value')
    return "'" + value.replace("'", "''") + "'"

def load_config():
    db = json.loads((ROOT / 'config/database.json').read_text(encoding='utf-8'))
    credentials = json.loads((ROOT / 'config/credentials.json').read_text(encoding='utf-8'))
    users = credentials.get('users')
    if not isinstance(users, dict):
        fail('credentials.json requires a users object')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', db['tnsAlias']):
        fail('Invalid TNS alias')
    if not isinstance(db.get('timeoutSeconds', 300), int) or isinstance(db.get('timeoutSeconds'), bool) or db.get('timeoutSeconds', 300) <= 0:
        fail('timeoutSeconds must be a positive integer')
    target = db.get('expectedTarget')
    if not isinstance(target, dict) or set(target) != {'dbUniqueName', 'serviceName', 'conName'} or any(
            not isinstance(v, str) or not re.fullmatch(r'[A-Za-z0-9_.$#-]+', v) for v in target.values()):
        fail('database.json requires expectedTarget: dbUniqueName, serviceName, conName')
    configs = [p for p in (ROOT / 'config/schemas').glob('*.json') if not p.name.endswith('.example.json')]
    if not configs:
        fail('No schema JSON files found')
    by_user = {identifier(path.stem): path for path in configs}
    schema_order = db.get('schemaOrder')
    if not isinstance(schema_order, list) or len(schema_order) != len(configs) or any(not isinstance(x, str) for x in schema_order):
        fail('database.json must list every schema once in schemaOrder')
    schema_order = [identifier(x) for x in schema_order]
    if len(set(schema_order)) != len(schema_order) or set(schema_order) != set(by_user):
        fail('schemaOrder must match schema JSON filenames exactly')
    db['schemaOrder'] = schema_order
    schemas = []
    for user in schema_order:
        path = by_user[user]
        cfg = json.loads(path.read_text(encoding='utf-8'))
        kinds = {'restoreRows': 'objects', 'replaceTable': 'fullTables', 'update': 'updates', 'delete': 'deletes'}
        steps = cfg.pop('steps', None)
        if not isinstance(steps, list) or not steps or any(k in cfg for k in kinds.values()):
            fail(f'{path.name}: use one nonempty steps array; do not mix legacy arrays')
        plan = []
        for kind in kinds.values():
            cfg[kind] = []
        for step in steps:
            if not isinstance(step, dict) or step.get('type') not in kinds:
                fail(f'{path.name}: invalid step type')
            kind = kinds[step['type']]
            item = {k: v for k, v in step.items() if k != 'type'}
            plan.append({'type': step['type'], 'index': len(cfg[kind])})
            cfg[kind].append(item)
        cfg['_steps'] = plan
        if 'username' in cfg or 'password' in cfg:
            fail(f'{path.name}: put username and password only in credentials.json')
        account = users.get(user)
        if not isinstance(account, dict) or account.get('username') != user or not isinstance(account.get('password'), str) or not account['password'] or any(c in account['password'] for c in ['\n', '\r', '\x00']):
            fail(f'{user}: missing or invalid entry in credentials.json')
        cfg['username'] = user
        cfg['password'] = account['password']
        if not any(cfg.get(kind) for kind in ('objects', 'fullTables', 'deletes', 'updates')):
            fail(f'{user}: no configured operations')
        primary = [identifier(o['table']) for o in cfg.get('objects', []) + cfg.get('fullTables', [])]
        if len(primary) != len(set(primary)):
            fail(f'{user}: objects and fullTables cannot overlap')
        for kind in ('deletes', 'updates'):
            names = [identifier(o['table']) for o in cfg.get(kind, [])]
            if set(names) & set(primary):
                fail(f'{user}: {kind} cannot overlap with restoreRows/replaceTable')
        for update in cfg.get('updates', []):
            identifier(update['table'])
            keys = update.get('key')
            if not isinstance(keys, list) or not keys or len({identifier(k) for k in keys}) != len(keys):
                fail('Every UPDATE requires a nonempty, unique key list')
            if 'backupMaxRows' in update and (not isinstance(update['backupMaxRows'], int) or isinstance(update['backupMaxRows'], bool) or update['backupMaxRows'] < 0):
                fail(f'{user}.{update["table"]}: invalid backupMaxRows')
            match, values = update.get('match'), update.get('set')
            if ('match' in update and (not isinstance(match, dict) or not match)) or not isinstance(values, dict) or not values:
                fail(f'{user}.{update["table"]}: UPDATE requires a nonempty set and, when present, a nonempty match object')
            for name, mapping in (('match', match or {}), ('set', values)):
                if len({identifier(k) for k in mapping}) != len(mapping):
                    fail('Duplicate column after identifier normalization')
                for col, value in mapping.items():
                    identifier(col)
                    if value is not None and (not isinstance(value, (str, int, float)) or isinstance(value, bool)):
                        fail(f'{user}.{update["table"]}: invalid {name} value')
            if {identifier(k) for k in keys} & {identifier(k) for k in values}:
                fail('UPDATE cannot modify its stable key')
            if 'expectedRows' in update and (not isinstance(update['expectedRows'], int) or isinstance(update['expectedRows'], bool) or update['expectedRows'] < 0):
                fail(f'{user}.{update["table"]}: invalid expectedRows')
        table_keys = {}
        for update in cfg.get('updates', []):
            table, keys = identifier(update['table']), [identifier(k) for k in update['key']]
            if table in table_keys and table_keys[table] != keys:
                fail('UPDATE steps for the same table must use the same stable key')
            table_keys[table] = keys
        for deletion in cfg.get('deletes', []):
            identifier(deletion['table'])
            limit = deletion.get('maxDeleteRows')
            if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
                fail('Every DELETE requires a nonnegative maxDeleteRows')
            if 'backupMaxRows' in deletion and (not isinstance(deletion['backupMaxRows'], int) or isinstance(deletion['backupMaxRows'], bool) or deletion['backupMaxRows'] < 0):
                fail(f'{user}.{deletion["table"]}: invalid backupMaxRows')
            match = deletion.get('match')
            if not isinstance(match, dict) or not match:
                fail(f'{user}.{deletion["table"]}: deletes requires a nonempty match object')
            if any(v is not None and (not isinstance(v, (str, int, float)) or isinstance(v, bool)) for v in match.values()):
                fail(f'{user}.{deletion["table"]}: invalid match value')
            for col in match:
                identifier(col)
        for full in cfg.get('fullTables', []):
            identifier(full['table'])
            limit = full.get('maxDeleteRows')
            if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
                fail('Every replaceTable requires a nonnegative maxDeleteRows for the target')
            if 'maxRows' in full and (not isinstance(full['maxRows'], int) or isinstance(full['maxRows'], bool) or full['maxRows'] < 0):
                fail(f'{user}.{full["table"]}: invalid maxRows')
            if 'expectedRows' in full and (not isinstance(full['expectedRows'], int) or isinstance(full['expectedRows'], bool) or full['expectedRows'] < 0 or ('maxRows' in full and full['expectedRows'] > full['maxRows'])):
                fail(f'{user}.{full["table"]}: invalid expectedRows')
        for obj in cfg.get('objects', []):
            identifier(obj['table'])
            if 'expectedRows' in obj and (not isinstance(obj['expectedRows'], int) or isinstance(obj['expectedRows'], bool) or obj['expectedRows'] < 0):
                fail('Invalid restoreRows expectedRows')
            if 'backupMaxRows' in obj and (not isinstance(obj['backupMaxRows'], int) or isinstance(obj['backupMaxRows'], bool) or obj['backupMaxRows'] < 0):
                fail(f'{user}.{obj["table"]}: invalid backupMaxRows')
            keys = [identifier(x) for x in obj['key']]
            all_rows = obj.get('allRows', False)
            if not isinstance(all_rows, bool):
                fail(f'{user}.{obj["table"]}: allRows must be boolean')
            if all_rows and ('keyValues' in obj or 'expectedRows' in obj):
                fail(f'{user}.{obj["table"]}: allRows uses every key; omit keyValues and expectedRows')
            cols = [identifier(x) for x in obj['columns']]
            if not keys or not cols or len(set(keys + cols)) != len(keys + cols):
                fail(f'{user}.{obj["table"]}: invalid/duplicate columns')
            if 'where' in obj:
                fail('Free-form WHERE is not supported; use keyValues')
            if all_rows:
                continue
            if not isinstance(obj.get('keyValues'), list) or not obj['keyValues']:
                fail(f'{user}.{obj["table"]}: supply explicit keyValues')
            for values in obj['keyValues']:
                if len(values) != len(keys) or any(v is None or not isinstance(v, (str, int, float)) or isinstance(v, bool) for v in values):
                    fail(f'{user}.{obj["table"]}: invalid keyValues')
        schemas.append(cfg)
    if any(k in db for k in ('fullTableRestoreOrder', 'updateOrder', 'deleteOrder')):
        fail('Use schemaOrder and per-schema steps; remove legacy order lists')
    return db, schemas

def target_guard(db, cfg):
    fields = {'dbUniqueName': 'DB_UNIQUE_NAME', 'serviceName': 'SERVICE_NAME', 'conName': 'CON_NAME'}
    checks = [f"NVL(UPPER(SYS_CONTEXT('USERENV', '{field}')), '?') <> {quoted(db['expectedTarget'][key].upper())}"
              for key, field in fields.items()]
    checks.append(f"SYS_CONTEXT('USERENV', 'SESSION_USER') <> {quoted(cfg['username'])}")
    return ('BEGIN IF ' + ' OR '.join(checks) +
            " THEN RAISE_APPLICATION_ERROR(-20010, 'Target database or account mismatch'); END IF; END;\n/\n")


def sqlplus(db, cfg, script):
    exe = db.get('sqlplusPath', 'sqlplus')
    # Credentials never appear in the process command line or log. SQL*Plus reads CONNECT from stdin.
    password = cfg['password'].replace('"', '""')
    if any(c in password for c in ['\x00']):
        fail('Unsupported password character')
    header = ('whenever oserror exit failure rollback\nwhenever sqlerror exit failure rollback\n'
              'set define off echo off verify off\n'
              f'connect {cfg["username"]}/"{password}"@{db["tnsAlias"]}\n'
              'set heading off feedback off verify off echo off define off pagesize 0 linesize 32767 trimspool on tab off\n'
              'set sqlblanklines on serveroutput on size unlimited format wrapped\n'
              "alter session set nls_numeric_characters='.,';\n"
              "alter session set nls_calendar='GREGORIAN';\n" + target_guard(db, cfg))
    env = {**os.environ, 'NLS_LANG': '.AL32UTF8', 'ORA_NCHAR_LITERAL_REPLACE': 'TRUE'}
    proc = subprocess.run([exe, '-L', '-S', '/nolog'], input=header + script + '\nexit rollback\n',
                          text=True, encoding='utf-8', errors='strict', env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=db.get('timeoutSeconds', 300))
    output = proc.stdout + proc.stderr
    errors = re.findall(r'(?m)^\s*((?:ORA-|SP2-|PLS-)\d+)', output)
    if proc.returncode or errors:
        # Do not echo SQL, connection text, or captured configuration values into logs.
        fail(f'SQL*Plus failed for {cfg["username"]}: return code {proc.returncode}; errors {errors}')
    return output

def metadata(db, cfg, table, names):
    values = ','.join(quoted(x) for x in names)
    q = ("SELECT 'META|' || column_name || '|' || data_type FROM user_tab_columns "
         f"WHERE table_name = {quoted(table)} AND column_name IN ({values}) ORDER BY column_id;\n")
    lines = [line.strip()[5:].split('|', 1) for line in sqlplus(db, cfg, q).splitlines() if line.strip().startswith('META|')]
    result = {name: normalized_type(typ) for name, typ in lines}
    if set(result) != set(names) or any(t not in TYPES for t in result.values()):
        fail(f'{cfg["username"]}.{table}: missing column or unsupported type: {result}')
    return result

def full_metadata(db, cfg, table):
    q = ("SELECT 'META|' || column_name || '|' || data_type FROM user_tab_cols "
         f"WHERE table_name = {quoted(table)} AND virtual_column = 'NO' "
         "AND hidden_column = 'NO' ORDER BY column_id;\n")
    lines = [line.strip()[5:].split('|', 1) for line in sqlplus(db, cfg, q).splitlines() if line.strip().startswith('META|')]
    result = {name: normalized_type(typ) for name, typ in lines}
    if not result or len(result) != len(lines) or any(t not in TYPES or t == 'TIMESTAMP WITH LOCAL TIME ZONE' for t in result.values()):
        fail(f'{cfg["username"]}.{table}: empty table metadata or unsupported type: {result}')
    return result

def expression(col, typ):
    if typ == 'NUMBER':
        return f"TO_CHAR({col}, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''')"
    if typ == 'DATE':
        return f"TO_CHAR({col}, 'YYYY-MM-DD HH24:MI:SS')"
    if typ == 'TIMESTAMP':
        return f"TO_CHAR({col}, 'YYYY-MM-DD HH24:MI:SS.FF9')"
    if typ == 'TIMESTAMP WITH TIME ZONE':
        return f"TO_CHAR({col}, 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM')"
    if typ == 'TIMESTAMP WITH LOCAL TIME ZONE':
        fail('TIMESTAMP WITH LOCAL TIME ZONE requires an explicit timezone policy')
    return col

def literal(value, typ):
    if value is None:
        return 'NULL'
    if typ == 'NUMBER':
        if not re.fullmatch(r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?', str(value)):
            fail('Invalid numeric snapshot value')
        return str(value)
    if typ == 'DATE':
        return f"TO_DATE({literal(value, 'VARCHAR2')}, 'FXYYYY-MM-DD HH24:MI:SS')"
    if typ == 'TIMESTAMP':
        return f"TO_TIMESTAMP({literal(value, 'VARCHAR2')}, 'FXYYYY-MM-DD HH24:MI:SS.FF9')"
    if typ == 'TIMESTAMP WITH TIME ZONE':
        return f"TO_TIMESTAMP_TZ({literal(value, 'VARCHAR2')}, 'FXYYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM')"
    if not isinstance(value, str):
        fail('Character column requires a string or null')
    # Keep SQL*Plus control lines and blank lines out of literal input. Small
    # chunks also avoid its input-line limit for long UTF-8 strings.
    parts = []
    prefix = 'N' if typ in {'NCHAR', 'NVARCHAR2'} else ''
    for piece in re.split(r'([\r\n])', value):
        if piece in {'\r', '\n'}:
            parts.append(f"{'NCHR' if prefix else 'CHR'}({ord(piece)})")
        elif piece:
            parts.extend(prefix + quoted(piece[i:i + 200]) for i in range(0, len(piece), 200))
    if not parts:
        return 'NULL'
    result = '(' + '\n || '.join(parts) + ')'
    if len(parts) > 1 and typ in {'CHAR', 'NCHAR'}:
        cast = f'CHAR({len(value)} CHAR)' if typ == 'CHAR' else f'NCHAR({len(value)})'
        result = f'CAST({result} AS {cast})'
    return result

def predicate(keys, values, types):
    return ' AND '.join(f'{k} = {literal(v, types[k])}' for k, v in zip(keys, values))

def delete_predicate(match, types):
    return ' AND '.join(f'{identifier(key)} IS NULL' if value is None or value == '' else
                        f'{identifier(key)} = {literal(value, types[identifier(key)])}'
                        for key, value in match.items())


def captured_predicate(row, types):
    # Compare the exported representation, including timezone offsets. Oracle
    # timestamp equality alone would conflate equal instants with different offsets.
    return ' AND '.join(f'{col} IS NULL' if value is None else
                        f'{expression(col, types[col])} = {literal(value, types[col] if types[col] in {"CHAR", "VARCHAR2", "NCHAR", "NVARCHAR2"} else "VARCHAR2")}'
                        for col, value in row.items())

def query_rows(db, cfg, obj, types):
    table = identifier(obj['table'])
    names = [identifier(x) for x in obj['key'] + obj['columns']]
    fields = ', '.join(f'{quoted(n)} VALUE {expression(n, types[n])}' for n in names)
    keys = [identifier(x) for x in obj['key']]
    rows = []
    for keyvals in obj['keyValues']:
        clause = predicate(keys, keyvals, types)
        # JSON_OBJECT handles NULL, quoting, control characters and apostrophes.
        json_expr = f'JSON_OBJECT({fields} NULL ON NULL RETURNING CLOB)'
        sql = ("set serveroutput on size unlimited\n"
               "DECLARE v_json VARCHAR2(32767); v_count NUMBER := 0; BEGIN\n"
               f"FOR r IN (SELECT {json_expr} AS j FROM {table} WHERE {clause}) LOOP\n"
               "v_count := v_count + 1; IF v_count > 1 THEN RAISE_APPLICATION_ERROR(-20001, 'Duplicate key'); END IF;\n"
               "IF DBMS_LOB.GETLENGTH(r.j) > 32763 THEN RAISE_APPLICATION_ERROR(-20005, 'JSON row too large'); END IF;\n"
               "v_json := DBMS_LOB.SUBSTR(r.j, 32763, 1); DBMS_OUTPUT.PUT_LINE('ROW|' || v_json); END LOOP;\n"
               "IF v_count != 1 THEN RAISE_APPLICATION_ERROR(-20002, 'Missing key'); END IF; END;\n/\n")
        output = sqlplus(db, cfg, sql)
        found = [json.loads(line.strip()[4:]) for line in output.splitlines() if line.strip().startswith('ROW|')]
        if len(found) != 1:
            fail(f'{cfg["username"]}.{table}: expected one captured row for {keyvals}')
        rows.append(found[0])
    if 'expectedRows' in obj and obj['expectedRows'] != len(rows):
        fail(f'{cfg["username"]}.{table}: expectedRows mismatch')
    return rows

def query_full_table(db, cfg, table, types, max_rows, where=None):
    fields = ', '.join(f'{quoted(n)} VALUE {expression(n, typ)}' for n, typ in types.items())
    json_expr = f'JSON_OBJECT({fields} NULL ON NULL RETURNING CLOB)'
    sql = ("set serveroutput on size unlimited\n"
           "DECLARE v_count NUMBER := 0; BEGIN\n"
           f"FOR r IN (SELECT {json_expr} AS j FROM {table}{' WHERE ' + where if where else ''}) LOOP\n"
           "v_count := v_count + 1;\n"
           + (f"IF v_count > {max_rows} THEN RAISE_APPLICATION_ERROR(-20004, 'Full-table maxRows exceeded'); END IF;\n" if max_rows is not None else '') +
           "IF DBMS_LOB.GETLENGTH(r.j) > 32763 THEN RAISE_APPLICATION_ERROR(-20005, 'JSON row too large'); END IF;\n"
           "DBMS_OUTPUT.PUT_LINE('ROW|' || DBMS_LOB.SUBSTR(r.j, 32763, 1)); END LOOP;\n"
           "DBMS_OUTPUT.PUT_LINE('COUNT|' || v_count); END;\n/\n")
    output = sqlplus(db, cfg, sql)
    rows = [json.loads(line.strip()[4:]) for line in output.splitlines() if line.strip().startswith('ROW|')]
    counts = [int(line.strip()[6:]) for line in output.splitlines() if line.strip().startswith('COUNT|')]
    if counts != [len(rows)]:
        fail(f'{cfg["username"]}.{table}: incomplete full-table output')
    return rows

def write_table_backups(root, user, table, keys, cols, types, rows):
    """Export exactly the captured columns and rows, alongside the JSON snapshot."""
    directory = root / user
    directory.mkdir(parents=True, exist_ok=True)
    names = keys + cols
    csv_path = directory / f'{table}.csv'
    sql_path = directory / f'{table}.insert.sql'
    with csv_path.open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.writer(stream)
        # Flags make SQL NULL distinct from an empty string in the CSV export.
        writer.writerow(names + [f'{name}__IS_NULL' for name in names])
        for row in rows:
            writer.writerow([row[name] if row[name] is not None else '' for name in names] +
                            [int(row[name] is None) for name in names])
    sql_path.write_text(render_insert_backup(user, table, names, types, rows), encoding='utf-8')
    return [csv_path, sql_path]

def render_insert_backup(user, table, names, types, rows):
    lines = [f'-- Captured rows for {user}.{table}; manual recovery aid.',
             '-- Intended for an empty target or rows removed beforehand.',
             'WHENEVER SQLERROR EXIT FAILURE ROLLBACK', 'SET DEFINE OFF', 'SET SQLBLANKLINES ON',
             "ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,';"]
    for row in rows:
        values = ', '.join(literal(row[name], types[name]) for name in names)
        lines.append(f'INSERT INTO {user}.{table} ({", ".join(names)}) VALUES ({values});')
    lines.append('-- Review the result and COMMIT explicitly; otherwise ROLLBACK.')
    return '\n'.join(lines) + '\n'

def verify_capture_artifacts(root, db, schemas, snapshot, inventory, backup_files):
    path = root / 'snapshot.json'
    if read_snapshot(path, db, schemas) != snapshot:
        fail('Snapshot read-back differs from captured data')
    expected_tables = {(cfg['username'], identifier(step['table']))
                       for cfg in schemas for kind in ('objects', 'fullTables', 'updates', 'deletes')
                       for step in cfg[kind]}
    if set(inventory) != expected_tables or len(backup_files) != 2 * len(expected_tables):
        fail('Full-table backup inventory is incomplete')
    manifest_lines = (root / 'backups.sha256').read_text(encoding='ascii').splitlines()
    if len(manifest_lines) != len(backup_files):
        fail('Incomplete backup checksum manifest')
    for file, line in zip(backup_files, manifest_lines):
        expected_hash, separator, relative = line.partition('  ')
        if not separator or relative != file.relative_to(root).as_posix() or len(expected_hash) != 64:
            fail('Backup manifest entry mismatch')
        if hashlib.sha256(file.read_bytes()).hexdigest() != expected_hash:
            fail(f'Backup read-back checksum mismatch: {relative}')
    for (user, table), (types, rows) in inventory.items():
        names = list(types)
        csv_path = root / user / f'{table}.csv'
        with csv_path.open('r', encoding='utf-8-sig', newline='') as stream:
            reader = csv.reader(stream)
            header = next(reader, None)
            actual = list(reader)
        expected = [[str(row[name]) if row[name] is not None else '' for name in names] +
                    [str(int(row[name] is None)) for name in names] for row in rows]
        if header != names + [f'{name}__IS_NULL' for name in names] or actual != expected:
            fail(f'{user}.{table}: CSV read-back differs from captured table')
        sql_path = root / user / f'{table}.insert.sql'
        if sql_path.read_text(encoding='utf-8') != render_insert_backup(user, table, names, types, rows):
            fail(f'{user}.{table}: INSERT backup read-back differs from captured table')
    print(f'Capture verification: {len(inventory)} full-table backups and snapshot OK')

def capture(db, schemas):
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    root = ROOT / 'snapshots' / stamp
    root.mkdir(parents=True, exist_ok=False)
    snapshot = {'version': 2, 'configHash': config_hash(db, schemas), 'capturedAt': stamp,
                'tnsAlias': db['tnsAlias'], 'status': 'INCOMPLETE', 'schemas': []}
    backup_files = []
    inventory = {}
    path = root / 'snapshot.json'
    try:
        for cfg in schemas:
            user = identifier(cfg['username'])
            entry = {'username': user, 'objects': [], 'fullTables': [], 'deletes': [], 'updates': [], 'layouts': {}}
            for kind in ('objects', 'fullTables', 'deletes', 'updates'):
                for item in cfg[kind]:
                    table = identifier(item['table'])
                    if table not in entry['layouts']:
                        entry['layouts'][table] = table_layout(db, cfg, table)
            backed_up = set()
            for obj in cfg.get('objects', []):
                table = identifier(obj['table'])
                keys = [identifier(x) for x in obj['key']]
                backup_types = full_metadata(db, cfg, table)
                backup_rows = query_full_table(db, cfg, table, backup_types, obj.get('backupMaxRows'))
                if obj.get('allRows', False):
                    cols = [identifier(x) for x in obj['columns']]
                    if not set(keys + cols) <= set(backup_types):
                        fail(f'{user}.{table}: key/value column missing')
                    seen = set()
                    for row in backup_rows:
                        key_tuple = tuple(row[k] for k in keys)
                        if None in key_tuple or key_tuple in seen:
                            fail(f'{user}.{table}: allRows requires non-null, unique keys')
                        seen.add(key_tuple)
                    types = {name: backup_types[name] for name in keys + cols}
                    rows = [{name: row[name] for name in keys + cols} for row in backup_rows]
                else:
                    cols = [identifier(x) for x in obj['columns']]
                    types = metadata(db, cfg, table, keys + cols)
                    rows = query_rows(db, cfg, obj, types)
                entry['objects'].append({'table': table, 'key': keys, 'columns': cols, 'types': types,
                                         'rows': rows, 'allRows': obj.get('allRows', False),
                                         'backupMaxRows': obj.get('backupMaxRows')})
                backup_files.extend(write_table_backups(root, user, table, [], list(backup_types), backup_types, backup_rows))
                inventory[(user, table)] = (backup_types, backup_rows)
                backed_up.add(table)
                print(f'{user}.{table}: {len(rows)} restore rows; {len(backup_rows)} full-table backup rows')
            for full in cfg.get('fullTables', []):
                table = identifier(full['table'])
                types = full_metadata(db, cfg, table)
                rows = query_full_table(db, cfg, table, types, full.get('maxRows'))
                if 'expectedRows' in full and len(rows) != full['expectedRows']:
                    fail(f'{user}.{table}: full-table expectedRows mismatch')
                if len(rows) > full['maxDeleteRows']:
                    fail(f'{user}.{table}: maxDeleteRows must also allow deleting restored rows on a retry')
                entry['fullTables'].append({'table': table, 'types': types, 'rows': rows,
                                            'maxRows': full.get('maxRows'), 'expectedRows': full.get('expectedRows'),
                                            'maxDeleteRows': full['maxDeleteRows']})
                backup_files.extend(write_table_backups(root, user, table, [], list(types), types, rows))
                inventory[(user, table)] = (types, rows)
                backed_up.add(table)
                print(f'{user}.{table}: {len(rows)} full-table rows captured')
            for deletion in cfg.get('deletes', []):
                table = identifier(deletion['table'])
                types = full_metadata(db, cfg, table)
                match = {identifier(k): v for k, v in deletion['match'].items()}
                if not set(match) <= set(types):
                    fail(f'{user}.{table}: delete match column missing')
                rows = query_full_table(db, cfg, table, types, deletion.get('backupMaxRows'))
                entry['deletes'].append({'table': table, 'match': match, 'types': {k: types[k] for k in match},
                                         'maxDeleteRows': deletion['maxDeleteRows'],
                                         'backupMaxRows': deletion.get('backupMaxRows')})
                if table not in backed_up:
                    backup_files.extend(write_table_backups(root, user, table, [], list(types), types, rows))
                    inventory[(user, table)] = (types, rows)
                    backed_up.add(table)
                print(f'{user}.{table}: {len(rows)} full-table backup rows for DELETE')
            for update in cfg.get('updates', []):
                table = identifier(update['table'])
                types = full_metadata(db, cfg, table)
                match = {identifier(k): v for k, v in update.get('match', {}).items()}
                values = {identifier(k): v for k, v in update['set'].items()}
                keys = [identifier(k) for k in update['key']]
                if not (set(match) | set(values) | set(keys)) <= set(types):
                    fail(f'{user}.{table}: UPDATE column missing')
                check_keys(db, cfg, table, keys)
                if table not in backed_up:
                    rows = query_full_table(db, cfg, table, types, update.get('backupMaxRows'))
                    backup_files.extend(write_table_backups(root, user, table, [], list(types), types, rows))
                    inventory[(user, table)] = (types, rows)
                    backed_up.add(table)
                    print(f'{user}.{table}: {len(rows)} full-table backup rows for UPDATE')
                if update.get('backupMaxRows') is not None and len(inventory[(user, table)][1]) > update['backupMaxRows']:
                    fail(f'{user}.{table}: backupMaxRows exceeded')
                entry['updates'].append({'table': table, 'match': match, 'set': values,
                                         'key': keys,
                                         'types': {k: types[k] for k in list(match) + list(values) + keys},
                                         'expectedRows': update.get('expectedRows'),
                                         'backupMaxRows': update.get('backupMaxRows')})
            entry['steps'] = cfg['_steps']
            snapshot['schemas'].append(entry)
        snapshot['schemaOrder'] = db['schemaOrder']
        snapshot['status'] = 'SUCCESS'
        path.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding='utf-8')
        (root / 'snapshot.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '\n', encoding='ascii')
        (root / 'backups.sha256').write_text(''.join(
            f'{hashlib.sha256(item.read_bytes()).hexdigest()}  {item.relative_to(root).as_posix()}\n'
            for item in backup_files), encoding='ascii')
        verify_capture_artifacts(root, db, schemas, snapshot, inventory, backup_files)
        print(f'CAPTURE SUCCESS: {root}')
    except Exception:
        if path.exists():
            try:
                snapshot['status'] = 'FAILED'
                path.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding='utf-8')
                (root / 'snapshot.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '\n', encoding='ascii')
            except Exception:
                path.unlink(missing_ok=True)
                (root / 'snapshot.sha256').unlink(missing_ok=True)
        print(f'CAPTURE FAILED: incomplete output at {root}', file=sys.stderr)
        raise

def read_snapshot(path, db, schemas):
    path = path.resolve()
    raw = path.read_bytes()
    expected = (path.parent / 'snapshot.sha256').read_text(encoding='ascii').strip()
    if hashlib.sha256(raw).hexdigest() != expected:
        fail('Snapshot checksum mismatch')
    snap = json.loads(raw)
    if snap.get('version') != 2 or snap.get('configHash') != config_hash(db, schemas):
        fail('Snapshot version/configuration mismatch; capture a new version 2 snapshot')
    if snap['status'] != 'SUCCESS' or snap['tnsAlias'] != db['tnsAlias']:
        fail('Incomplete snapshot or TNS alias mismatch')
    if [x['username'] for x in snap['schemas']] != [identifier(c['username']) for c in schemas]:
        fail('Schema list changed since capture')
    if snap.get('schemaOrder') != db['schemaOrder']:
        fail('Schema order changed since capture')
    for recorded, cfg in zip(snap['schemas'], schemas):
        if recorded.get('steps') != cfg['_steps']:
            fail('Step order changed since capture')
        if len(recorded['objects']) != len(cfg.get('objects', [])) or len(recorded.get('fullTables', [])) != len(cfg.get('fullTables', [])) or len(recorded.get('deletes', [])) != len(cfg.get('deletes', [])) or len(recorded.get('updates', [])) != len(cfg.get('updates', [])):
            fail('Object list changed since capture')
        for obj, current in zip(recorded['objects'], cfg.get('objects', [])):
            if obj['table'] != identifier(current['table']) or obj['key'] != [identifier(x) for x in current['key']] or obj.get('allRows', False) != current.get('allRows', False) or obj.get('backupMaxRows') != current.get('backupMaxRows'):
                fail('Capture configuration changed since snapshot')
            if obj.get('allRows', False):
                if obj['columns'] != [identifier(x) for x in current['columns']] or any(set(row) != set(obj['types']) for row in obj['rows']):
                    fail('allRows snapshot columns mismatch')
                continue
            if obj['columns'] != [identifier(x) for x in current['columns']] or [[str(row[k]) if row[k] is not None else None for k in obj['key']] for row in obj['rows']] != [[str(v) if v is not None else None for v in values] for values in current['keyValues']]:
                fail('Capture configuration changed since snapshot')
        for full, current in zip(recorded.get('fullTables', []), cfg.get('fullTables', [])):
            if full['table'] != identifier(current['table']) or full.get('maxRows') != current.get('maxRows') or full['expectedRows'] != current.get('expectedRows') or (full.get('maxRows') is not None and len(full['rows']) > full['maxRows']):
                fail('Full-table configuration changed since snapshot')
            if any(set(row) != set(full['types']) for row in full['rows']):
                fail('Full-table snapshot columns mismatch')
        for deletion, current in zip(recorded.get('deletes', []), cfg.get('deletes', [])):
            if deletion['table'] != identifier(current['table']) or deletion['match'] != {identifier(k): v for k, v in current['match'].items()} or deletion.get('backupMaxRows') != current.get('backupMaxRows'):
                fail('Delete configuration changed since capture')
        for update, current in zip(recorded.get('updates', []), cfg.get('updates', [])):
            if update['table'] != identifier(current['table']) or update['match'] != {identifier(k): v for k, v in current.get('match', {}).items()} or update['set'] != {identifier(k): v for k, v in current['set'].items()} or update['expectedRows'] != current.get('expectedRows') or update.get('backupMaxRows') != current.get('backupMaxRows'):
                fail('Fixed UPDATE configuration changed since capture')
    return snap

def config_hash(db, schemas):
    config = {'tnsAlias': db['tnsAlias'], 'expectedTarget': db['expectedTarget'],
              'schemaOrder': db['schemaOrder'],
              'schemas': [{k: v for k, v in cfg.items() if k != 'password'} for cfg in schemas]}
    return digest(config)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode('utf-8')).hexdigest()


def table_layout(db, cfg, table):
    fields = {'name': 'column_name', 'type': 'data_type', 'bytes': 'data_length',
              'precision': 'data_precision', 'scale': 'data_scale', 'chars': 'char_length',
              'charUsed': 'char_used', 'nullable': 'nullable', 'identity': 'identity_column',
              'virtual': 'virtual_column', 'hidden': 'hidden_column', 'defaultOnNull': 'default_on_null'}
    pairs = ', '.join(f"'{key}' VALUE {column}" for key, column in fields.items())
    sql = (f"SELECT 'LAYOUT|' || JSON_OBJECT({pairs} NULL ON NULL) FROM user_tab_cols "
           f"WHERE table_name = {quoted(table)} AND user_generated = 'YES' ORDER BY internal_column_id;\n")
    rows = [json.loads(line.strip()[7:]) for line in sqlplus(db, cfg, sql).splitlines()
            if line.strip().startswith('LAYOUT|')]
    if not rows:
        fail(f'{cfg["username"]}.{table}: table layout missing')
    return {row.pop('name'): row for row in rows}


def scalar(db, cfg, query):
    output = sqlplus(db, cfg, f"SELECT 'CHECK|' || ({query}) FROM dual;\n")
    values = [int(line.strip()[6:]) for line in output.splitlines() if line.strip().startswith('CHECK|')]
    if len(values) != 1:
        fail('Missing or ambiguous database count')
    return values[0]


def check_keys(db, cfg, table, keys):
    nulls = ' OR '.join(f'{k} IS NULL' for k in keys)
    query = (f'SELECT COUNT(*) FROM (SELECT {", ".join(keys)} FROM {table} '
             f'GROUP BY {", ".join(keys)} HAVING COUNT(*) > 1 OR {nulls})')
    if scalar(db, cfg, query):
        fail(f'{cfg["username"]}.{table}: stable keys must be unique and non-null')


def check_update_count(update, count):
    expected = update.get('expectedRows')
    if (expected is not None and count != expected) or (expected is None and update['match'] and count == 0):
        fail(f'{update["table"]}: unexpected UPDATE row count: {count}')


def replacement_dependencies(db, cfg, entry):
    tables = [entry['fullTables'][step['index']]['table'] for step in entry['steps'] if step['type'] == 'replaceTable']
    if not tables:
        return
    # DBA_CONSTRAINTS is deliberate: ALL_CONSTRAINTS can hide incoming foreign
    # keys from schemas to which this account has no object privileges.
    sql = ("SELECT 'FK|' || c.owner || '|' || c.table_name || '|' || p.table_name "
           'FROM sys.dba_constraints c JOIN sys.dba_constraints p '
           'ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name '
           f"WHERE c.constraint_type = 'R' AND c.status = 'ENABLED' AND p.owner = {quoted(cfg['username'])} "
           f"AND p.table_name IN ({','.join(quoted(t) for t in tables)});\n")
    for line in sqlplus(db, cfg, sql).splitlines():
        if not line.strip().startswith('FK|'):
            continue
        owner, child, parent = line.strip()[3:].split('|')
        if owner != cfg['username'] or child not in tables or tables.index(child) <= tables.index(parent):
            fail(f'{owner}.{child} -> {cfg["username"]}.{parent}: replacement requires children '
                 'in the same schema, with parent-first insert order; cross-schema/self/cyclic FKs need DBA handling')


def value_checks(table, values, layout):
    checks = []
    for col, value in values.items():
        info = layout[col]
        typ = normalized_type(info['type'])
        expr = literal(value, typ)
        bad = []
        if info['nullable'] == 'N':
            bad.append(f'{expr} IS NULL')
        if typ in {'VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR'}:
            national = typ in {'NVARCHAR2', 'NCHAR'}
            function = 'LENGTH' if national or info['charUsed'] == 'C' else 'LENGTHB'
            size = info['chars'] if function == 'LENGTH' else info['bytes']
            bad.append(f'{function}({expr}) > {size}')
        elif typ == 'NUMBER' and (info['precision'] is not None or info['scale'] is not None):
            cast = f"NUMBER({info['precision'] or 38},{info['scale'] or 0})"
            bad.append(f'CAST({expr} AS {cast}) <> {expr}')
        if bad:
            checks.append(f"SELECT COUNT(*) INTO v_count FROM dual WHERE {' OR '.join(bad)};\n"
                          f"IF v_count <> 0 THEN RAISE_APPLICATION_ERROR(-20011, '{table}.{col}: value does not fit'); END IF;")
        # Evaluate conversion even for nullable DATE/TIMESTAMP columns.
        checks.append(f'SELECT COUNT(*) INTO v_count FROM dual WHERE {expr} IS NULL;')
    return '\n'.join(checks)


def load_restore_plan(path, snap, db):
    if path is None or not path.exists():
        return None
    wrapper = json.loads(path.read_text(encoding='utf-8'))
    plan = wrapper['plan']
    if wrapper.get('sha256') != digest(plan) or plan.get('snapshotHash') != digest(snap) or plan.get('target') != db['expectedTarget']:
        fail('Restore plan checksum/snapshot/target mismatch')
    return plan


def save_restore_plan(path, plan):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as stream:
        tmp = Path(stream.name)
        json.dump({'sha256': digest(plan), 'plan': plan}, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def preflight(db, schemas, snap, state_path=None):
    previous = load_restore_plan(state_path, snap, db)
    plan = previous or {'snapshotHash': digest(snap), 'target': db['expectedTarget'], 'schemas': []}
    for schema_index, (cfg, entry) in enumerate(zip(schemas, snap['schemas'])):
        for table, captured in entry['layouts'].items():
            if table_layout(db, cfg, table) != captured:
                fail(f'{cfg["username"]}.{table}: layout changed (type/length/precision/nullability/identity)')
            if scalar(db, cfg, f"SELECT COUNT(*) FROM user_triggers WHERE table_name = {quoted(table)} AND status = 'ENABLED'"):
                fail(f'{table}: enabled triggers require DBA handling before restore')
        replacement_dependencies(db, cfg, entry)
        for full in entry['fullTables']:
            layout = entry['layouts'][full['table']]
            if any(c['identity'] == 'YES' or c['hidden'] == 'YES' for c in layout.values()):
                fail(f'{full["table"]}: replaceTable does not support identity or invisible columns')
            count = scalar(db, cfg, f'SELECT COUNT(*) FROM {full["table"]}')
            if count > full['maxDeleteRows']:
                fail(f'{full["table"]}: maxDeleteRows exceeded ({count})')
        for obj in entry['objects']:
            layout = entry['layouts'][obj['table']]
            if any(layout[c]['identity'] == 'YES' or layout[c]['virtual'] == 'YES' for c in obj['columns']):
                fail('restoreRows cannot write identity or virtual columns')
            query_rows(db, cfg, {**obj, 'keyValues': [[r[k] for k in obj['key']] for r in obj['rows']]}, obj['types'])
        for deletion in entry['deletes']:
            where = delete_predicate(deletion['match'], deletion['types'])
            count = scalar(db, cfg, f'SELECT COUNT(*) FROM {deletion["table"]} WHERE {where}')
            if count > deletion['maxDeleteRows']:
                fail(f'{deletion["table"]}: maxDeleteRows exceeded ({count})')
        schema_plan = previous['schemas'][schema_index] if previous else {'updates': []}
        used = set()
        for index, update in enumerate(entry['updates']):
            table, keys = update['table'], update['key']
            layout = entry['layouts'][table]
            if any(layout[c]['identity'] == 'YES' or layout[c]['virtual'] == 'YES' for c in update['set']):
                fail('UPDATE cannot write identity or virtual columns')
            check_keys(db, cfg, table, keys)
            checks = value_checks(table, update['set'], layout)
            sqlplus(db, cfg, 'DECLARE v_count NUMBER; BEGIN\n' + checks + '\nEND;\n/\n')
            if previous:
                rows = schema_plan['updates'][index]['rows']
                query_rows(db, cfg, {'table': table, 'key': keys, 'columns': [],
                                    'keyValues': [[row[k] for k in keys] for row in rows]}, update['types'])
            else:
                where = delete_predicate(update['match'], update['types']) if update['match'] else None
                rows = query_full_table(db, cfg, table, {k: update['types'][k] for k in keys}, update['expectedRows'], where)
                schema_plan['updates'].append({'rows': rows})
            check_update_count(update, len(rows))
            for row in rows:
                marker = (table, tuple(keys), tuple(row[k] for k in keys))
                if marker in used:
                    fail(f'{table}: overlapping UPDATE steps are not supported')
                used.add(marker)
                for deletion in entry['deletes']:
                    if deletion['table'] != table:
                        continue
                    post_match = {k: update['set'].get(k, v) for k, v in deletion['match'].items()}
                    # Check deletion against the row after this UPDATE, using SQL
                    # comparisons so CHAR padding and Oracle NULL rules apply.
                    terms = []
                    for col, wanted in deletion['match'].items():
                        expr = literal(post_match[col], update['types'][col]) if col in update['set'] else col
                        typ = deletion['types'][col]
                        terms.append(f'{expr} IS NULL' if wanted is None or wanted == '' else f'{expr} = {literal(wanted, typ)}')
                    clause = predicate(keys, [row[k] for k in keys], update['types'])
                    original = delete_predicate(deletion['match'], deletion['types'])
                    both = f'({original}) OR ({" AND ".join(terms)})'
                    if scalar(db, cfg, f'SELECT COUNT(*) FROM {table} WHERE {clause} AND ({both})'):
                        fail(f'{table}: DELETE overlaps rows needed for UPDATE validation')
        if not previous:
            plan['schemas'].append(schema_plan)
    print('PREFLIGHT SUCCESS (read-only database checks)')
    return plan


def assert_count(query, expected, label):
    return (f'SELECT COUNT(*) INTO v_count FROM ({query});\n'
            f"IF v_count <> {expected} THEN RAISE_APPLICATION_ERROR(-20012, {quoted(label)}); END IF;")


def validation_statements(entry, schema_plan):
    statements = []
    for obj in entry['objects']:
        for row in obj['rows']:
            where = captured_predicate(row, obj['types'])
            statements.append(assert_count(f'SELECT 1 FROM {obj["table"]} WHERE {where}', 1,
                                           obj['table'] + ': restored row mismatch'))
    for full in entry['fullTables']:
        statements.append(assert_count(f'SELECT 1 FROM {full["table"]}', len(full['rows']),
                                       full['table'] + ': replacement count mismatch'))
        grouped = Counter(json.dumps(row, sort_keys=True) for row in full['rows'])
        for encoded, count in grouped.items():
            where = captured_predicate(json.loads(encoded), full['types'])
            statements.append(assert_count(f'SELECT 1 FROM {full["table"]} WHERE {where}', count,
                                           full['table'] + ': replacement value mismatch'))
    for deletion in entry['deletes']:
        where = delete_predicate(deletion['match'], deletion['types'])
        statements.append(assert_count(f'SELECT 1 FROM {deletion["table"]} WHERE {where}', 0,
                                       deletion['table'] + ': deleted rows remain'))
    for update, selected in zip(entry['updates'], schema_plan['updates']):
        check_update_count(update, len(selected['rows']))
        for row in selected['rows']:
            where = delete_predicate({**row, **update['set']}, update['types'])
            statements.append(assert_count(f'SELECT 1 FROM {update["table"]} WHERE {where}', 1,
                                           update['table'] + ': UPDATE key/value mismatch'))
        if not update['match']:
            statements.append(assert_count(f'SELECT 1 FROM {update["table"]}', len(selected['rows']),
                                           update['table'] + ': UPDATE table row count changed'))
    return statements


def schema_restore_sql(entry, schema_plan, first_attempt):
    statements = [f'LOCK TABLE {table} IN EXCLUSIVE MODE NOWAIT;' for table in sorted(entry['layouts'])]
    # Check original selectors under the same locks as the writes. On a retry,
    # selectors may have changed, so use the durable plan's original keys.
    if first_attempt:
        for update, selected in zip(entry['updates'], schema_plan['updates']):
            clause = ' WHERE ' + delete_predicate(update['match'], update['types']) if update['match'] else ''
            statements.append(assert_count(f'SELECT 1 FROM {update["table"]}{clause}', len(selected['rows']),
                                           update['table'] + ': UPDATE selection changed since preflight'))
            for row in selected['rows']:
                where = delete_predicate(row, update['types'])
                if update['match']:
                    where += ' AND ' + delete_predicate(update['match'], update['types'])
                statements.append(assert_count(f'SELECT 1 FROM {update["table"]} WHERE {where}', 1,
                                               update['table'] + ': UPDATE key selection changed'))
    for step in reversed(entry['steps']):
        if step['type'] == 'replaceTable':
            item = entry['fullTables'][step['index']]
            statements.append(f'DELETE FROM {item["table"]};')
            statements.append(f"IF SQL%ROWCOUNT > {item['maxDeleteRows']} THEN "
                              "RAISE_APPLICATION_ERROR(-20013, 'Replacement maxDeleteRows exceeded'); END IF;")
    kinds = {'restoreRows': 'objects', 'replaceTable': 'fullTables', 'update': 'updates', 'delete': 'deletes'}
    for step in entry['steps']:
        item = entry[kinds[step['type']]][step['index']]
        table = item['table']
        if step['type'] == 'replaceTable':
            for row in item['rows']:
                values = ',\n'.join(literal(row[col], typ) for col, typ in item['types'].items())
                statements.append(f'INSERT INTO {table} ({", ".join(item["types"])}) VALUES (\n{values});')
        elif step['type'] in {'restoreRows', 'update'}:
            rows = item['rows'] if step['type'] == 'restoreRows' else schema_plan['updates'][step['index']]['rows']
            for row in rows:
                values = {col: row[col] for col in item['columns']} if step['type'] == 'restoreRows' else item['set']
                assignments = ',\n'.join(f'{col} = {literal(value, item["types"][col])}' for col, value in values.items())
                where = predicate(item['key'], [row[k] for k in item['key']], item['types'])
                statements.append(f'UPDATE {table} SET {assignments} WHERE {where};')
                statements.append("IF SQL%ROWCOUNT <> 1 THEN RAISE_APPLICATION_ERROR(-20014, 'Missing or duplicate update key'); END IF;")
        else:
            where = delete_predicate(item['match'], item['types'])
            statements.append(f'DELETE FROM {table} WHERE {where};')
            statements.append(f"IF SQL%ROWCOUNT > {item['maxDeleteRows']} THEN "
                              "RAISE_APPLICATION_ERROR(-20015, 'DELETE maxDeleteRows exceeded'); END IF;")
    statements.extend(validation_statements(entry, schema_plan))
    return ('DECLARE v_count NUMBER; BEGIN\n' + '\n'.join(statements) +
            '\nCOMMIT;\nEXCEPTION WHEN OTHERS THEN ROLLBACK; RAISE; END;\n/\n')


def restore(db, schemas, snap, state_path):
    first_attempt = not state_path.exists()
    plan = preflight(db, schemas, snap, state_path)
    # Persist all post-refresh keys BEFORE the first database write, including
    # before a possibly successful COMMIT whose acknowledgement could be lost.
    save_restore_plan(state_path, plan)
    for cfg, entry, schema_plan in zip(schemas, snap['schemas'], plan['schemas']):
        sqlplus(db, cfg, schema_restore_sql(entry, schema_plan, first_attempt))
        print(f'{cfg["username"]}: schema transaction committed and validated', flush=True)
    print('RESTORE SUCCESS')


def validate(db, schemas, snap, state_path):
    plan = load_restore_plan(state_path, snap, db)
    if plan is None and any(entry['updates'] for entry in snap['schemas']):
        fail('UPDATE validation requires restore-plan.json created by restore')
    for index, (cfg, entry) in enumerate(zip(schemas, snap['schemas'])):
        schema_plan = plan['schemas'][index] if plan else {'updates': []}
        for table, layout in entry['layouts'].items():
            if table_layout(db, cfg, table) != layout:
                fail(f'{table}: layout changed')
        checks = validation_statements(entry, schema_plan)
        sqlplus(db, cfg, 'DECLARE v_count NUMBER; BEGIN\n' + '\n'.join(checks or ['NULL;']) + '\nEND;\n/\n')
        print(f'{cfg["username"]}: all configured results validated')
    print('VALIDATION SUCCESS')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['capture', 'preflight', 'restore', 'validate'])
    parser.add_argument('--snapshot', type=Path)
    args = parser.parse_args()
    db, schemas = load_config()
    if args.action == 'capture':
        capture(db, schemas)
    else:
        if not args.snapshot:
            fail('--snapshot is required')
        snap = read_snapshot(args.snapshot, db, schemas)
        actions = {'preflight': preflight, 'restore': restore, 'validate': validate}
        actions[args.action](db, schemas, snap, args.snapshot.resolve().parent / 'restore-plan.json')

if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAILED: {exc}', file=sys.stderr)
        sys.exit(1)
