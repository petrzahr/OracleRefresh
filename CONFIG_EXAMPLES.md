# Vzorové konfigurace operací

Každý příklad je samostatný soubor schématu, například `config/schemas/APP1.json`. Nahraďte názvy a hodnoty podle své databáze. Pravidla a chování operací popisuje [README](README.md#kroky-ve-schématu).

## 1. Pouze záloha celé tabulky

```json
{
  "steps": [
    {
      "type": "backupTable",
      "table": "AUDIT_LOG",
      "allRows": true
    }
  ]
}
```

## 2. Pouze záloha konkrétních řádků

```json
{
  "steps": [
    {
      "type": "backupTable",
      "table": "AUDIT_LOG",
      "key": [
        "LOG_ID"
      ],
      "match": [
        {
          "LOG_ID": 101
        },
        {
          "LOG_ID": 102
        }
      ]
    }
  ]
}
```

## 3. Obnova sloupců konkrétních řádků

```json
{
  "steps": [
    {
      "type": "restoreRows",
      "table": "CONFIG",
      "key": [
        "CONFIG_KEY"
      ],
      "match": [
        {
          "CONFIG_KEY": "API_URL"
        },
        {
          "CONFIG_KEY": "CALLBACK_URL"
        }
      ],
      "columns": [
        "CONFIG_VALUE",
        "DESCRIPTION"
      ]
    }
  ]
}
```

## 4. Obnova sloupců všech původních řádků

```json
{
  "steps": [
    {
      "type": "restoreRows",
      "table": "CONFIG",
      "key": [
        "CONFIG_KEY"
      ],
      "allRows": true,
      "columns": [
        "CONFIG_VALUE",
        "DESCRIPTION"
      ]
    }
  ]
}
```

## 5. Obnova podle složeného klíče

```json
{
  "steps": [
    {
      "type": "restoreRows",
      "table": "TENANT_CONFIG",
      "key": [
        "TENANT_ID",
        "CONFIG_KEY"
      ],
      "match": [
        {
          "TENANT_ID": 10,
          "CONFIG_KEY": "API_URL"
        },
        {
          "TENANT_ID": 20,
          "CONFIG_KEY": "API_URL"
        }
      ],
      "columns": [
        "CONFIG_VALUE",
        "DESCRIPTION"
      ]
    }
  ]
}
```

## 6. Nahrazení celého obsahu tabulky

```json
{
  "steps": [
    {
      "type": "replaceTable",
      "table": "LOOKUP",
      "allRows": true
    }
  ]
}
```

## 7. Nahrazení navázaných tabulek

```json
{
  "steps": [
    {
      "type": "replaceTable",
      "table": "USERS",
      "allRows": true
    },
    {
      "type": "replaceTable",
      "table": "USERGROUPS",
      "allRows": true
    }
  ]
}
```

## 8. Doplnění konkrétních zachycených řádků

```json
{
  "steps": [
    {
      "type": "insert",
      "table": "CONFIG",
      "key": [
        "CONFIG_KEY"
      ],
      "match": [
        {
          "CONFIG_KEY": "API_URL"
        },
        {
          "CONFIG_KEY": "CALLBACK_URL"
        }
      ]
    }
  ]
}
```

## 9. Doplnění všech původních řádků

```json
{
  "steps": [
    {
      "type": "insert",
      "table": "TEST_USERS",
      "key": [
        "USER_ID"
      ],
      "allRows": true
    }
  ]
}
```

## 10. Nastavení hodnot konkrétnímu řádku

```json
{
  "steps": [
    {
      "type": "update",
      "table": "CONFIG",
      "key": [
        "CONFIG_KEY"
      ],
      "match": [
        {
          "CONFIG_KEY": "API_URL"
        }
      ],
      "set": {
        "CONFIG_VALUE": "https://api-test.example.cz",
        "DESCRIPTION": "Testovací API"
      }
    }
  ]
}
```

## 11. Stejné hodnoty několika řádkům

```json
{
  "steps": [
    {
      "type": "update",
      "table": "INTEGRATIONS",
      "key": [
        "INTEGRATION_ID"
      ],
      "match": [
        {
          "INTEGRATION_ID": 10
        },
        {
          "INTEGRATION_ID": 20
        }
      ],
      "set": {
        "ENABLED": 0
      }
    }
  ]
}
```

## 12. Nastavení hodnot všem řádkům

```json
{
  "steps": [
    {
      "type": "update",
      "table": "NOTIFICATION_SETTINGS",
      "key": [
        "ID"
      ],
      "allRows": true,
      "set": {
        "ENABLED": 0,
        "RECIPIENT_EMAIL": null
      }
    }
  ]
}
```

## 13. Smazání konkrétních řádků

```json
{
  "steps": [
    {
      "type": "delete",
      "table": "TEMP_MESSAGES",
      "key": [
        "MESSAGE_ID"
      ],
      "match": [
        {
          "MESSAGE_ID": 101
        },
        {
          "MESSAGE_ID": 102
        }
      ]
    }
  ]
}
```

## 14. Smazání všech řádků

```json
{
  "steps": [
    {
      "type": "delete",
      "table": "TEMP_MESSAGES",
      "allRows": true
    }
  ]
}
```
