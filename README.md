# Oracle TEST: capture → DBA refresh → preflight → restore

Nástroj zachová vybrané nastavení TEST databáze a obnoví je po refreshi provedeném DBA. Samotný refresh nespouští. Vyžaduje **Windows PowerShell 5.1**, stávající SQL*Plus a Oracle 19c+. Python, Oracle knihovny pro Python ani dodatečné PowerShell moduly nejsou potřeba. Implementace je v `scripts/OracleRefresh.ps1`; čtyři vstupní skripty ji načítají přímo.

Předpokladem je stejné prostředí a Windows účet, pod kterým funguje ruční `sqlplus APP1/"heslo"@TESTDB`. Alias se vyhodnocuje obvyklým Oracle klientem, například pomocí `tnsnames.ora` a `TNS_ADMIN`. Skript spouští `sqlplus.exe -L -S /nolog` bez okna a CONNECT předává přes standardní vstup. PowerShell execution policy musí dovolovat spuštění skriptů podle pravidel serveru; nástroj ji nemění ani neobchází.

```powershell
$PSVersionTable.PSVersion
Get-Command sqlplus.exe
```

## Konfigurace

1. Zkopírujte `config/database.example.json` na `config/database.json` a doplňte připojení a hesla. Připojení i účty jsou v tomto jediném souboru.
2. Zkopírujte požadované `config/schemas/*.example.json` na soubory bez `.example`. Příklady mohou zůstat na místě; při načítání se ignorují.
3. V `schemaOrder` uveďte všechna používaná schémata právě jednou, v pořadí obnovy. Název `CT.json` vybere účet `users.CT`; jeho `username` musí být `CT`.

```json
{
  "host": "db-server.example.cz",
  "port": 1521,
  "serviceName": "testpdb.example.cz",
  "sqlplusPath": "sqlplus.exe",
  "schemaOrder": ["APP1", "APP2", "CT"],
  "users": {
    "APP1": { "username": "APP1", "password": "DOPLNTE_HESLO_APP1" },
    "APP2": { "username": "APP2", "password": "DOPLNTE_HESLO_APP2" },
    "CT": { "username": "CT", "password": "DOPLNTE_HESLO_CT" }
  }
}
```

Pro přímé připojení zadejte `host` (server nebo IP), `port` a `serviceName`. Vynechaný port má výchozí hodnotu 1521. Service name je název služby používaný při připojení, nikoli název uživatele. SQL*Plus dostane adresu ve tvaru `//host:port/serviceName`.

Pokud používáte existující TNS alias, stačí místo těchto tří polí:

```json
"host": "TESTDB"
```

U TNS aliasu neuvádějte `port` ani `serviceName`: ty se načtou z nastavení Oracle klienta. `host` přijímá také kompletní adresu `server:1521/service` nebo `//server:1521/service` bez samostatného portu/služby. Samotný název serveru bez služby se vyhodnocuje jako připojovací alias Oracle klienta. `sqlplusPath` může být plná cesta k `sqlplus.exe`; při vynechání se použije `sqlplus.exe` z PATH. Volitelný `timeoutSeconds` má výchozí hodnotu 300.

`expectedTarget`, `dbUniqueName` a `conName` se již nenastavují. Cíl určuje připojení; nástroj nezávisle neověřuje identitu databáze. Každé spojení stále ověřuje přihlášený účet před pracovními dotazy. Snapshot a restore plán jsou vázané na připojovací adresu/alias a konfiguraci kroků; změna serveru, portu či služby vyžaduje nový Capture. Změnu cíle uvnitř stejného TNS aliasu tato vazba nedetekuje.

Při přechodu ze dvou souborů přesuňte objekt `users` z `credentials.json` do `database.json`, přejmenujte `tnsAlias` na `host` (nebo zadejte server/port/službu) a odstraňte `expectedTarget`. Soubor `credentials.json` se již nečte. Před dalším refreshem vytvořte nový Capture; staré snapshoty mají jiný otisk konfigurace. Hesla nejsou součástí otisku, takže jejich změna nový Capture nevyžaduje. `database.json` je ignorovaný Gitem.

Účty používají vlastní tabulky. Kontrola cizích klíčů čte `ALL_CONSTRAINTS` a `USER_CONSTRAINTS`; přístup k `SYS.DBA_CONSTRAINTS` není potřeba. Podporované prostředí nemá příchozí cizí klíče mezi různými schématy. Vazby uvnitř schématu se kontrolují automaticky. Nepřístupné externí vazby tento účet nemusí vidět; jejich nepřítomnost je předpokladem nasazení, nikoli výsledkem kontroly. Aktivní triggery na konfigurovaných tabulkách musí před obnovou vyřešit DBA; nástroj je sám nevypíná.

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
| `insert` | `table`, `match` | Při Capture zachytí celé vybrané řádky a vytvoří CSV/INSERT SQL. Při Restore vloží chybějící zachycené řádky; ostatní řádky ponechá. Volitelné `key`, `maxInsertRows`, `expectedRows`. |

