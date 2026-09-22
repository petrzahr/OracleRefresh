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
    configs = list((ROOT / 'config/schemas').glob('*.json'))
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
            if 'backupMaxRows' in update and (not isinstance(update['backupMaxRows'], int) or isinstance(update['backupMaxRows'], bool) or update['backupMaxRows'] < 0):
                fail(f'{user}.{update["table"]}: invalid backupMaxRows')
            match, values = update.get('match'), update.get('set')
            if ('match' in update and (not isinstance(match, dict) or not match)) or not isinstance(values, dict) or not values:
                fail(f'{user}.{update["table"]}: UPDATE requires a nonempty set and, when present, a nonempty match object')
            for name, mapping in (('match', match or {}), ('set', values)):
                for col, value in mapping.items():
                    identifier(col)
                    if value is not None and (not isinstance(value, (str, int, float)) or isinstance(value, bool)):
                        fail(f'{user}.{update["table"]}: invalid {name} value')
            if 'expectedRows' in update and (not isinstance(update['expectedRows'], int) or isinstance(update['expectedRows'], bool) or update['expectedRows'] < 0):
                fail(f'{user}.{update["table"]}: invalid expectedRows')
        for deletion in cfg.get('deletes', []):
            identifier(deletion['table'])
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
            if 'maxRows' in full and (not isinstance(full['maxRows'], int) or isinstance(full['maxRows'], bool) or full['maxRows'] < 0):
                fail(f'{user}.{full["table"]}: invalid maxRows')
            if 'expectedRows' in full and (not isinstance(full['expectedRows'], int) or full['expectedRows'] < 0 or ('maxRows' in full and full['expectedRows'] > full['maxRows'])):
                fail(f'{user}.{full["table"]}: invalid expectedRows')
        for obj in cfg.get('objects', []):
            identifier(obj['table'])
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

