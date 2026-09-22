# Oracle TEST: capture → DBA refresh → preflight → restore

Nástroj zachová vybrané nastavení TEST databáze a obnoví je po refreshi provedeném DBA. Samotný refresh nespouští. Vyžaduje Python 3.9+, PowerShell, SQL*Plus a Oracle 19c+.

## Konfigurace

1. Zkopírujte `config/database.example.json` na `config/database.json`.
2. Zkopírujte `config/credentials.example.json` na `config/credentials.json` a doplňte účty.
3. Zkopírujte požadované `config/schemas/*.example.json` na soubory bez `.example`. Příklady mohou zůstat na místě; při načítání se ignorují.
4. V `schemaOrder` uveďte všechna používaná schémata právě jednou, v pořadí obnovy. Název `CT.json` vybere účet `CT` z credentials.

```json
{
  "tnsAlias": "TESTDB",
  "sqlplusPath": "sqlplus.exe",
  "schemaOrder": ["APP1", "APP2", "CT"],
  "expectedTarget": {
    "dbUniqueName": "TESTDB",
    "serviceName": "testpdb.example.cz",
    "conName": "TESTPDB"
  },
  "timeoutSeconds": 300
}
```

`expectedTarget` je povinný. Skutečné hodnoty nechte ověřit DBA na cílovém TEST prostředí:

```sql
SELECT SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME') AS db_unique_name,
       SYS_CONTEXT('USERENV', 'SERVICE_NAME') AS service_name,
       SYS_CONTEXT('USERENV', 'CON_NAME') AS con_name
FROM dual;
```

Každé spojení ověřuje tyto tři hodnoty a přihlášený účet ještě před pracovními dotazy. Porovnání názvů cíle ignoruje velikost písmen. Samotný TNS alias není důkazem identity databáze. Pro non-CDB vyplňte skutečnou vrácenou hodnotu `CON_NAME`. Očekávaný cíl nastavte nezávisle na snapshotu; nenastavujte jej automaticky podle právě připojené databáze.

Účty používají vlastní tabulky. Pro `replaceTable` potřebují také přímé oprávnění `SELECT ON SYS.DBA_CONSTRAINTS`, aby preflight viděl i příchozí cizí klíče z jinak nepřístupných schémat. Bez něj kontrola skončí chybou. Aktivní triggery na konfigurovaných tabulkách musí před obnovou vyřešit DBA; nástroj je sám nevypíná.

## Kroky ve schématu

Každý soubor obsahuje jedno pole `steps`.

| Typ | Povinná pole | Chování |
| --- | --- | --- |
| `restoreRows` | `table`, `key`, `columns`, `keyValues` nebo `allRows: true` | Obnoví vybrané sloupce zachycených řádků podle unikátních neprázdných klíčů. `allRows` znamená všechny řádky zachycené před refreshem; další řádky po refreshi ponechá. |
| `replaceTable` | `table`, `maxDeleteRows` | Nahradí obsah pomocí transakčních DELETE a INSERT. Volitelné `maxRows` omezuje capture a `expectedRows` vyžaduje přesný počet zachycených řádků. |
| `update` | `table`, `key`, `set`; volitelně `match` | Nastaví pevné hodnoty v řádcích vybraných až po refreshi. `key` identifikuje řádky pro provedení, opakování i validaci. |
| `delete` | `table`, `match`, `maxDeleteRows` | Smaže odpovídající řádky. Nula řádků je platný výsledek, také při opakování obnovy. |

`match` používá rovnosti spojené AND. JSON `null` a prázdný řetězec používají Oracle `IS NULL`. Volné SQL ani OR nejsou povolené. Názvy tabulek a sloupců se normalizují na velká písmena; quoted identifiers nejsou podporovány.

`update.key` musí být jedinečný a neprázdný v cílové tabulce a nesmí se měnit v `set`. Doporučen je primární klíč. Všechny UPDATE stejné tabulky musí použít stejný seznam klíčových sloupců. Překrývající se UPDATE a DELETE zasahující řádky potřebné pro validaci UPDATE preflight odmítne. `restoreRows` a `replaceTable` nelze kombinovat s jinými typy operací na stejné tabulce.

