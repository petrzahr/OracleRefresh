# Testování

## Lokální regrese

Z kořene projektu spusťte:

```powershell
python -B -m unittest discover -s tests -v
```

Používá se pouze standardní knihovna Pythonu. Lokální testy pokrývají načítání příkladů, povinnou konfiguraci, SQL*Plus transport a kontrolu cíle, bezpečné literály, validaci UPDATE přes klíče, limity, FK pořadí, read-only preflight a opakování po simulované chybě. Neprokazují chování skutečného Oracle.

## Oracle integrační testy

Sada vyžaduje SQL*Plus a Oracle 19c+ s databázovou znakovou sadou podporující češtinu (doporučeno AL32UTF8). **Použijte vyhrazené prázdné testovací schéma s názvem `ORF_TEST_*`.** Testy vytvářejí a mažou vlastní náhodně pojmenované tabulky `ORF_<náhodný identifikátor>_*`, provádějí COMMIT a testují rollback. Neprovádějí DBA refresh a nepracují s aplikačními tabulkami.

DBA musí účtu udělit CREATE SESSION, CREATE TABLE, kvótu v jeho tablespace a přímé SELECT ON SYS.DBA_CONSTRAINTS. Oprávnění k DROP/ALTER vlastních testovacích tabulek vyplývá z vlastnictví. Testovací účet nemá potřebovat přístup k datům aplikací.

Vytvořte lokální `config/integration.json` (Git jej ignoruje):

```json
{
  "database": {
    "tnsAlias": "TESTDB",
    "sqlplusPath": "sqlplus.exe",
    "expectedTarget": {
      "dbUniqueName": "TESTDB",
      "serviceName": "testpdb.example.cz",
      "conName": "TESTPDB"
    }
  },
  "account": {
    "username": "ORF_TEST_REFRESH",
    "password": "DOPLNTE_LOKALNE"
  }
}
```

Hodnoty cíle ověřte nezávisle s DBA. Test s chybným cílem úmyslně očekává odmítnutí připojení před pracovním dotazem.

```powershell
$env:ORACLE_REFRESH_INTEGRATION_CONFIG = (Resolve-Path ./config/integration.json).Path
python -B -m unittest discover -s tests -p test_oracle_integration.py -v
Remove-Item Env:ORACLE_REFRESH_INTEGRATION_CONFIG
```

Scénáře ověřují:

- skutečný capture → změnu dat simulující refresh → preflight → restore → validate;
- češtinu, národní znaky, apostrofy, ampersand, prázdné řádky, lomítko na samostatném řádku a CRLF;
- NULL, přesný NUMBER, DATE, TIMESTAMP(9) a TIMESTAMP WITH TIME ZONE;
- rodičovskou a dětskou tabulku s aktivním FK a opačné pořadí DELETE;
- UPDATE se stejnou hodnotou v match/set i změnu hodnoty match, následně opakovaný restore;
- pozdní chybu CHECK constraint po předchozích DML, rollback celého schématu a úspěšné opakování;
- odmítnutí chybějícího klíče, změny délky sloupce, překročení limitu mazání a chybného cíle.

Každý test má vlastní tabulky a dočasný adresář snapshotů. Při běžném ukončení se uklidí. Po násilném ukončení procesu mohou zůstat tabulky s prefixem ORF_; uklízejte pouze objekty daného testovacího běhu.
