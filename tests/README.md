# Testování

## Lokální regrese

Z kořene projektu spusťte:

```powershell
powershell.exe -NoProfile -File .\tests\Test-OracleRefresh.ps1
powershell.exe -NoProfile -STA -File .\tests\Test-OracleRefreshUI.ps1
```

Používá se Windows PowerShell 5.1 a vestavěný .NET Framework, bez Pythonu, Pesteru nebo dodatečných modulů. Lokální testy pokrývají načítání příkladů, zachování JSON polí/NULL/řetězců, povinnou konfiguraci, SQL*Plus transport a kontrolu účtu, bezpečné literály, validaci UPDATE přes klíče, volitelné limity, FK pořadí, read-only preflight, capture všech typů kroků a opakování po simulované chybě. Přenos UTF-8 a současné čtení stdout/stderr se ověřují skutečným pomocným procesem PowerShellu; samostatný test vyvolá timeout. Databázové odpovědi jsou v lokálních testech simulované, takže neprokazují chování skutečného Oracle.

## Oracle integrační testy

UI testy vytvářejí skutečné Windows Forms ovládací prvky bez zobrazení okna a používají dočasný simulovaný engine. Ověřují průběžné hlášky, asynchronní spuštění, zobrazení chyb, výběr nového snapshotu, blokování souběhu i zavření během běhu. Vyžadují Windows Forms, ale nepřipojují se k Oracle.

Sada vyžaduje SQL*Plus a Oracle 19c+ s databázovou znakovou sadou podporující češtinu (doporučeno AL32UTF8). **Použijte vyhrazené prázdné testovací schéma s názvem `ORF_TEST_*`.** Testy vytvářejí a mažou vlastní náhodně pojmenované tabulky `ORF_<náhodný identifikátor>_*`, provádějí COMMIT a testují rollback. Neprovádějí DBA refresh a nepracují s aplikačními tabulkami.

Bez nastavení konfigurace lze ověřit přeskočení celé integrační sady: `powershell.exe -NoProfile -File .\tests\Test-OracleIntegration.ps1`. Vypíše `SKIP` pro osm scénářů a nepřipojí se do databáze.

DBA musí účtu udělit CREATE SESSION, CREATE TABLE a kvótu v jeho tablespace. Přístup k SYS.DBA_CONSTRAINTS není potřeba; kontrola používá ALL_CONSTRAINTS a USER_CONSTRAINTS. Oprávnění k DROP/ALTER vlastních testovacích tabulek vyplývá z vlastnictví. Testovací účet nemá potřebovat přístup k datům aplikací. Sada vytváří izolované tabulky bez vazeb z jiných schémat.

Vytvořte lokální `config/integration.json` (Git jej ignoruje):

```json
{
  "host": "localhost",
  "port": 1521,
  "serviceName": "XEPDB1",
  "sqlplusPath": "sqlplus.exe",
  "schemaOrder": ["ORF_TEST_REFRESH"],
  "users": {
    "ORF_TEST_REFRESH": {
      "username": "ORF_TEST_REFRESH",
      "password": "DOPLNTE_LOKALNE"
    }
  }
}
```

Formát je stejný jako `database.json`, pouze s jedním vyhrazeným testovacím schématem. Pro TNS alias použijte například `"host": "TESTDB"` a vynechte `port` i `serviceName`. Test s chybným očekávaným účtem ověřuje odmítnutí před pracovním dotazem. Identitu databáze podle DB_UNIQUE_NAME/CON_NAME sada neověřuje.

```powershell
$env:ORACLE_REFRESH_INTEGRATION_CONFIG = (Resolve-Path ./config/integration.json).Path
powershell.exe -NoProfile -File .\tests\Test-OracleIntegration.ps1
Remove-Item Env:ORACLE_REFRESH_INTEGRATION_CONFIG
```

Scénáře ověřují:

- skutečný capture → změnu dat simulující refresh → preflight → restore → validate;
- češtinu, národní znaky, apostrofy, ampersand, prázdné řádky, lomítko na samostatném řádku a CRLF;
- NULL, přesný NUMBER, DATE, TIMESTAMP(9) a TIMESTAMP WITH TIME ZONE včetně kladných, záporných a necelohodinových offsetů;
- rodičovskou a dětskou tabulku s aktivním FK a opačné pořadí DELETE;
- UPDATE se stejnou hodnotou v match/set i změnu hodnoty match, následně opakovaný restore;
- pozdní chybu CHECK constraint po předchozích DML, rollback celého schématu a úspěšné opakování;
- přeskočení chybějícího klíče s recovery výstupem a zachování dodatečných řádků;
- odmítnutí změny délky sloupce, překročení limitu mazání a chybného účtu;
- odmítnutí nekonfigurované dětské tabulky s ON DELETE CASCADE před zápisem, se zachováním rodičovských i dětských dat.
- filtrovaný INSERT celých řádků, provedení exportovaného SQL bez automatického COMMIT, automatické nalezení primárního klíče, opakovaný Restore bez duplicit, zachování dalších řádků a rollback vložených dat;
- odmítnutí INSERT konfliktu klíče před jakýmkoli zápisem a úspěšnou obnovu po odstranění konfliktu.

Každý test má vlastní tabulky a dočasný adresář snapshotů. Při běžném ukončení se uklidí. Po násilném ukončení procesu mohou zůstat tabulky s prefixem ORF_; uklízejte pouze objekty daného testovacího běhu.
