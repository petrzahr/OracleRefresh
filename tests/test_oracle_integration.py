"""Opt-in tests against a disposable Oracle 19c+ schema; see tests/README.md."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('oracle_integration_app', ROOT / 'scripts/config_data.py')
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
SETTINGS = os.environ.get('ORACLE_REFRESH_INTEGRATION_CONFIG')


@unittest.skipUnless(SETTINGS, 'Set ORACLE_REFRESH_INTEGRATION_CONFIG to opt into real Oracle tests')
class OracleIntegrationTests(unittest.TestCase):
    def setUp(self):
        settings = json.loads(Path(SETTINGS).read_text(encoding='utf-8'))
        self.db, self.account = settings['database'], settings['account']
        self.user = app.identifier(self.account['username'])
        if not self.user.startswith('ORF_TEST_'):
            self.fail('Integration account must be a disposable schema named ORF_TEST_*')
        self.prefix = 'ORF_' + uuid.uuid4().hex[:8].upper()
        self.parent, self.child, self.config, self.values = [self.prefix + suffix for suffix in ('_P', '_C', '_F', '_V')]
        self.created = []
        self.addCleanup(self.drop_tables)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.root_patch = patch.object(app, 'ROOT', self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.text = "Příliš žluťoučký kůň\n\n/\nO'Brien & čaj\r\nkonec"
        definitions = [
            (self.parent, 'ID NUMBER PRIMARY KEY, V VARCHAR2(100 CHAR)'),
            (self.child, f'ID NUMBER PRIMARY KEY, PID NUMBER REFERENCES {self.parent}(ID), V VARCHAR2(100 CHAR)'),
            (self.config, 'ID NUMBER PRIMARY KEY, STATE VARCHAR2(20), V VARCHAR2(100 CHAR), NVAL VARCHAR2(20)'),
            (self.values, 'ID NUMBER PRIMARY KEY, V VARCHAR2(100 CHAR), NV NVARCHAR2(100), '
             'AMOUNT NUMBER(12,2), D DATE, TS TIMESTAMP(9), TZ TIMESTAMP(9) WITH TIME ZONE')]
        for table, columns in definitions:
            self.run_sql(f'CREATE TABLE {table} ({columns});')
            self.created.append(table)
        self.run_sql(f"INSERT INTO {self.parent} VALUES (1, 'test');\n"
                     f"INSERT INTO {self.child} VALUES (1, 1, 'test');\n"
                     f"INSERT INTO {self.config} VALUES (1, 'TEST', 't', NULL);\n"
                     f"INSERT INTO {self.config} VALUES (2, 'PROD', 't', 'old');\n"
                     f"INSERT INTO {self.config} VALUES (3, 'DELETE', 't', NULL);\n"
                     f"INSERT INTO {self.values} VALUES (1, {app.literal(self.text, 'VARCHAR2')}, "
                     f"{app.literal('Žluťoučký 漢字', 'NVARCHAR2')}, 1234567890.12, "
                     "TO_DATE('2026-09-22 14:35:02', 'YYYY-MM-DD HH24:MI:SS'), "
                     "TO_TIMESTAMP('2026-09-22 14:35:02.123456789', 'YYYY-MM-DD HH24:MI:SS.FF9'), "
                     "TO_TIMESTAMP_TZ('2026-09-22 14:35:02.123456789 +02:00', 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM'));\nCOMMIT;")
        self.steps = [
            dict(type='replaceTable', table=self.parent, maxRows=10, maxDeleteRows=10),
            dict(type='replaceTable', table=self.child, maxRows=10, maxDeleteRows=10),
            dict(type='restoreRows', table=self.values, key=['ID'],
                 columns=['V', 'NV', 'AMOUNT', 'D', 'TS', 'TZ'], allRows=True),
            dict(type='update', table=self.config, key=['ID'], match={'STATE': 'TEST'},
                 set={'STATE': 'TEST', 'V': self.text, 'NVAL': None}, expectedRows=1),
            dict(type='update', table=self.config, key=['ID'], match={'STATE': 'PROD'},
                 set={'STATE': 'TEST', 'V': 'Český text'}, expectedRows=1),
            dict(type='delete', table=self.config, match={'STATE': 'DELETE'}, maxDeleteRows=1)]
        config_dir = self.root / 'config'
        (config_dir / 'schemas').mkdir(parents=True)
        self.db = {**self.db, 'schemaOrder': [self.user]}
        (config_dir / 'database.json').write_text(json.dumps(self.db))
        (config_dir / 'credentials.json').write_text(json.dumps({'users': {self.user: self.account}}))
        (config_dir / 'schemas' / f'{self.user}.json').write_text(json.dumps({'steps': self.steps}))
        self.db, self.schemas = app.load_config()
        app.capture(self.db, self.schemas)
        self.snapshot_path = next((self.root / 'snapshots').glob('*/snapshot.json'))
        self.snap = app.read_snapshot(self.snapshot_path, self.db, self.schemas)
        self.state = self.snapshot_path.parent / 'restore-plan.json'

    def run_sql(self, sql):
        return app.sqlplus(self.db, self.account, sql + '\n')

    def drop_tables(self):
        for table in reversed(self.created):
            self.run_sql(f'DROP TABLE {table} PURGE;')

    def refresh_fixture(self):
        self.run_sql(f"DELETE FROM {self.child};\nDELETE FROM {self.parent};\n"
                     f"INSERT INTO {self.parent} VALUES (2, 'prod');\n"
                     f"INSERT INTO {self.child} VALUES (2, 2, 'prod');\n"
                     f"UPDATE {self.values} SET V = 'prod', NV = NULL, AMOUNT = 0, D = NULL, TS = NULL, TZ = NULL;\n"
                     f"UPDATE {self.config} SET V = 'p', NVAL = 'prod';\nCOMMIT;")

    def test_round_trip_unicode_null_dates_foreign_keys_and_retry(self):
        self.refresh_fixture()
        app.preflight(self.db, self.schemas, self.snap, self.state)
        self.assertFalse(self.state.exists())
        app.restore(self.db, self.schemas, self.snap, self.state)
        app.validate(self.db, self.schemas, self.snap, self.state)
        app.restore(self.db, self.schemas, self.snap, self.state)
        app.validate(self.db, self.schemas, self.snap, self.state)
        types = app.full_metadata(self.db, self.account, self.values)
        rows = app.query_full_table(self.db, self.account, self.values, types, 10)
        self.assertEqual(rows[0]['V'], self.text)
        self.assertEqual(rows[0]['NV'], 'Žluťoučký 漢字')
        self.assertEqual(rows[0]['AMOUNT'], '1234567890.12')

    def test_late_failure_rolls_back_replacements_then_retry_succeeds(self):
        self.refresh_fixture()
        constraint = self.prefix + '_CHECK'
        self.run_sql(f'ALTER TABLE {self.config} ADD CONSTRAINT {constraint} CHECK (LENGTH(V) <= 1);')
        with self.assertRaises(ValueError):
            app.restore(self.db, self.schemas, self.snap, self.state)
        self.assertTrue(self.state.exists())
        self.assertEqual(app.scalar(self.db, self.account, f'SELECT COUNT(*) FROM {self.parent} WHERE ID = 2'), 1)
        self.assertEqual(app.scalar(self.db, self.account, f'SELECT COUNT(*) FROM {self.child} WHERE ID = 2'), 1)
        self.assertEqual(app.scalar(self.db, self.account, f"SELECT COUNT(*) FROM {self.values} WHERE V = 'prod'"), 1)
        self.run_sql(f'ALTER TABLE {self.config} DROP CONSTRAINT {constraint};')
        app.restore(self.db, self.schemas, self.snap, self.state)
        app.validate(self.db, self.schemas, self.snap, self.state)

    def test_missing_key_is_caught_before_replacement(self):
        self.refresh_fixture()
        self.run_sql(f'DELETE FROM {self.values};\nCOMMIT;')
        with self.assertRaises(ValueError):
            app.restore(self.db, self.schemas, self.snap, self.state)
        self.assertFalse(self.state.exists())
        self.assertEqual(app.scalar(self.db, self.account, f'SELECT COUNT(*) FROM {self.parent} WHERE ID = 2'), 1)

    def test_changed_length_is_caught_before_replacement(self):
        self.refresh_fixture()
        self.run_sql(f'ALTER TABLE {self.values} MODIFY V VARCHAR2(50 CHAR);')
        with self.assertRaisesRegex(ValueError, 'layout changed'):
            app.restore(self.db, self.schemas, self.snap, self.state)
        self.assertFalse(self.state.exists())

    def test_wrong_target_blocks_even_a_read(self):
        wrong = copy.deepcopy(self.db)
        wrong['expectedTarget']['conName'] = 'INTENTIONALLY_WRONG_PDB'
        with self.assertRaisesRegex(ValueError, 'ORA-20010'):
            app.sqlplus(wrong, self.account, 'SELECT 1 FROM dual;\n')

    def test_delete_limit_is_checked_before_writes(self):
        self.refresh_fixture()
        self.run_sql(f"INSERT INTO {self.config} VALUES (4, 'DELETE', 'p', NULL);\nCOMMIT;")
        with self.assertRaisesRegex(ValueError, 'maxDeleteRows'):
            app.restore(self.db, self.schemas, self.snap, self.state)
        self.assertFalse(self.state.exists())


if __name__ == '__main__':
    unittest.main()
