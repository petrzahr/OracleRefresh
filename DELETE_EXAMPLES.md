# Mazání podle explicitních klíčů nebo celé tabulky

Připojení a účty patří do `config/database.json`. Pro schéma APP1 uveďte `APP1` v `schemaOrder` a vytvořte `config/schemas/APP1.json`.

```json
{
  "steps": [
    {
      "type": "delete",
      "table": "TEMP_MESSAGES",
      "key": ["MESSAGE_ID"],
      "match": [{"MESSAGE_ID": 101}, {"MESSAGE_ID": 102}]
    }
  ]
}
```

`match` obsahuje přesně sloupce z `key`. Obecný filtr nad SOURCE/STATUS se nepoužívá; vyberte konkrétní identifikátory. Chybějící řádky nevadí.

Pro smazání celé tabulky použijte místo předchozího kroku:

```json
{
  "steps": [
    {"type": "delete", "table": "TEMP_MESSAGES", "allRows": true}
  ]
}
```

Tato varianta nepotřebuje `key`. Při každém spuštění smaže celý aktuální obsah včetně nově přidaných řádků. DELETE se provádí až po refreshi; Capture uloží úplnou CSV a SQL zálohu tabulky.

Mazání probíhá v transakci schématu a po kontrole výsledků se potvrdí společným COMMIT. DELETE nesmí odstranit řádky potřebné pro validaci UPDATE; preflight překryv odmítne. Další varianty jsou v [CONFIG_EXAMPLES.md](CONFIG_EXAMPLES.md).
