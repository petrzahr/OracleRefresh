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

Každý soubor obsahuje neprázdné pole `steps`. Kompletní vzory všech variant jsou v [CONFIG_EXAMPLES.md](CONFIG_EXAMPLES.md).

```json
{
  "steps": [
    {"type": "replaceTable", "table": "USERS", "allRows": true},
    {"type": "replaceTable", "table": "USERGROUPS", "allRows": true}
  ]
}
```

Všechny `replaceTable` se nejprve mažou v opačném pořadí konfigurace (i bez FK), potom vkládají v uvedeném pořadí. Zde tedy DELETE `USERGROUPS → USERS`, INSERT `USERS → USERGROUPS`, vše v jedné transakci schématu.

### Jednotný výběr a explicitní klíče

- Vždy zadejte právě jedno z `match` nebo `"allRows": true`. Chybějící výběr, prázdné `match`, `allRows: false` i kombinace obou polí jsou chybou.
- `match` je neprázdné pole objektů. Každý objekt obsahuje přesně sloupce z `key`. Sloupce uvnitř objektu jsou spojené AND, objekty OR. Opakovaná podmínka nevybere řádek vícekrát.
- Kde je `match`, je povinný explicitní `key`. Primární klíč se nikdy automaticky nezjišťuje. Zadaný klíč musí být jedinečný a neprázdný v tabulce; může být složený a nemusí mít databázový constraint.
- `match` vybírá konkrétní identity řádků, nikoli obecné podmínky nad jinými sloupci. Hodnoty klíčů nesmějí být `null` ani prázdný řetězec. Volné SQL, LIKE, rozsahy ani jiné operátory nejsou podporovány.
- Nulový výběr je platný. Počty se vypisují do logu. Pole `keyValues`, `maxRows`, `backupMaxRows`, `maxInsertRows`, `maxDeleteRows` a `expectedRows` byla odstraněna a při načtení vyvolají chybu. Neznámá pole kroků se také odmítají.
- Hodnoty sloupců jsou řetězce, čísla nebo `null`; boolean používejte pouze pro `allRows`. Názvy tabulek a sloupců se normalizují na velká písmena; quoted identifiers nejsou podporovány.

| Typ | Výběr | `key` | Další povinná pole | Chování při Restore |
| --- | --- | --- | --- | --- |
| `backupTable` | `match` nebo `allRows` | Jen s `match` | — | Žádná obnova; Preflight a Validate tabulku také přeskočí. |
| `restoreRows` | `match` nebo `allRows` | Vždy | `columns` | Obnoví původní hodnoty sloupců podle zachycených klíčů. Chybějící řádky přeskočí s upozorněním, nové ponechá. |
| `replaceTable` | Pouze `allRows` | Nepoužívá | — | Smaže celý aktuální obsah a vloží celý zachycený obsah. |
| `insert` | `match` nebo `allRows` | Vždy | — | Vloží chybějící zachycené řádky, shodné přeskočí; stejný klíč s jinými hodnotami je konflikt. |
| `update` | `match` nebo `allRows` | Vždy | `set` | Nastaví pevné hodnoty řádkům vybraným po refreshi; klíče uloží do plánu pro opakování. |
| `delete` | `match` nebo `allRows` | Jen s `match` | — | Smaže konkrétní klíče, nebo celý aktuální obsah tabulky. |

U `backupTable`, `replaceTable` a `delete` s `allRows` se `key` neuvádí a nástroj jej odmítá jako nepoužívaný. `columns` patří pouze k `restoreRows`, `set` pouze k `update`. Klíčové sloupce nesmějí být v `columns` ani `set`.

`backupTable`, `restoreRows`, `replaceTable` a `insert` nelze kombinovat s jiným krokem pro stejnou tabulku. Více UPDATE/DELETE na stejné tabulce je možné, ale všechny UPDATE musí používat stejný seznam klíčů. Překrývající se UPDATE a DELETE zasahující řádky potřebné pro validaci UPDATE preflight odmítne.

`backupTable`, `restoreRows` a `insert` vybírají řádky při Capture. `update` a `delete` pracují s databází po refreshi. `delete` s `allRows` provádí při každém spuštění `DELETE FROM tabulka`, takže smaže i nově přidané řádky. DELETE s `match` při každém spuštění maže zadané klíče; jejich nepřítomnost není chyba.

`insert` zachytí všechny podporované uložené sloupce vybraných řádků. Pro navázané INSERT kroky uveďte rodiče před dětmi. Identity a neviditelné sloupce se u `insert` a `replaceTable` odmítají; virtuální sloupce se nevkládají.

### Přechod ze staré konfigurace