def sqlplus(db, cfg, script):
    exe = db.get('sqlplusPath', 'sqlplus')
    # Credentials never appear in the process command line or log. SQL*Plus reads CONNECT from stdin.
    password = cfg['password'].replace('"', '""')
    if any(c in password for c in ['\x00']):
        fail('Unsupported password character')
    header = (f'connect {cfg["username"]}/"{password}"@{db["tnsAlias"]}\n'
              'whenever oserror exit failure\nwhenever sqlerror exit sql.sqlcode rollback\n'
              'set heading off feedback off verify off echo off define off pagesize 0 linesize 32767 trimspool on tab off\n'
              "alter session set nls_numeric_characters='.,';\n")
    proc = subprocess.run([exe, '-S', '/nolog'], input=header + script + '\nexit\n', text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    output = proc.stdout + proc.stderr
    if proc.returncode or re.search(r'(^|\n)(ORA-|SP2-|PLS-)\d+', output):
        fail(f'SQL*Plus failed for {cfg["username"]}: ' + '\n'.join(output.splitlines()[-12:]))
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
    q = ("SELECT 'META|' || column_name || '|' || data_type FROM user_tab_columns "
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
        return f"TO_NUMBER({quoted(str(value))}, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''')"
    if typ == 'DATE':
        return f"TO_DATE({quoted(value)}, 'YYYY-MM-DD HH24:MI:SS')"
    if typ == 'TIMESTAMP':
        return f"TO_TIMESTAMP({quoted(value)}, 'YYYY-MM-DD HH24:MI:SS.FF9')"
    if typ == 'TIMESTAMP WITH TIME ZONE':
        return f"TO_TIMESTAMP_TZ({quoted(value)}, 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM')"
    return quoted(value)

def predicate(keys, values, types):
    return ' AND '.join(f'{k} = {literal(v, types[k])}' for k, v in zip(keys, values))

def delete_predicate(match, types):
    return ' AND '.join(f'{identifier(key)} IS NULL' if value is None else
                        f'{identifier(key)} = {literal(value, types[identifier(key)])}'
                        for key, value in match.items())

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

def query_full_table(db, cfg, table, types, max_rows):
    fields = ', '.join(f'{quoted(n)} VALUE {expression(n, typ)}' for n, typ in types.items())
    json_expr = f'JSON_OBJECT({fields} NULL ON NULL RETURNING CLOB)'
    sql = ("set serveroutput on size unlimited\n"
           "DECLARE v_count NUMBER := 0; BEGIN\n"
           f"FOR r IN (SELECT {json_expr} AS j FROM {table}) LOOP\n"
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
             'WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK', 'SET DEFINE OFF']
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
    snapshot = {'capturedAt': stamp, 'tnsAlias': db['tnsAlias'], 'status': 'INCOMPLETE', 'schemas': []}
    backup_files = []
    inventory = {}
    path = root / 'snapshot.json'
    try:
        for cfg in schemas:
            user = identifier(cfg['username'])
            entry = {'username': user, 'objects': [], 'fullTables': [], 'deletes': [], 'updates': []}
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
                entry['fullTables'].append({'table': table, 'types': types, 'rows': rows,
                                            'maxRows': full.get('maxRows'), 'expectedRows': full.get('expectedRows')})
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
                if not set(match) | set(values) <= set(types):
                    fail(f'{user}.{table}: UPDATE column missing')
                if table not in backed_up:
                    rows = query_full_table(db, cfg, table, types, update.get('backupMaxRows'))
                    backup_files.extend(write_table_backups(root, user, table, [], list(types), types, rows))
                    inventory[(user, table)] = (types, rows)
                    backed_up.add(table)
                    print(f'{user}.{table}: {len(rows)} full-table backup rows for UPDATE')
                entry['updates'].append({'table': table, 'match': match, 'set': values,
                                         'types': {k: types[k] for k in list(match) + list(values)},
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

def restore(db, schemas, snap):
    # Preflight every destination before any irreversible TRUNCATE.
    for cfg, entry in zip(schemas, snap['schemas']):
        for full in entry['fullTables']:
            if full_metadata(db, cfg, full['table']) != full['types']:
                fail(f'{entry["username"]}.{full["table"]}: column types changed')
        for obj in entry['objects']:
            if metadata(db, cfg, obj['table'], list(obj['types'])) != obj['types']:
                fail(f'{entry["username"]}.{obj["table"]}: restore column types changed')
        for operation in entry['updates'] + entry['deletes']:
            if metadata(db, cfg, operation['table'], list(operation['types'])) != operation['types']:
                fail(f'{entry["username"]}.{operation["table"]}: configured column types changed')

    kind_map = {'restoreRows': 'objects', 'replaceTable': 'fullTables', 'update': 'updates', 'delete': 'deletes'}
    full_steps = [(cfg, entry[kind_map[step['type']]][step['index']])
                  for cfg, entry in zip(schemas, snap['schemas'])
                  for step in entry['steps'] if step['type'] == 'replaceTable']
    # Children first: TRUNCATE phase is intentionally reverse of the configured insertion order.
    for cfg, full in reversed(full_steps):
        name = f'{cfg["username"]}.{full["table"]}'
        sqlplus(db, cfg, f'TRUNCATE TABLE {full["table"]};\n')
        print(f'{name}: truncated', flush=True)

    for cfg, entry in zip(schemas, snap['schemas']):
        for step in entry['steps']:
            kind = step['type']
            item = entry[kind_map[kind]][step['index']]
            name = f'{entry["username"]}.{item["table"]}'
            if kind == 'restoreRows':
                statements = []
                for row in item['rows']:
                    sets = ', '.join(f'{col} = {literal(row[col], item["types"][col])}' for col in item['columns'])
                    clause = predicate(item['key'], [row[k] for k in item['key']], item['types'])
                    statements.append(f'UPDATE {item["table"]} SET {sets} WHERE {clause};\n'
                                      f'IF SQL%ROWCOUNT != 1 THEN RAISE_APPLICATION_ERROR(-20003, {quoted(name + ": affected row count != 1")}); END IF;')
                chunks = [statements[i:i + 50] for i in range(0, len(statements), 50)]
                script = ''.join('BEGIN\n' + '\n'.join(chunk) + '\nEND;\n/\n' for chunk in chunks) + 'COMMIT;\n'
                sqlplus(db, cfg, script)
                print(f'{name}: restored {len(statements)} selected rows')
            elif kind == 'replaceTable':
                rows, types = item['rows'], item['types']
                if rows:
                    columns = ', '.join(types)
                    inserts = '\n'.join(f'INSERT INTO {item["table"]} ({columns}) VALUES (' +
                                        ', '.join(literal(row[col], typ) for col, typ in types.items()) + ');'
                                        for row in rows)
                    sqlplus(db, cfg, f'SET DEFINE OFF\n{inserts}\nCOMMIT;\n')
                print(f'{name}: inserted {len(rows)} rows')
            elif kind == 'update':
                clause = f" WHERE {delete_predicate(item['match'], item['types'])}" if item['match'] else ''
                assignments = ', '.join(f'{col} = {literal(value, item["types"][col])}' for col, value in item['set'].items())
                expected = item['expectedRows']
                check = (f'IF SQL%ROWCOUNT != {expected} THEN RAISE_APPLICATION_ERROR(-20006, {quoted(name + ": unexpected UPDATE row count")}); END IF;\n'
                         if expected is not None else
                         f'IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20006, {quoted(name + ": unexpected UPDATE row count")}); END IF;\n'
                         if item['match'] else '')
                sql = (f'BEGIN UPDATE {item["table"]} SET {assignments}{clause};\n'
                       f'{check}'
                       'COMMIT; EXCEPTION WHEN OTHERS THEN ROLLBACK; RAISE; END;\n/\n')
                sqlplus(db, cfg, sql)
                print(f'{name}: fixed UPDATE applied')
            elif kind == 'delete':
                where = delete_predicate(item['match'], item['types'])
                sqlplus(db, cfg, f'DELETE FROM {item["table"]} WHERE {where};\nCOMMIT;\n')
                print(f'{name}: matching rows deleted')
    print('RESTORE SUCCESS')

def validate(db, schemas, snap):
    for cfg, entry in zip(schemas, snap['schemas']):
        for obj in entry['objects']:
            live = query_rows(db, cfg, {'table': obj['table'], 'key': obj['key'], 'columns': obj['columns'], 'keyValues': [[row[k] for k in obj['key']] for row in obj['rows']]}, obj['types'])
            if live != obj['rows']:
                fail(f'{entry["username"]}.{obj["table"]}: validation mismatch')
            print(f'{entry["username"]}.{obj["table"]}: validated {len(live)} rows')
        for full in entry.get('fullTables', []):
            live_types = full_metadata(db, cfg, full['table'])
            if live_types != full['types']:
                fail(f'{entry["username"]}.{full["table"]}: column types changed')
            live = query_full_table(db, cfg, full['table'], live_types, full['maxRows'])
            as_multiset = lambda rows: Counter(json.dumps(row, sort_keys=True, ensure_ascii=False) for row in rows)
            if as_multiset(live) != as_multiset(full['rows']):
                fail(f'{entry["username"]}.{full["table"]}: full-table validation mismatch')
            print(f'{entry["username"]}.{full["table"]}: validated all {len(live)} rows')
        for deletion in entry.get('deletes', []):
            where = delete_predicate(deletion['match'], deletion['types'])
            sql = f"SELECT 'DELETE_REMAINING|' || COUNT(*) FROM {deletion['table']} WHERE {where};\n"
            output = sqlplus(db, cfg, sql)
            counts = [int(line.strip().split('|', 1)[1]) for line in output.splitlines() if line.strip().startswith('DELETE_REMAINING|')]
            if counts != [0]:
                fail(f'{entry["username"]}.{deletion["table"]}: matching rows remain')
            print(f'{entry["username"]}.{deletion["table"]}: delete validated')
        for update in entry.get('updates', []):
            clause = f" WHERE {delete_predicate(update['match'], update['types'])}" if update['match'] else ''
            overlap = set(update['match']) & set(update['set'])
            if overlap:
                stable_match = {k: v for k, v in update['match'].items() if k not in overlap}
                new_match = {**stable_match, **update['set']}
                old_sql = f"SELECT 'UPDATE_OLD|' || COUNT(*) FROM {update['table']}{clause};\n"
                new_sql = f"SELECT 'UPDATE_NEW|' || COUNT(*) FROM {update['table']} WHERE {delete_predicate(new_match, update['types'])};\n"
                old_output = sqlplus(db, cfg, old_sql)
                new_output = sqlplus(db, cfg, new_sql)
                old_counts = [int(line.strip().split('|', 1)[1]) for line in old_output.splitlines() if line.strip().startswith('UPDATE_OLD|')]
                new_counts = [int(line.strip().split('|', 1)[1]) for line in new_output.splitlines() if line.strip().startswith('UPDATE_NEW|')]
                if old_counts != [0] or len(new_counts) != 1 or new_counts[0] == 0:
                    fail(f'{entry["username"]}.{update["table"]}: fixed UPDATE validation mismatch')
                print(f'{entry["username"]}.{update["table"]}: fixed UPDATE validated')
                continue
            mismatches = []
            for col, value in update['set'].items():
                mismatches.append(f'{col} IS NOT NULL' if value is None else
                                  f'({col} IS NULL OR {col} <> {literal(value, update["types"][col])})')
            sql = ("SELECT 'UPDATE_CHECK|' || COUNT(*) || '|' || "
                   f"COALESCE(SUM(CASE WHEN {' OR '.join(mismatches)} THEN 1 ELSE 0 END), 0) "
                   f'FROM {update["table"]}{clause};\n')
            output = sqlplus(db, cfg, sql)
            found = [line.strip().split('|')[1:] for line in output.splitlines() if line.strip().startswith('UPDATE_CHECK|')]
            if len(found) != 1 or len(found[0]) != 2:
                fail(f'{entry["username"]}.{update["table"]}: validation output missing')
            count, wrong = map(int, found[0])
            if wrong or (update['expectedRows'] is not None and count != update['expectedRows']) or (update['expectedRows'] is None and update['match'] and count == 0):
                fail(f'{entry["username"]}.{update["table"]}: fixed UPDATE validation mismatch')
            print(f'{entry["username"]}.{update["table"]}: fixed UPDATE validated ({count} rows)')
    print('VALIDATION SUCCESS')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['capture', 'restore', 'validate'])
    parser.add_argument('--snapshot', type=Path)
    args = parser.parse_args()
    db, schemas = load_config()
    if args.action == 'capture':
        capture(db, schemas)
    else:
        if not args.snapshot:
            fail('--snapshot is required')
        snap = read_snapshot(args.snapshot, db, schemas)
        (restore if args.action == 'restore' else validate)(db, schemas, snap)

if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAILED: {exc}', file=sys.stderr)
        sys.exit(1)