```json
{
  "steps": [
    {
      "type": "update",
      "table": "CONFIG",
      "key": ["ID"],
      "match": {"STATUS": "PROD"},
      "set": {"STATUS": "TEST", "CONFIG_VALUE": "https://api-test.example.cz"},
      "expectedRows": 1
    },
    {
      "type": "delete",
      "table": "TEMP_MESSAGES",
      "match": {"SOURCE": "PROD", "STATUS": "PENDING"},
      "maxDeleteRows": 1000
    }
  ]
}
```

Bez `match` UPDATE vybere celou tabulku; `key` je i v tomto případě povinný. `expectedRows` kontroluje počet původně vybraných řádků a platí také při validaci. Bez něj filtrovaný UPDATE vyžaduje alespoň jeden řádek; celotabulkový UPDATE připouští i prázdnou tabulku. `expectedRows: 0` je podporováno.

`maxDeleteRows` omezuje počet skutečně mazaných řádků po refreshi. Kontroluje se při preflightu i bezprostředně po DELETE v transakci; překročení způsobí rollback schématu. U `replaceTable` musí limit pokrýt také počet zachycených řádků, aby šla obnova zopakovat. `backupMaxRows` u ostatních kroků omezuje velikost zálohy při capture, nikoli rozsah mazání.

## Provozní postup

1. Zastavte zápisy aplikací do konfigurovaných tabulek. Ponechte je zastavené po dobu capture, refresh, restore a validace.
2. Před refreshem spusťte `./scripts/Capture.ps1`. Pokračujte až po `CAPTURE SUCCESS` a uchovejte celý adresář snapshotu mimo databázi.
3. DBA provede refresh.
4. Spusťte `./scripts/Preflight.ps1 -Snapshot './snapshots/<timestamp>/snapshot.json'`.
5. Po `PREFLIGHT SUCCESS` spusťte `./scripts/Restore.ps1 -Snapshot './snapshots/<timestamp>/snapshot.json'`. Restore zopakuje preflight, provede obnovu a wrapper spustí samostatnou validaci.
6. Validaci lze zopakovat pomocí `./scripts/Validate.ps1 -Snapshot '...'`.

Preflight pouze čte databázi a nevytváří plán obnovy na disku. Kontroluje cíl, strukturu sloupců včetně délek, přesnosti, škály, NULL a identity atributů, existenci a jednoznačnost obnovovaných klíčů, limity mazání, pevně zadávané hodnoty, triggery a závislosti náhrad celých tabulek. Není zkušebním provedením DML: například CHECK constraints se mohou projevit až během transakce, která pak provede rollback.

## Transakce, pořadí a selhání

Všechna schémata projdou preflightem před prvním zápisem. Pak běží postupně podle `schemaOrder`, každé v **jediné vlastní transakci**:

1. Zamknou se konfigurované tabulky daného schématu pomocí `LOCK TABLE ... IN EXCLUSIVE MODE NOWAIT`. Obsazený zámek způsobí chybu.
2. Tabulky `replaceTable` se vymažou v opačném pořadí kroků, tedy děti před rodiči.
3. Kroky se provedou v uvedeném pořadí, včetně INSERT rodičů před dětmi.
4. V téže transakci se zkontrolují výsledné hodnoty a počty. Teprve potom proběhne jeden COMMIT.

**TRUNCATE se nepoužívá.** Chyba DML nebo vnitřní validace vrátí změny aktuálního schématu. Dříve dokončená schémata zůstanou potvrzená a pozdější se nespustí. Nejde o jednu transakci přes všechna schémata. Při ztrátě spojení právě během COMMIT může být výsledek nejistý; ověřte jej validací nebo obnovu zopakujte se stejným plánem.