Odstraňte všechna početní omezení. Nahraďte `keyValues` polem pojmenovaných objektů `match`, například `"match": [{"ID": 101}]`. Původní objekt `match` zabalte do pole a zajistěte, že obsahuje přesně sloupce explicitního klíče. Obecný filtr nad neunikátními sloupci nelze automaticky převést: vyberte konkrétní klíče. Pro celé tabulky přidejte `"allRows": true`.

Nový formát vyžaduje nový Capture před refreshem. Staré snapshoty se neobnovují novou verzí.

## Provozní postup

### Database Refresh Utility

Při **Restore** se chybějící řádky typu `restoreRows` zapisují samostatně do složky `recovery/<čas-běhu>-<id>/` vedle `snapshot.json`. Každé schéma má soubor `<schema>.skipped-updates.json` s tabulkou, klíčem a původními obnovovanými hodnotami. Záznamy odpovídají UPDATE, které při daném běhu skutečně nezasáhly žádný řádek; nejde jen o výsledek Preflight.

Pokud existují přeskočené řádky, aplikace je dohledá v plné CSV záloze, ověří její SHA-256 a vytvoří `<schema>.missing-rows.insert.sql`. Soubor obsahuje celé původní řádky včetně sloupců mimo `columns` a vloží je pouze tehdy, pokud jejich klíč stále chybí. Skript se automaticky nespouští ani neprovádí COMMIT. Před ručním spuštěním v SQL*Plus pod odpovídajícím schématem zkontrolujte hodnoty a pořadí tabulek podle cizích klíčů; výsledek potvrďte příkazem COMMIT nebo zrušte příkazem ROLLBACK. Kontrola přihlášeného účtu je součástí skriptu. Identity sloupce vyžadují ruční přípravu INSERT; při chybě generování zůstává samostatný log zachovaný a aplikace oznámí, že obnova schématu již byla potvrzena.

Tento výstup platí pro `restoreRows` s `match` i `allRows`. Operace `update` vybírá řádky až po refreshi, takže nemá seznam původních chybějících řádků pro dodatečné vložení.

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

Preflight pouze čte databázi a nevytváří plán obnovy na disku. Kontroluje připojení, účet, strukturu sloupců včetně délek, přesnosti, škály, NULL a identity atributů, existenci a jednoznačnost obnovovaných klíčů, pevně zadávané hodnoty, triggery a závislosti náhrad celých tabulek. Není zkušebním provedením DML: například CHECK constraints se mohou projevit až během transakce, která pak provede rollback.

## Transakce, pořadí a selhání

Všechna schémata projdou preflightem před prvním zápisem. Pak běží postupně podle `schemaOrder`, každé v **jediné vlastní transakci**:

1. Zamknou se konfigurované tabulky daného schématu pomocí `LOCK TABLE ... IN EXCLUSIVE MODE NOWAIT`. Obsazený zámek způsobí chybu.
2. Tabulky `replaceTable` se vymažou v opačném pořadí kroků, tedy děti před rodiči.
3. Kroky se provedou v uvedeném pořadí, včetně INSERT rodičů před dětmi.
4. V téže transakci se zkontrolují výsledné hodnoty a počty. Teprve potom proběhne jeden COMMIT.

**TRUNCATE se nepoužívá.** Chyba DML nebo vnitřní validace vrátí změny aktuálního schématu. Dříve dokončená schémata zůstanou potvrzená a pozdější se nespustí. Nejde o jednu transakci přes všechna schémata. Při ztrátě spojení právě během COMMIT může být výsledek nejistý; ověřte jej validací nebo obnovu zopakujte se stejným plánem.

Pro příchozí aktivní FK k nahrazované tabulce musí být i dětská tabulka mezi `replaceTable` ve stejném schématu a za rodičem. Viditelné vazby z jiných schémat, cykly, samoodkazy a nenahrazované závislé tabulky preflight odmítá. Neviditelné externí vazby automaticky ověřit nemůže. Tyto případy vyžadují samostatný postup DBA; nástroj automaticky nevypíná constraints. Identity a neviditelné sloupce v `replaceTable` se odmítají. Virtuální sloupce se nevkládají a UPDATE nesmí měnit virtuální ani identity sloupce.


## Opakování a plán UPDATE

Před prvním zápisem restore atomicky uloží `restore-plan.json` vedle snapshotu. Obsahuje klíče řádků vybraných **po refreshi**, vazbu na snapshot a cíl a kontrolní součet. Při opakování se používají tyto původní klíče, také při celotabulkovém výběru `allRows`. Správně funguje i přiřazení stejné hodnoty, například `STATUS = 'TEST'` tam, kde už TEST je. Sloupce z `match` jsou nyní klíče a UPDATE je nesmí měnit.

