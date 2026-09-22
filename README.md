# Oracle TEST configuration: capture → DBA refresh → restore

Requires Python 3.9+, SQL*Plus, PowerShell and an Oracle version supporting `JSON_OBJECT(... RETURNING CLOB)` (Oracle 19c recommended). The scripts **do not perform or start the DBA database refresh**.

## Configuration

1. Copy `config/database.example.json` to `config/database.json`. Set `tnsAlias`, `sqlplusPath`, and `schemaOrder` (every schema filename, once, in execution order).
2. Copy `config/credentials.example.json` to `config/credentials.json`. Its `users` map contains all schema usernames and passwords. Protect this file.
3. Copy each `config/schemas/*.example.json` to the same name without `.example`. There is **one JSON per schema** and one ordered `steps` array per JSON. A filename such as `CT.json` selects the `CT` account in `credentials.json`.

Step types:

| `type` | Required fields | Effect after DBA refresh |
| --- | --- | --- |
| `restoreRows` | `table`, `key`, `columns`, plus `keyValues` or `allRows: true` | Captures current TEST values and updates only specified columns for the selected rows. With `allRows`, every captured row is matched using the non-null, unique key. Optional `expectedRows` applies only to `keyValues`. |
| `replaceTable` | `table` | Captures every row, truncates the table and inserts all captured rows. Optional `maxRows` / `expectedRows`. |
| `update` | `table`, `set`; optional `match` | Fixed post-refresh UPDATE. All entries in `match` use AND; omitting `match` updates every row in the table. Each entry in `set` names a column to change. `expectedRows` optionally requires an exact affected count; without it, a filtered UPDATE requires at least one row, while an update of the entire table also accepts zero rows. |
| `delete` | `table`, `match` | Fixed post-refresh DELETE for all rows matching the AND conditions. Zero affected rows is allowed. |

`match` values are exact equality tests; JSON `null` means SQL `IS NULL`. There is no free-form SQL or OR operator. Multiple `update` or `delete` steps for the same table can use different match conditions. Keep their selectors disjoint when the final validation needs to check each result. A table configured as `restoreRows` or `replaceTable` cannot also use fixed `update` or `delete`; fixed `update` and `delete` may share a table if the delete does not remove rows needed for update validation.

To set the same value in every row of `CONFIG`, use a step without `match`:

```json
{
  "type": "update",
  "table": "CONFIG",
  "set": {"CONFIG_VALUE": "https://api-test.example.cz"}
}
```

The entire table is exported to CSV and INSERT SQL during capture. Validation checks that every row still present in the table has the configured value; with `expectedRows`, it also checks the final row count. Avoid subsequent steps that change this column unless they leave the same final value.

**Execution order:** All destinations are checked first. Every `replaceTable` is then **truncated in reverse order** of the `schemaOrder`/`steps` traversal (children before parents). Next, schemas run in `schemaOrder` and each schema's steps run from top to bottom. At a `replaceTable` step, the previously truncated table is inserted (parents before children). This keeps the required reverse TRUNCATE/forward INSERT order across schemas. Oracle may still prohibit `TRUNCATE` on a referenced parent with an enabled foreign key; arrange DBA constraint handling or use a separate DELETE approach if needed. TRUNCATE commits immediately; a later failure can leave tables empty or partially restored. Preserve the snapshot and rerun after resolving the cause.

## Operation

1. **You, before DBA refresh:** `./scripts/Capture.ps1`. Proceed only after `CAPTURE SUCCESS`. Keep the entire timestamped snapshot directory safely outside the database.
2. **DBA:** performs the clone or restore from backup.
3. **You, after DBA refresh:** `./scripts/Restore.ps1 -Snapshot './snapshots/<timestamp>/snapshot.json'`. This runs restore and validation; either error fails the command. `Validate.ps1 -Snapshot '...'` repeats validation independently when needed.

For **every configured table**, capture exports all rows and all supported visible, nonvirtual columns to `<schema>/<table>.csv` and `<schema>/<table>.insert.sql`. These manual INSERT scripts are never run automatically and contain no COMMIT. The CSV carries `__IS_NULL` flags. Optional `backupMaxRows` (for restoreRows/update/delete) and `maxRows` (for replaceTable) stop capture if exceeded. The JSON snapshot keeps only the data needed for automatic restore and the step plan. Capture fails if a backup cannot be completed. Checksums detect accidental changes to the snapshot and exported backups; they are not authenticity signatures.

Before reporting `CAPTURE SUCCESS`, the script reopens the snapshot, verifies its checksum and configuration, checks that every configured table has both backup files, reads and compares all CSV rows and generated INSERT text with the values captured in memory, and checks the backup checksums. If this final check fails, the snapshot is marked `FAILED` and restore refuses it. This verifies the written files; it does not prove that separate queries across tables saw one transactionally consistent database instant. Pause TEST writes during capture.

Supported column types: CHAR, VARCHAR2, NCHAR, NVARCHAR2, NUMBER, DATE, TIMESTAMP and TIMESTAMP WITH TIME ZONE. Unsupported columns, oversized JSON rows, CLOB/BLOB/RAW, and TIMESTAMP WITH LOCAL TIME ZONE stop capture. Pause writes to TEST configuration during capture. Test with representative non-ASCII data and actual Oracle data types before production use.

Local `credentials.json`, schema JSONs, and snapshots are ignored by Git. Passwords are read from the local JSON and supplied to SQL*Plus via stdin, not the command line. Protect these files and do not enable SQL*Plus tracing.