Pro příchozí aktivní FK k nahrazované tabulce musí být i dětská tabulka mezi `replaceTable` ve stejném schématu a za rodičem. Vazby z jiných schémat, cykly, samoodkazy a nenahrazované závislé tabulky preflight odmítá. Tyto případy vyžadují samostatný postup DBA; nástroj automaticky nevypíná constraints. Identity a neviditelné sloupce v `replaceTable` se odmítají. Virtuální sloupce se nevkládají a UPDATE nesmí měnit virtuální ani identity sloupce.

## Opakování a plán UPDATE

Před prvním zápisem restore atomicky uloží `restore-plan.json` vedle snapshotu. Obsahuje klíče řádků vybraných **po refreshi**, vazbu na snapshot a cíl a kontrolní součet. Při opakování se používají tyto původní klíče, i když UPDATE již změnil sloupec z `match`. Správně funguje i přiřazení stejné hodnoty, například `STATUS = 'TEST'` tam, kde už TEST je.

Po odstranění příčiny chyby spusťte stejný Restore znovu. Dokončená schémata se znovu aplikují; stav se neodhaduje jen podle uloženého příznaku úspěchu. Plán ani snapshot nemažte nebo ručně neupravujte. Pokud chybí plán, samostatná validace UPDATE skončí chybou. Nový DBA refresh vyžaduje nový capture a nový adresář snapshotu. Pro jeden snapshot nespouštějte více obnov souběžně.

Pokud wrapper oznámí chybu až při samostatné validaci po restore, transakce obnovy již byly potvrzené a tato následná kontrola je nevrátí.

## Zálohy a datové typy

Capture pro každou konfigurovanou tabulku uloží všechny podporované viditelné nevirtuální sloupce do CSV a ručního INSERT SQL. CSV obsahuje příznaky `__IS_NULL`. INSERT soubory se automaticky nespouštějí a neobsahují COMMIT. Jsou určeny pro předem vyprázdněný cíl nebo odstraněné řádky; jejich ruční použití vyžaduje kontrolu identity, FK, triggerů a struktury cíle.

Před `CAPTURE SUCCESS` se snapshot i exporty znovu načtou a porovnají se zachycenými hodnotami a kontrolními součty. Kontrola textu INSERT není důkazem jeho proveditelnosti v libovolném schématu. SHA-256 chrání před náhodnou změnou, nikoli před úmyslným přepsáním dat i součtu. Jednotlivé capture dotazy netvoří společný konzistentní SCN; proto jsou zastavené zápisy nutné.

Podporované typy: CHAR, VARCHAR2, NCHAR, NVARCHAR2, NUMBER, DATE, TIMESTAMP a TIMESTAMP WITH TIME ZONE. NUMBER se ukládá jako text, aby se neztratila přesnost. DATE očekává `YYYY-MM-DD HH24:MI:SS`, TIMESTAMP přidává devět desetinných míst a časová zóna offset `+HH:MM`. U časové zóny se zachovává offset, nikoli název regionu. Nepodporované typy, například CLOB/BLOB/RAW a TIMESTAMP WITH LOCAL TIME ZONE, nebo příliš velký JSON řádek způsobí chybu capture. SQL*Plus komunikuje v UTF-8; víceřádkové řetězce se převádějí na bezpečné výrazy s CHR/NCHR.

Snapshoty verze 1 nejsou kompatibilní. Po aktualizaci doplňte `expectedTarget`, `update.key` a `maxDeleteRows` a proveďte nový capture **před** refreshem. Existující snapshoty nepřepisujte.

Credentials, lokální konfigurace, snapshoty a plány obsahují citlivé údaje a jsou ignorovány Gitem. Hesla jdou SQL*Plus přes stdin, nikoli argumenty procesu; nevypisují se ani hodnoty řádků z chybového SQL.

## Testy

```powershell
python -B -m unittest discover -s tests -v
```

Lokální regresní testy nevyžadují Oracle. Skutečné integrační testy jsou explicitně volitelné a bez konfigurace se zobrazí jako přeskočené; podrobnosti a oprávnění jsou v [tests/README.md](tests/README.md).