Po odstranění příčiny chyby spusťte stejný Restore znovu. Dokončená schémata se znovu aplikují; stav se neodhaduje jen podle uloženého příznaku úspěchu. Plán ani snapshot nemažte nebo ručně neupravujte. Pokud chybí plán, samostatná validace UPDATE skončí chybou. Nový DBA refresh vyžaduje nový capture a nový adresář snapshotu. Pro jeden snapshot nespouštějte více obnov souběžně.

Plán je po prvním uložení neměnný. Restore drží výhradní souborový zámek `restore-plan.json.lock`, takže druhý proces nad stejným snapshotem skončí před prací. Prázdný lock soubor může zůstat na disku; rozhodující je aktivní zámek operačního systému, který se při ukončení procesu uvolní.

Pokud wrapper oznámí chybu až při samostatné validaci po restore, transakce obnovy již byly potvrzené a tato následná kontrola je nevrátí.

## Zálohy a datové typy

Capture pro každou konfigurovanou tabulku uloží všechny podporované viditelné nevirtuální sloupce do CSV a ručního INSERT SQL. Kroky `insert` a `backupTable` exportují pouze vybrané řádky (`match`), nebo celou tabulku (`allRows`). Ostatní kroky vytvářejí úplnou zálohu tabulky; `restoreRows` navíc ukládá vybrané hodnoty pro automatickou obnovu. CSV obsahuje příznaky `__IS_NULL`. INSERT soubory se automaticky nespouštějí a neobsahují COMMIT. Jsou určeny pro předem vyprázdněný cíl nebo odstraněné řádky; jejich ruční použití vyžaduje kontrolu identity, FK, triggerů a struktury cíle. Automatická obnova kroku `insert` používá data ze snapshotu a vlastní transakční SQL.

Před `CAPTURE SUCCESS` se snapshot i exporty znovu načtou a porovnají se zachycenými hodnotami a kontrolními součty. Kontrola textu INSERT není důkazem jeho proveditelnosti v libovolném schématu. SHA-256 chrání před náhodnou změnou, nikoli před úmyslným přepsáním dat i součtu. Jednotlivé capture dotazy netvoří společný konzistentní SCN; proto jsou zastavené zápisy nutné.

Podporované typy: CHAR, VARCHAR2, NCHAR, NVARCHAR2, NUMBER, DATE, TIMESTAMP a TIMESTAMP WITH TIME ZONE. NUMBER se ukládá jako text, aby se neztratila přesnost. DATE očekává `YYYY-MM-DD HH24:MI:SS`, TIMESTAMP přidává devět desetinných míst a časová zóna offset `+HH:MM`. U časové zóny se zachovává offset, nikoli název regionu. Nepodporované typy, například CLOB/BLOB/RAW a TIMESTAMP WITH LOCAL TIME ZONE, nebo příliš velký JSON řádek způsobí chybu capture. SQL*Plus komunikuje v UTF-8; víceřádkové řetězce se převádějí na bezpečné výrazy s CHR/NCHR.

PowerShell vytváří **snapshoty verze 4** pro nový formát konfigurace. Snapshoty verzí 1/2/3 a jejich restore plány se odmítají. Při přechodu upravte konfiguraci a proveďte nový Capture **před** refreshem. Pokud refresh už proběhl a máte jen starý snapshot, dokončete obnovu původní verzí nástroje; snapshot ručně nepřevádějte.

Soubory `.ps1` jsou uložené jako UTF-8 s BOM kvůli Windows PowerShellu 5.1. JSON a SQL exporty používají UTF-8 bez BOM, CSV UTF-8 s BOM. Přenos do SQL*Plus používá explicitní UTF-8 bajty přes .NET proces, současně se čtou stdout i stderr a hlídá se `timeoutSeconds`. Není závislý na kódové stránce konzole. Velká přesná čísla v konfiguraci zapište jako JSON řetězce; NUMBER načtený z Oracle se vždy uchovává jako text.

Credentials, lokální konfigurace, snapshoty a plány obsahují citlivé údaje a jsou ignorovány Gitem. Hesla jdou SQL*Plus přes stdin, nikoli argumenty procesu; nevypisují se ani hodnoty řádků z chybového SQL.

## Testy

```powershell
powershell.exe -NoProfile -File .\tests\Test-OracleRefresh.ps1
powershell.exe -NoProfile -STA -File .\tests\Test-OracleRefreshUI.ps1
powershell.exe -NoProfile -File .\tests\Test-OracleIntegration.ps1
```

Lokální regresní testy běží přímo v PowerShellu 5.1 bez Oracle i bez Pesteru. Ověřují také skutečný přenos UTF-8 do pomocného procesu a timeout. Skutečné integrační testy jsou explicitně volitelné a bez konfigurace se zobrazí jako přeskočené; podrobnosti a oprávnění jsou v [tests/README.md](tests/README.md).
