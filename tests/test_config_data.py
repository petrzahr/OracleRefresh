import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('config_data', ROOT / 'scripts/config_data.py')
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


def layout(typ='VARCHAR2', **changes):
    result = dict(type=typ, bytes=400, precision=None, scale=None, chars=100,
                  charUsed='C', nullable='Y', identity='NO', virtual='NO', hidden='NO', defaultOnNull='NO')
    result.update(changes)
    return result


def fixture():
    db = {'tnsAlias': 'TEST', 'schemaOrder': ['APP'],
          'expectedTarget': {'dbUniqueName': 'TEST', 'serviceName': 'testpdb', 'conName': 'TESTPDB'}}
    cfg = {'username': 'APP', 'password': 'secret&password'}
    update = {'table': 'CONFIG', 'key': ['ID'], 'match': {'STATE': 'TEST'},
              'set': {'STATE': 'TEST', 'VALUE': 'Příliš\n\n/\n& žluťoučký'},
              'types': {'ID': 'NUMBER', 'STATE': 'VARCHAR2', 'VALUE': 'VARCHAR2'}, 'expectedRows': 1}
    entry = {'username': 'APP', 'objects': [], 'fullTables': [], 'deletes': [], 'updates': [update],
             'steps': [{'type': 'update', 'index': 0}],
             'layouts': {'CONFIG': {'ID': layout('NUMBER'), 'STATE': layout(), 'VALUE': layout()}}}
    return db, cfg, entry, {'schemas': [entry]}


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(ROOT / 'config', self.root / 'config', ignore=shutil.ignore_patterns('integration.json'))
        for path in (self.root / 'config').rglob('*.example.json'):
            shutil.copyfile(path, path.with_name(path.name.replace('.example', '')))
        self.patch = patch.object(app, 'ROOT', self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def alter(self, file, mutate):
        path = self.root / 'config' / file
        data = json.loads(path.read_text())
        mutate(data)
        path.write_text(json.dumps(data))

    def test_readme_setup_ignores_examples(self):
        db, schemas = app.load_config()
        self.assertEqual(db['schemaOrder'], ['APP1', 'APP2', 'CT'])
        self.assertEqual(len(schemas), 3)

    def test_target_required(self):
        self.alter('database.json', lambda v: v.pop('expectedTarget'))
        with self.assertRaisesRegex(ValueError, 'expectedTarget'):
            app.load_config()

    def test_delete_limit_required(self):
        self.alter('schemas/CT.json', lambda v: v['steps'][-1].pop('maxDeleteRows'))
        with self.assertRaisesRegex(ValueError, 'maxDeleteRows'):
            app.load_config()

    def test_replacement_limits_optional(self):
        self.alter('schemas/APP2.json', lambda v: v['steps'][0].pop('maxDeleteRows', None))
        self.alter('schemas/APP2.json', lambda v: v['steps'][0].pop('maxRows', None))
        _, schemas = app.load_config()
        self.assertNotIn('maxDeleteRows', schemas[1]['fullTables'][0])

    def test_explicit_invalid_replacement_limit_rejected(self):
        for value in [None, True, -1, '100']:
            with self.subTest(value=value):
                self.alter('schemas/APP2.json', lambda v: v['steps'][0].update(maxDeleteRows=value))
                with self.assertRaisesRegex(ValueError, 'maxDeleteRows'):
                    app.load_config()

    def test_update_key_must_be_stable(self):
        self.alter('schemas/CT.json', lambda v: v['steps'][0]['set'].update(CONFIG_KEY='OTHER'))
        with self.assertRaisesRegex(ValueError, 'stable key'):
            app.load_config()

    def test_update_key_required(self):
        self.alter('schemas/CT.json', lambda v: v['steps'][0].pop('key'))
        with self.assertRaisesRegex(ValueError, 'key list'):
            app.load_config()

    def test_capture_writes_and_reopens_snapshot_and_exports(self):
        db = json.loads((self.root / 'config/database.json').read_text())
        db['schemaOrder'] = ['CT']
        (self.root / 'config/database.json').write_text(json.dumps(db))
        for name in ['APP1.json', 'APP2.json']:
            (self.root / 'config/schemas' / name).unlink()
        (self.root / 'config/schemas/CT.json').write_text(json.dumps({'steps': [
            {'type': 'restoreRows', 'table': 'CONFIG', 'key': ['ID'], 'columns': ['VALUE'], 'allRows': True}]}))
        db, schemas = app.load_config()
        rows = [{'ID': '1', 'VALUE': "Příliš\n\n/\r\nO'Brien & čaj"}, {'ID': '2', 'VALUE': None}]
        types = {'ID': 'NUMBER', 'VALUE': 'VARCHAR2'}
        with patch.object(app, 'table_layout', return_value={'ID': layout('NUMBER'), 'VALUE': layout()}), \
                patch.object(app, 'full_metadata', return_value=types), \
                patch.object(app, 'query_full_table', return_value=rows):
            app.capture(db, schemas)
        path = next((self.root / 'snapshots').glob('*/snapshot.json'))
        snap = app.read_snapshot(path, db, schemas)
        self.assertEqual(snap['version'], 2)
        self.assertEqual(snap['schemas'][0]['objects'][0]['rows'], rows)
        self.assertIn('CHR(13)', (path.parent / 'CT/CONFIG.insert.sql').read_text(encoding='utf-8'))
        path.write_text(path.read_text() + ' ')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            app.read_snapshot(path, db, schemas)


class SqlTests(unittest.TestCase):
    def test_full_metadata_uses_correct_view(self):
        with patch.object(app, 'sqlplus', return_value='META|ID|NUMBER\n') as run:
            self.assertEqual(app.full_metadata({}, {'username': 'APP'}, 'T'), {'ID': 'NUMBER'})
        self.assertIn('FROM user_tab_cols ', run.call_args.args[2])

    def test_connection_guard_and_unicode_transport(self):
        db, cfg, _, _ = fixture()
        with patch.object(app.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
            app.sqlplus(db, cfg, 'BEGIN NULL; END;\n/\n')
        options = run.call_args.kwargs
        self.assertEqual(options['encoding'], 'utf-8')
        self.assertEqual(options['env']['NLS_LANG'], '.AL32UTF8')
        self.assertIn('-L', run.call_args.args[0])
        sql = options['input']
        self.assertLess(sql.index('set define off'), sql.index('connect '))
        self.assertLess(sql.index('DB_UNIQUE_NAME'), sql.index('BEGIN NULL;'))
        self.assertIn('SERVICE_NAME', sql)
        self.assertIn('CON_NAME', sql)
        self.assertTrue(sql.endswith('exit rollback\n'))

    def test_error_does_not_disclose_configuration(self):
        db, cfg, _, _ = fixture()
        output = 'ORA-20010: bad secret&password\nprivate row data\n'
        with patch.object(app.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, output, '')):
            with self.assertRaises(ValueError) as error:
                app.sqlplus(db, cfg, '')
        self.assertNotIn('secret', str(error.exception))
        self.assertNotIn('private', str(error.exception))

    def test_multiline_literal_has_no_sqlplus_control_lines(self):
        sql = app.literal("Příliš\n\n/\n'&žluťoučký\r\nkůň", 'VARCHAR2')
        self.assertIn('CHR(10)', sql)
        self.assertIn('CHR(13)', sql)
        self.assertNotIn('\n/\n', sql)
        self.assertNotIn('\n\n', sql)
        self.assertIn("''", sql)
        self.assertIn("N'žluťoučký'", app.literal('žluťoučký', 'NVARCHAR2'))

    def test_number_literal_preserves_precision_and_rejects_sql(self):
        value = '12345678901234567890123456789012345678'
        self.assertEqual(app.literal(value, 'NUMBER'), value)
        with self.assertRaises(ValueError):
            app.literal('1); DELETE FROM T;', 'NUMBER')

    def test_long_char_preserves_blank_padding_semantics(self):
        self.assertIn('AS CHAR(201 CHAR)', app.literal('x' * 201, 'CHAR'))

    def test_captured_timezone_comparison_preserves_offset(self):
        sql = app.captured_predicate({'TZ': '2026-09-22 14:35:02.123456789 +02:00'},
                                     {'TZ': 'TIMESTAMP WITH TIME ZONE'})
        self.assertIn('TO_CHAR(TZ,', sql)
        self.assertIn('TZH:TZM', sql)

    def test_value_checks_include_byte_length_null_and_precision(self):
        sql = app.value_checks('T', {'V': 'č', 'N': '1.234'},
                               {'V': layout(charUsed='B', bytes=1, nullable='N'),
                                'N': layout('NUMBER', precision=3, scale=2)})
        self.assertIn('LENGTHB', sql)
        self.assertIn('IS NULL', sql)
        self.assertIn('NUMBER(3,2)', sql)

    def test_null_and_empty_string_use_is_null(self):
        self.assertEqual(app.delete_predicate({'V': ''}, {'V': 'VARCHAR2'}), 'V IS NULL')
        self.assertEqual(app.literal(None, 'NUMBER'), 'NULL')

    def test_update_validation_uses_keys_even_if_match_unchanged(self):
        _, _, entry, _ = fixture()
        statements = app.validation_statements(entry, {'updates': [{'rows': [{'ID': '42'}]}]})
        self.assertIn('ID = 42', statements[0])
        self.assertNotIn('UPDATE_OLD', ''.join(statements))

    def test_expected_update_count_including_zero(self):
        _, _, entry, _ = fixture()
        with self.assertRaisesRegex(ValueError, 'row count'):
            app.validation_statements(entry, {'updates': [{'rows': []}]})
        entry['updates'][0]['expectedRows'] = 0
        self.assertEqual(app.validation_statements(entry, {'updates': [{'rows': []}]}), [])

    def test_transaction_and_parent_child_order(self):
        _, _, entry, _ = fixture()
        entry['updates'] = []
        entry['layouts'] = {'PARENT': {}, 'CHILD': {}}
        entry['fullTables'] = [dict(table=t, rows=[{'ID': '1'}], types={'ID': 'NUMBER'}, maxDeleteRows=10)
                               for t in ['PARENT', 'CHILD']]
        entry['steps'] = [{'type': 'replaceTable', 'index': i} for i in range(2)]
        sql = app.schema_restore_sql(entry, {'updates': []}, True)
        self.assertLess(sql.index('DELETE FROM CHILD'), sql.index('DELETE FROM PARENT'))
        self.assertLess(sql.index('INSERT INTO PARENT'), sql.index('INSERT INTO CHILD'))
        self.assertNotIn('TRUNCATE', sql)
        self.assertEqual(sql.count('COMMIT;'), 1)
        self.assertLess(sql.index('replacement value mismatch'), sql.index('COMMIT;'))
        self.assertIn('EXCEPTION WHEN OTHERS THEN ROLLBACK;', sql)


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.db, self.cfg, self.entry, self.snap = fixture()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / 'restore-plan.json'

    def mocks(self):
        patches = [patch.object(app, 'table_layout', return_value=copy.deepcopy(self.entry['layouts']['CONFIG'])),
                   patch.object(app, 'scalar', return_value=0),
                   patch.object(app, 'query_full_table', return_value=[{'ID': '42'}]),
                   patch.object(app, 'query_rows', return_value=[{'ID': '42'}]),
                   patch.object(app, 'sqlplus', return_value='')]
        mocks = [p.start() for p in patches]
        for p in patches:
            self.addCleanup(p.stop)
        return mocks

    def test_preflight_is_read_only_and_does_not_save_plan(self):
        mocks = self.mocks()
        plan = app.preflight(self.db, [self.cfg], self.snap, self.state)
        self.assertFalse(self.state.exists())
        self.assertEqual(plan['schemas'][0]['updates'][0]['rows'], [{'ID': '42'}])
        for call in mocks[-1].call_args_list:
            self.assertNotIn('COMMIT;', call.args[2])
            self.assertNotIn('DELETE FROM', call.args[2])
            self.assertNotIn('UPDATE CONFIG', call.args[2])

    def test_layout_change_blocks_before_writes(self):
        mocks = self.mocks()
        mocks[0].return_value['VALUE']['chars'] = 20
        with self.assertRaisesRegex(ValueError, 'layout changed'):
            app.restore(self.db, [self.cfg], self.snap, self.state)
        mocks[-1].assert_not_called()
        self.assertFalse(self.state.exists())

    def test_missing_restore_key_blocks_before_plan_or_writes(self):
        mocks = self.mocks()
        self.entry['objects'] = [{'table': 'CONFIG', 'key': ['ID'], 'columns': ['VALUE'],
                                  'types': {'ID': 'NUMBER', 'VALUE': 'VARCHAR2'},
                                  'rows': [{'ID': '7', 'VALUE': 'test'}]}]
        mocks[3].side_effect = ValueError('Missing key')
        with self.assertRaisesRegex(ValueError, 'Missing key'):
            app.restore(self.db, [self.cfg], self.snap, self.state)
        self.assertFalse(self.state.exists())
        mocks[-1].assert_not_called()

    def test_identity_replacement_rejected_before_plan(self):
        self.entry['layouts']['CONFIG']['ID']['identity'] = 'YES'
        self.entry['fullTables'] = [dict(table='CONFIG', maxDeleteRows=10)]
        self.entry['steps'] = [dict(type='replaceTable', index=0)]
        self.entry['updates'] = []
        self.mocks()
        with self.assertRaisesRegex(ValueError, 'identity'):
            app.restore(self.db, [self.cfg], self.snap, self.state)
        self.assertFalse(self.state.exists())

    def test_enabled_trigger_rejected(self):
        mocks = self.mocks()
        mocks[1].return_value = 1
        with self.assertRaisesRegex(ValueError, 'triggers'):
            app.preflight(self.db, [self.cfg], self.snap)

    def test_delete_ceiling_blocks_preflight(self):
        mocks = self.mocks()
        self.entry['updates'] = []
        self.entry['deletes'] = [dict(table='CONFIG', match={'STATE': 'PROD'},
                                     types={'STATE': 'VARCHAR2'}, maxDeleteRows=2)]
        mocks[1].side_effect = [0, 3]
        with self.assertRaisesRegex(ValueError, 'maxDeleteRows'):
            app.preflight(self.db, [self.cfg], self.snap)

    def test_unlimited_replacement_skips_count_and_retains_validation(self):
        mocks = self.mocks()
        self.entry['updates'] = []
        self.entry['fullTables'] = [dict(table='CONFIG', rows=[{'ID': '1'}], types={'ID': 'NUMBER'}, maxDeleteRows=None)]
        self.entry['steps'] = [dict(type='replaceTable', index=0)]
        plan = app.preflight(self.db, [self.cfg], self.snap)
        self.assertEqual(mocks[1].call_count, 1)  # Trigger check only; no table row count.
        sql = app.schema_restore_sql(self.entry, plan['schemas'][0], True)
        self.assertIn('DELETE FROM CONFIG;', sql)
        self.assertNotIn('maxDeleteRows exceeded', sql)
        self.assertIn('replacement count mismatch', sql)
        self.assertIn('COMMIT;', sql)

    def test_plan_survives_failed_restore_and_reuses_original_keys(self):
        mocks = self.mocks()
        def fail_transaction(db, cfg, sql):
            if 'COMMIT;' in sql:
                self.assertTrue(self.state.exists())
                raise ValueError('simulated lost connection')
            return ''
        mocks[-1].side_effect = fail_transaction
        with self.assertRaisesRegex(ValueError, 'lost connection'):
            app.restore(self.db, [self.cfg], self.snap, self.state)
        mocks[2].reset_mock()
        mocks[-1].side_effect = None
        app.restore(self.db, [self.cfg], self.snap, self.state)
        mocks[2].assert_not_called()
        sql = mocks[-1].call_args.args[2]
        self.assertIn('WHERE ID = 42', sql)
        self.assertNotIn('selection changed since preflight', sql)

    def test_corrupt_or_other_snapshot_plan_is_rejected(self):
        self.mocks()
        plan = app.preflight(self.db, [self.cfg], self.snap)
        app.save_restore_plan(self.state, plan)
        other = copy.deepcopy(self.snap)
        other['other'] = True
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            app.load_restore_plan(self.state, other, self.db)
        raw = json.loads(self.state.read_text())
        raw['plan']['schemas'][0]['updates'][0]['rows'][0]['ID'] = '99'
        self.state.write_text(json.dumps(raw))
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            app.load_restore_plan(self.state, self.snap, self.db)

    def test_standalone_update_validation_requires_plan(self):
        with self.assertRaisesRegex(ValueError, 'requires restore-plan'):
            app.validate(self.db, [self.cfg], self.snap, self.state)

    def test_overlap_is_rejected(self):
        self.mocks()
        self.entry['updates'].append(copy.deepcopy(self.entry['updates'][0]))
        with self.assertRaisesRegex(ValueError, 'overlapping'):
            app.preflight(self.db, [self.cfg], self.snap)

    def test_foreign_keys_require_same_schema_parent_first(self):
        self.entry['fullTables'] = [{'table': 'PARENT'}, {'table': 'CHILD'}]
        self.entry['steps'] = [{'type': 'replaceTable', 'index': i} for i in range(2)]
        with patch.object(app, 'sqlplus', return_value='FK|APP|CHILD|PARENT\n'):
            app.replacement_dependencies(self.db, self.cfg, self.entry)
        with patch.object(app, 'sqlplus', return_value='FK|OTHER|CHILD|PARENT\n'):
            with self.assertRaisesRegex(ValueError, 'same schema'):
                app.replacement_dependencies(self.db, self.cfg, self.entry)


if __name__ == '__main__':
    unittest.main()
