# Oracle TEST: capture → DBA refresh → preflight → restore

Nástroj zachová vybrané nastavení TEST databáze a obnoví je po refreshi provedeném DBA. Samotný refresh nespouští. Vyžaduje **Windows PowerShell 5.1**, stávající SQL*Plus a Oracle 19c+. Python, Oracle knihovny pro Python ani dodatečné PowerShell moduly nejsou potřeba. Implementace je v `scripts/OracleRefresh.ps1`; čtyři vstupní skripty ji načítají přímo.

Předpokladem je stejné prostředí a Windows účet, pod kterým funguje ruční `sqlplus APP1/"heslo"@TESTDB`. Alias se vyhodnocuje obvyklým Oracle klientem, například pomocí `tnsnames.ora` a `TNS_ADMIN`. Skript spouští `sqlplus.exe -L -S /nolog` bez okna a CONNECT předává přes standardní vstup. PowerShell execution policy musí dovolovat spuštění skriptů podle pravidel serveru; nástroj ji nemění ani neobchází.

```powershell
$PSVersionTable.PSVersion
Get-Command sqlplus.exe
```

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

Pro dvě navázané tabulky `USERS` a `USERGROUPS` bez početních limitů stačí:

```json
{
  "steps": [
    {"type": "replaceTable", "table": "USERS"},
    {"type": "replaceTable", "table": "USERGROUPS"}
  ]
}
```

Mazání proběhne `USERGROUPS → USERS`, vkládání `USERS → USERGROUPS`, vše v jedné transakci schématu. `expectedRows` je nepovinný pro `replaceTable`, `update` i `restoreRows` s `keyValues`; u `allRows: true` se neuvádí.

| Typ | Povinná pole | Chování |
| --- | --- | --- |
| `restoreRows` | `table`, `key`, `columns`, `keyValues` nebo `allRows: true` | Obnoví vybrané sloupce zachycených řádků podle unikátních neprázdných klíčů. `allRows` znamená všechny řádky zachycené před refreshem; další řádky po refreshi ponechá. Chybějící klíče přeskočí s upozorněním; validace kontroluje pouze existující zachycené klíče. Počty řádků před a po refreshi se mohou lišit oběma směry. |
| `replaceTable` | `table` | Nahradí obsah pomocí transakčních DELETE a INSERT. Volitelné `maxRows` omezuje capture a `expectedRows` vyžaduje přesný počet zachycených řádků. |
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

`maxDeleteRows` je u `replaceTable` nepovinný: při vynechání se smaže celý obsah bez limitu počtu řádků a bez předběžného počítání pro tento limit. Také `maxRows` lze vynechat pro capture bez početního limitu. U filtrovaného kroku `delete` zůstává `maxDeleteRows` povinný. Zadaný `maxDeleteRows` omezuje počet skutečně mazaných řádků po refreshi. Kontroluje se při preflightu i bezprostředně po DELETE v transakci; překročení způsobí rollback schématu. U `replaceTable` musí limit pokrýt také počet zachycených řádků, aby šla obnova zopakovat. `backupMaxRows` u ostatních kroků omezuje velikost zálohy při capture, nikoli rozsah mazání.

## Provozní postup

### Database Refresh Utility

Při **Restore** se chybějící řádky typu `restoreRows` zapisují samostatně do složky `recovery/<čas-běhu>-<id>/` vedle `snapshot.json`. Každé schéma má soubor `<schema>.skipped-updates.json` s tabulkou, klíčem a původními obnovovanými hodnotami. Záznamy odpovídají UPDATE, které při daném běhu skutečně nezasáhly žádný řádek; nejde jen o výsledek Preflight.

Pokud existují přeskočené řádky, aplikace je dohledá v plné CSV záloze, ověří její SHA-256 a vytvoří `<schema>.missing-rows.insert.sql`. Soubor obsahuje celé původní řádky včetně sloupců mimo `columns` a vloží je pouze tehdy, pokud jejich klíč stále chybí. Skript se automaticky nespouští ani neprovádí COMMIT. Před ručním spuštěním v SQL*Plus pod odpovídajícím schématem zkontrolujte hodnoty a pořadí tabulek podle cizích klíčů; výsledek potvrďte příkazem COMMIT nebo zrušte příkazem ROLLBACK. Kontrola cílové databáze je součástí skriptu. Identity sloupce vyžadují ruční přípravu INSERT; při chybě generování zůstává samostatný log zachovaný a aplikace oznámí, že obnova schématu již byla potvrzena.

Tento výstup platí pro `restoreRows` s `keyValues` i `allRows`. Operace `update` vybírá řádky až po refreshi, takže nemá seznam původních chybějících řádků pro dodatečné vložení.

Na Windows serveru s grafickým prostředím spusťte z kořene projektu:

```powershell
powershell.exe -NoProfile -STA -File .\scripts\Start-OracleRefreshUI.ps1
```