`match` používá rovnosti spojené AND. JSON `null` a prázdný řetězec používají Oracle `IS NULL`. Volné SQL ani OR nejsou povolené. Názvy tabulek a sloupců se normalizují na velká písmena; quoted identifiers nejsou podporovány.

`update.key` musí být jedinečný a neprázdný v cílové tabulce a nesmí se měnit v `set`. Doporučen je primární klíč. Všechny UPDATE stejné tabulky musí použít stejný seznam klíčových sloupců. Překrývající se UPDATE a DELETE zasahující řádky potřebné pro validaci UPDATE preflight odmítne. `restoreRows`, `replaceTable` a `insert` nelze kombinovat s jinými kroky na stejné tabulce.

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

### Filtrovaný INSERT

```json
{
  "type": "insert",
  "table": "TEMP_MESSAGES",
  "match": {
    "SOURCE": "PROD",
    "STATUS": "PENDING"
  },
  "maxInsertRows": 10000
}
```

`match` je povinný neprázdný filtr se stejnými pravidly jako u `delete` (rovnosti spojené AND, `null` a prázdný řetězec jako IS NULL). Vyhodnocuje se **při Capture**, nikoli znovu po refreshi. Uloží se všechny podporované uložené sloupce vybraných řádků včetně těch, které nejsou ve filtru. Exporty jsou vedle snapshotu ve složce schématu: `TEMP_MESSAGES.csv` a `TEMP_MESSAGES.insert.sql`. U tohoto kroku obsahují pouze vybrané řádky. SQL soubor obsahuje běžné INSERT příkazy pro ruční použití bez automatického COMMIT; spouštějte jej pouze tehdy, pokud v cíli zachycené řádky ještě nejsou.

Restore používá zachycené hodnoty ze snapshotu, nikoli ručně upravený SQL soubor. Chybějící řádek vloží, shodný existující řádek přeskočí. Existující řádek se stejným klíčem a jinými hodnotami je konflikt: preflight obnovu odmítne, případná pozdější chyba vrátí celou transakci schématu. Dodatečné řádky po refreshi i řádky mimo filtr zůstanou beze změny. Opakování Restore tak nevytváří duplicity.

Klíč se automaticky převezme z aktivního primárního klíče tabulky a uloží do snapshotu. Pokud tabulka primární klíč nemá, zadejte například `"key": ["MESSAGE_ID"]`; lze použít i složený klíč. Sloupce klíče musí být v tabulce jedinečné a neprázdné při Capture i Preflight. Bez vhodného klíče Capture skončí chybou.

`maxInsertRows` je volitelný strop počtu zachycených řádků (nikoli počet nových řádků při opakování). Bez něj není počet omezen. `expectedRows` volitelně požaduje přesný počet; nula vybraných řádků je jinak platná a vytvoří prázdný export. `backupMaxRows`, je-li uvedeno, u tohoto kroku omezuje také jen filtrovaný výběr. Identity a neviditelné sloupce se odmítají, virtuální sloupce se nevkládají. Pro navázané INSERT kroky uveďte rodiče před dětmi; Oracle kontroluje FK během transakce. Jeden `insert` je jediným krokem pro danou tabulku, nelze jej tedy kombinovat s `delete` téže tabulky.

`maxDeleteRows` je u `replaceTable` nepovinný: při vynechání se smaže celý obsah bez limitu počtu řádků a bez předběžného počítání pro tento limit. Také `maxRows` lze vynechat pro capture bez početního limitu. U filtrovaného kroku `delete` zůstává `maxDeleteRows` povinný. Zadaný `maxDeleteRows` omezuje počet skutečně mazaných řádků po refreshi. Kontroluje se při preflightu i bezprostředně po DELETE v transakci; překročení způsobí rollback schématu. U `replaceTable` musí limit pokrýt také počet zachycených řádků, aby šla obnova zopakovat. `backupMaxRows` u ostatních kroků omezuje velikost zálohy při capture, nikoli rozsah mazání.

## Provozní postup

### Database Refresh Utility

Při **Restore** se chybějící řádky typu `restoreRows` zapisují samostatně do složky `recovery/<čas-běhu>-<id>/` vedle `snapshot.json`. Každé schéma má soubor `<schema>.skipped-updates.json` s tabulkou, klíčem a původními obnovovanými hodnotami. Záznamy odpovídají UPDATE, které při daném běhu skutečně nezasáhly žádný řádek; nejde jen o výsledek Preflight.

