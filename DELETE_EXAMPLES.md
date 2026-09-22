# Ukázka dvou schémat

`config/credentials.json` obsahuje oba účty:

```json
{
  "users": {
    "APP1": {"username": "APP1", "password": "HESLO_APP1"},
    "CT": {"username": "CT", "password": "HESLO_CT"}
  }
}
```

`config/database.json` určí pořadí schémat:

```json
{"tnsAlias": "TESTDB", "sqlplusPath": "sqlplus.exe", "schemaOrder": ["APP1", "CT"]}
```

V `config/schemas/APP1.json` jsou všechny kroky pro APP1 v pořadí, například:

```json
{
  "steps": [
    {"type": "delete", "table": "TEMP_MESSAGES", "match": {"SOURCE": "PROD", "STATUS": "PENDING"}}
  ]
}
```

V `config/schemas/CT.json` jsou kroky pro CT:

```json
{
  "steps": [
    {"type": "update", "table": "CONFIG", "match": {"CONFIG_KEY": "API_URL"}, "set": {"CONFIG_VALUE": "https://api-test.example.cz"}, "expectedRows": 1},
    {"type": "update", "table": "CONFIG", "match": {"CONFIG_KEY": "CALLBACK_URL"}, "set": {"CONFIG_VALUE": "https://callback-test.example.cz", "DESCRIPTIONS": "Test callback"}, "expectedRows": 1},
    {"type": "delete", "table": "CONFIG", "match": {"CONFIG_VALUE": "DUAL_USER"}}
  ]
}
```

Po DBA refreshi se nejprve provede mazání v APP1, pak oba UPDATE kroky v CT v uvedeném pořadí a následně DELETE v CT. Před refreshem vznikne úplná CSV a SQL záloha obou tabulek.