Okno **Database Refresh Utility** má anglické rozhraní a nabízí **Capture**, **Preflight**, **Restore** a **Validate**, výběr `snapshot.json` a průběžný výpis hlášek. Po úspěšném sběru automaticky vybere nový snapshot. Výpis lze uložit do textového souboru. Používají se stejné konfigurace a stejná logika jako ve spouštěcích skriptech; Obnova zahrnuje preflight i následnou validaci.

Operace běží v samostatném PowerShell runspace, takže okno zůstává ovladatelné. Během práce nejde spustit další operaci ani zavřít okno; po dokončení se tlačítka znovu zpřístupní. UI neprovádí DBA refresh. Jde o lokální Windows Forms okno bez webového serveru a bez instalace dalších modulů. Na Server Core nebo bez interaktivní plochy používejte příkazy níže.

### Spuštění skripty

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

Plán je po prvním uložení neměnný. Restore drží výhradní souborový zámek `restore-plan.json.lock`, takže druhý proces nad stejným snapshotem skončí před prací. Prázdný lock soubor může zůstat na disku; rozhodující je aktivní zámek operačního systému, který se při ukončení procesu uvolní.

Pokud wrapper oznámí chybu až při samostatné validaci po restore, transakce obnovy již byly potvrzené a tato následná kontrola je nevrátí.

## Zálohy a datové typy

Capture pro každou konfigurovanou tabulku uloží všechny podporované viditelné nevirtuální sloupce do CSV a ručního INSERT SQL. CSV obsahuje příznaky `__IS_NULL`. INSERT soubory se automaticky nespouštějí a neobsahují COMMIT. Jsou určeny pro předem vyprázdněný cíl nebo odstraněné řádky; jejich ruční použití vyžaduje kontrolu identity, FK, triggerů a struktury cíle.

Před `CAPTURE SUCCESS` se snapshot i exporty znovu načtou a porovnají se zachycenými hodnotami a kontrolními součty. Kontrola textu INSERT není důkazem jeho proveditelnosti v libovolném schématu. SHA-256 chrání před náhodnou změnou, nikoli před úmyslným přepsáním dat i součtu. Jednotlivé capture dotazy netvoří společný konzistentní SCN; proto jsou zastavené zápisy nutné.

Podporované typy: CHAR, VARCHAR2, NCHAR, NVARCHAR2, NUMBER, DATE, TIMESTAMP a TIMESTAMP WITH TIME ZONE. NUMBER se ukládá jako text, aby se neztratila přesnost. DATE očekává `YYYY-MM-DD HH24:MI:SS`, TIMESTAMP přidává devět desetinných míst a časová zóna offset `+HH:MM`. U časové zóny se zachovává offset, nikoli název regionu. Nepodporované typy, například CLOB/BLOB/RAW a TIMESTAMP WITH LOCAL TIME ZONE, nebo příliš velký JSON řádek způsobí chybu capture. SQL*Plus komunikuje v UTF-8; víceřádkové řetězce se převádějí na bezpečné výrazy s CHR/NCHR.

PowerShell vytváří **snapshoty verze 3** se stejnými exporty CSV/INSERT SQL, ale novým vnitřním uspořádáním kroků a kontrolních součtů. Python snapshoty verzí 1/2 a jejich restore plány se odmítají. JSON konfigurace z předchozí verze se používají beze změny. Při přechodu proveďte nový capture **před** refreshem. Pokud refresh už proběhl a máte jen starý snapshot, dokončete jej původní verzí nástroje; starý snapshot nepřepisujte ani ručně nepřevádějte.

Soubory `.ps1` jsou uložené jako UTF-8 s BOM kvůli Windows PowerShellu 5.1. JSON a SQL exporty používají UTF-8 bez BOM, CSV UTF-8 s BOM. Přenos do SQL*Plus používá explicitní UTF-8 bajty přes .NET proces, současně se čtou stdout i stderr a hlídá se `timeoutSeconds`. Není závislý na kódové stránce konzole. Velká přesná čísla v konfiguraci zapište jako JSON řetězce; NUMBER načtený z Oracle se vždy uchovává jako text.

Credentials, lokální konfigurace, snapshoty a plány obsahují citlivé údaje a jsou ignorovány Gitem. Hesla jdou SQL*Plus přes stdin, nikoli argumenty procesu; nevypisují se ani hodnoty řádků z chybového SQL.

## Testy

```powershell
powershell.exe -NoProfile -File .\tests\Test-OracleRefresh.ps1
powershell.exe -NoProfile -STA -File .\tests\Test-OracleRefreshUI.ps1
powershell.exe -NoProfile -File .\tests\Test-OracleIntegration.ps1
```

Lokální regresní testy běží přímo v PowerShellu 5.1 bez Oracle i bez Pesteru. Ověřují také skutečný přenos UTF-8 do pomocného procesu a timeout. Skutečné integrační testy jsou explicitně volitelné a bez konfigurace se zobrazí jako přeskočené; podrobnosti a oprávnění jsou v [tests/README.md](tests/README.md).
