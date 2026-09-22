# Ukázka dvou schémat

Nejprve připravte `database.json`, `credentials.json` a povinný `expectedTarget` podle [README](README.md). Pro tuto ukázku nastavte `schemaOrder` na `["APP1", "CT"]` a vytvořte pouze odpovídající lokální schema JSON soubory; soubory `.example.json` mohou zůstat.

V `config/schemas/APP1.json`:

```json
{
  "steps": [
    {
      "type": "delete",
      "table": "TEMP_MESSAGES",
      "match": {"SOURCE": "PROD", "STATUS": "PENDING"},
      "maxDeleteRows": 1000
    }
  ]
}
```

V `config/schemas/CT.json`:

```json
{
  "steps": [
    {
      "type": "update",
      "table": "CONFIG",
      "key": ["CONFIG_KEY"],
      "match": {"CONFIG_KEY": "API_URL"},
      "set": {"CONFIG_VALUE": "https://api-test.example.cz"},
      "expectedRows": 1
    },
    {
      "type": "update",
      "table": "CONFIG",
      "key": ["CONFIG_KEY"],
      "match": {"CONFIG_KEY": "CALLBACK_URL"},
      "set": {"CONFIG_VALUE": "https://callback-test.example.cz", "DESCRIPTIONS": "Test callback"},
      "expectedRows": 1
    },
    {
      "type": "delete",
      "table": "CONFIG",
      "match": {"CONFIG_VALUE": "DUAL_USER"},
      "maxDeleteRows": 10
    }
  ]
}
```

`CONFIG_KEY` musí být neprázdný a unikátní v celé CONFIG. Pokud není, použijte skutečný primární klíč, například `ID`. DELETE nesmí odstranit řádky potřebné pro validaci obou UPDATE; preflight takový překryv odmítne.

Před refreshem capture uloží úplné CSV a SQL zálohy tabulek. Po refreshi nejprve spusťte preflight. Restore uloží klíče cílových UPDATE řádků, provede a ověří DELETE v APP1 a potvrdí transakci APP1. Pak provede oba UPDATE a DELETE v CT, ověří jejich výsledky a potvrdí transakci CT. Pokud CT selže, jeho změny se vrátí, ale potvrzený DELETE v APP1 zůstane. Po odstranění příčiny lze stejnou obnovu zopakovat se zachovaným snapshotem i restore-plan.json.