Pokud existují přeskočené řádky, aplikace je dohledá v plné CSV záloze, ověří její SHA-256 a vytvoří `<schema>.missing-rows.insert.sql`. Soubor obsahuje celé původní řádky včetně sloupců mimo `columns` a vloží je pouze tehdy, pokud jejich klíč stále chybí. Skript se automaticky nespouští ani neprovádí COMMIT. Před ručním spuštěním v SQL*Plus pod odpovídajícím schématem zkontrolujte hodnoty a pořadí tabulek podle cizích klíčů; výsledek potvrďte příkazem COMMIT nebo zrušte příkazem ROLLBACK. Kontrola přihlášeného účtu je součástí skriptu. Identity sloupce vyžadují ruční přípravu INSERT; při chybě generování zůstává samostatný log zachovaný a aplikace oznámí, že obnova schématu již byla potvrzena.

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

Preflight pouze čte databázi a nevytváří plán obnovy na disku. Kontroluje připojení, účet, strukturu sloupců včetně délek, přesnosti, škály, NULL a identity atributů, existenci a jednoznačnost obnovovaných klíčů, limity mazání, pevně zadávané hodnoty, triggery a závislosti náhrad celých tabulek. Není zkušebním provedením DML: například CHECK constraints se mohou projevit až během transakce, která pak provede rollback.

## Transakce, pořadí a selhání

Všechna schémata projdou preflightem před prvním zápisem. Pak běží postupně podle `schemaOrder`, každé v **jediné vlastní transakci**:

1. Zamknou se konfigurované tabulky daného schématu pomocí `LOCK TABLE ... IN EXCLUSIVE MODE NOWAIT`. Obsazený zámek způsobí chybu.
2. Tabulky `replaceTable` se vymažou v opačném pořadí kroků, tedy děti před rodiči.
3. Kroky se provedou v uvedeném pořadí, včetně INSERT rodičů před dětmi.
4. V téže transakci se zkontrolují výsledné hodnoty a počty. Teprve potom proběhne jeden COMMIT.

**TRUNCATE se nepoužívá.** Chyba DML nebo vnitřní validace vrátí změny aktuálního schématu. Dříve dokončená schémata zůstanou potvrzená a pozdější se nespustí. Nejde o jednu transakci přes všechna schémata. Při ztrátě spojení právě během COMMIT může být výsledek nejistý; ověřte jej validací nebo obnovu zopakujte se stejným plánem.

Pro příchozí aktivní FK k nahrazované tabulce musí být i dětská tabulka mezi `replaceTable` ve stejném schématu a za rodičem. Viditelné vazby z jiných schémat, cykly, samoodkazy a nenahrazované závislé tabulky preflight odmítá. Neviditelné externí vazby automaticky ověřit nemůže. Tyto případy vyžadují samostatný postup DBA; nástroj automaticky nevypíná constraints. Identity a neviditelné sloupce v `replaceTable` se odmítají. Virtuální sloupce se nevkládají a UPDATE nesmí měnit virtuální ani identity sloupce.


## Opakování a plán UPDATE

Před prvním zápisem restore atomicky uloží `restore-plan.json` vedle snapshotu. Obsahuje klíče řádků vybraných **po refreshi**, vazbu na snapshot a cíl a kontrolní součet. Při opakování se používají tyto původní klíče, i když UPDATE již změnil sloupec z `match`. Správně funguje i přiřazení stejné hodnoty, například `STATUS = 'TEST'` tam, kde už TEST je.

Po odstranění příčiny chyby spusťte stejný Restore znovu. Dokončená schémata se znovu aplikují; stav se neodhaduje jen podle uloženého příznaku úspěchu. Plán ani snapshot nemažte nebo ručně neupravujte. Pokud chybí plán, samostatná validace UPDATE skončí chybou. Nový DBA refresh vyžaduje nový capture a nový adresář snapshotu. Pro jeden snapshot nespouštějte více obnov souběžně.

Plán je po prvním uložení neměnný. Restore drží výhradní souborový zámek `restore-plan.json.lock`, takže druhý proces nad stejným snapshotem skončí před prací. Prázdný lock soubor může zůstat na disku; rozhodující je aktivní zámek operačního systému, který se při ukončení procesu uvolní.

Pokud wrapper oznámí chybu až při samostatné validaci po restore, transakce obnovy již byly potvrzené a tato následná kontrola je nevrátí.

## Zálohy a datové typy

Capture pro každou konfigurovanou tabulku uloží všechny podporované viditelné nevirtuální sloupce do CSV a ručního INSERT SQL. Krok `insert` exportuje pouze řádky podle `match`; ostatní kroky zálohují celou tabulku. CSV obsahuje příznaky `__IS_NULL`. INSERT soubory se automaticky nespouštějí a neobsahují COMMIT. Jsou určeny pro předem vyprázdněný cíl nebo odstraněné řádky; jejich ruční použití vyžaduje kontrolu identity, FK, triggerů a struktury cíle. Automatická obnova kroku `insert` používá data ze snapshotu a vlastní transakční SQL.

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
