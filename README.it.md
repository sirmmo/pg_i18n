# pg_i18n

*[English](README.md) · Italiano*

Colonne di testo traducibili per PostgreSQL, in puro SQL e PL/pgSQL.

Una colonna contiene una stringa semplice oppure un oggetto JSON di traduzioni:

```
name
-----------------------------------
Chair
{"en": "Chair", "it": "Sedia"}
```

pg_i18n fornisce funzioni per leggere e scrivere una singola lingua da una
colonna di questo tipo, uno strato di viste aggiornabili che permette a
un'applicazione che conosce solo stringhe semplici di continuare a funzionare,
una migrazione che trasforma il tutto in vero `jsonb`, e un'automazione
opzionale che riempie le lingue mancanti tramite DeepL, Google Translate o
un qualsiasi modello su OpenRouter.

Puro SQL e PL/pgSQL, nessun codice compilato, nessun superuser necessario.
Installabile come estensione o come semplice script. Testato su PostgreSQL 14,
16 e 17; richiede la 9.5 o successiva.

**Indice:** [Installazione](#installazione) · [Per iniziare](#per-iniziare) · [Riferimento delle funzioni](#riferimento-delle-funzioni) · [App basate su stringhe](#lasciare-intatta-unapplicazione-basata-su-stringhe) · [Migrare a jsonb](#migrare-a-jsonb) · [Automazione](#automazione-riempire-le-lingue-mancanti) · [Ricerca](#ricerca-con-like) · [Dettagli di comportamento](#dettagli-di-comportamento) · [Test](#eseguire-i-test)

## Struttura del repository

| File | Scopo |
|---|---|
| `i18n.sql` | nucleo: funzioni di lettura/scrittura, strato di viste, migrazione |
| `i18n_auto.sql` | automazione: configurazione, coda, trigger, funzioni lato worker |
| `pg_i18n.control`, `Makefile` | pacchettizzazione come estensione; `make install` genera `pg_i18n--1.0.sql` dai due file sopra |
| `worker/pg_i18n_worker.py` | worker di traduzione (DeepL, OpenRouter, echo) con `Dockerfile` e `requirements.txt` |
| `test.sql`, `test.sh`, `worker/test_worker.sh` | suite di test e script per eseguirla |

## Installazione

### Come estensione

```sh
make install                # usa pg_config dal PATH, oppure PG_CONFIG=/percorso/pg_config make install
psql -d mydb -c 'CREATE EXTENSION pg_i18n'
```

`make install` copia solo due file (`pg_i18n.control` e il generato
`pg_i18n--1.0.sql`, cioè `i18n.sql` più `i18n_auto.sql`) in
`$(pg_config --sharedir)/extension/`, quindi su un host senza `make` potete
copiarli a mano. `CREATE EXTENSION` non richiede
superuser, solo il privilegio `CREATE` sul database.

Per mettere le funzioni in uno schema dedicato:

```sql
CREATE EXTENSION pg_i18n SCHEMA i18n;
```

L'estensione non è rilocabile: le funzioni fissano lo schema in cui sono
state installate (vedi [search_path](#search_path)), quindi per spostarla
eliminatela e ricreatela invece di usare `ALTER EXTENSION ... SET SCHEMA`.

### Come semplice script

```sh
psql -d mydb -f i18n.sql -f i18n_auto.sql     # i18n_auto.sql è opzionale, vedi Automazione
```

Tutto viene creato nel primo schema del `search_path` corrente. Rieseguire
il file è sicuro (`CREATE OR REPLACE` ovunque).

### search_path

Le funzioni che chiamano altre funzioni di pg_i18n sono dichiarate
`SET search_path FROM CURRENT`, così continuano a funzionare quando
PostgreSQL 17+ costruisce indici e verifica vincoli con un `search_path`
ristretto, e quando l'estensione vive in uno schema che i chiamanti non
hanno nel proprio path. Lo schema è quindi fissato al momento
dell'installazione: installate con lo schema desiderato per primo nel
`search_path`, oppure usate `CREATE EXTENSION ... SCHEMA`.

## Per iniziare

```sql
SET i18n.default_lang = 'en';       -- lingua di ripiego (predefinita: en)
SET i18n.lang = 'it';               -- lingua per questa sessione

SELECT i18n_get(name) FROM products;
-- 'Chair'  -> Chair          (stringa semplice, restituita così com'è)
-- {"en":"Chair","it":"Sedia"} -> Sedia

UPDATE products SET name = i18n_set(name, 'Sedia rossa') WHERE id = 1;
-- 'Chair'  -> {"en": "Chair", "it": "Sedia rossa"}   (stringa semplice promossa a default_lang)
```

## Riferimento delle funzioni

Ogni funzione esiste in versione `text` e in versione `jsonb`. PostgreSQL
sceglie quella che corrisponde al tipo della colonna, quindi le stesse query
funzionano prima e dopo la [migrazione](#migrare-a-jsonb).

### Lettura

| Funzione | Volatilità | Descrizione |
|---|---|---|
| `i18n_get(v, lang, fallback)` | IMMUTABLE | Traduzione per `lang`, altrimenti `fallback`, altrimenti la prima lingua disponibile (ordinata per chiave). Una stringa semplice viene restituita invariata. |
| `i18n_get(v, lang)` | STABLE | Il ripiego è `i18n.default_lang`. |
| `i18n_get(v)` | STABLE | La lingua è `i18n.lang`. |
| `i18n_langs(v)` | IMMUTABLE | `text[]` delle lingue presenti. `{}` per una stringa semplice. |
| `i18n_is_json(v)` | IMMUTABLE | Vero solo per un oggetto JSON i cui valori sono tutti stringhe: una colonna di testo che per caso contiene altro JSON viene comunque trattata come stringa semplice. |
| `i18n_values(v)` | IMMUTABLE | `text[]` di tutte le traduzioni. Una stringa semplice dà un array di un elemento. |
| `i18n_all(v)` | IMMUTABLE | Tutte le traduzioni unite da un a capo. Per ricerche `LIKE` su tutte le lingue. |

Negli indici su espressione usate la forma a tre argomenti; le forme più corte
dipendono dallo stato di sessione e non sono indicizzabili.

### Scrittura

`i18n_set` restituisce il nuovo valore da salvare nella colonna. Non modifica
mai nulla direttamente.

| Funzione | Volatilità | Descrizione |
|---|---|---|
| `i18n_set(v, lang, val, promote_as)` | IMMUTABLE | Imposta `lang` a `val`. Una `v` stringa semplice viene prima promossa a `{promote_as: v}`. `NULL` o `''` partono da `{}`. Un `val` `NULL` rimuove la lingua; se non resta nulla il risultato è `NULL`. |
| `i18n_set(v, lang, val)` | STABLE | `promote_as` è `i18n.default_lang`. |
| `i18n_set(v, val)` | STABLE | `lang` è `i18n.lang`. |

```sql
SELECT i18n_set('Chair', 'it', 'Sedia', 'en');           -- {"en": "Chair", "it": "Sedia"}
SELECT i18n_set('{"en":"Chair"}', 'en', 'Armchair', 'en'); -- {"en": "Armchair"}
SELECT i18n_set('{"en":"Chair","it":"Sedia"}', 'it', NULL, 'en'); -- {"en": "Chair"}
```

### Funzioni di sessione

| Funzione | Volatilità | Descrizione |
|---|---|---|
| `i18n_lang()` | STABLE | Lingua corrente: `i18n.lang`, altrimenti `i18n.default_lang`. |
| `i18n_default_lang()` | STABLE | `i18n.default_lang`, altrimenti `en`. |

### Schema e migrazione

| Funzione | Descrizione |
|---|---|
| `i18n_wrap_table(tabella, colonne, vista)` | Crea `vista` che espone `colonne` come stringhe semplici nella lingua di sessione, con trigger `INSTEAD OF` che riscrivono. Vedi [sotto](#lasciare-intatta-unapplicazione-basata-su-stringhe). |
| `i18n_migration_report(tabella, col)` | Conta le righe null, semplici, tradotte e con altro JSON in una colonna. |
| `i18n_migrate_column(tabella, col [, lang])` | Promuove le stringhe semplici a `{lang: v}`, converte la colonna in `jsonb`, aggiunge un vincolo CHECK. |
| `i18n_migrate_table(tabella, colonne [, lang])` | Lo stesso per più colonne. |

### Automazione

| Funzione | Descrizione |
|---|---|
| `i18n_missing(v, langs [, default_lang])` | `text[]` delle lingue di `langs` assenti o vuote in `v`. IMMUTABLE con il terzo argomento. |
| `i18n_exact(v, lang, default_lang)` | Traduzione esattamente per `lang`, senza ripiego. Una stringa semplice conta come `default_lang`. IMMUTABLE. |
| `i18n_fill(v, traduzioni)` | Restituisce `v` con le lingue dell'oggetto `{"lang": "testo"}` aggiunte, solo dove ancora mancanti. STABLE. |
| `i18n_auto_enable(tabella, col, langs [, source_lang, provider, hint])` | Configura `col` perché resti compilata per `langs` e collega il trigger. |
| `i18n_auto_disable(tabella, col)` | Rimuove il trigger e disabilita la configurazione. |
| `i18n_backfill(tabella, col)` | Mette in coda ogni riga esistente a cui manca una lingua configurata. Restituisce il conteggio. |
| `i18n_queue_claim(n, worker)` | Lato worker: prende fino a `n` job in attesa (`SKIP LOCKED`) e li restituisce. |
| `i18n_queue_complete(id, traduzioni)` | Lato worker: applica le traduzioni tramite `i18n_fill` e marca il job come completato. |
| `i18n_queue_fail(id, errore [, max_attempts])` | Lato worker: torna in attesa, oppure `error` dopo `max_attempts`. |
| `i18n_queue_requeue_stale([intervallo])` | Riporta in attesa i job bloccati in `processing` da più di `intervallo`. |
| `i18n_present(v, default_lang)` | `text[]` delle lingue con testo non vuoto. Una stringa semplice conta come `default_lang`. IMMUTABLE. |
| `i18n_missing_rows(tabella, col, langs)` | Righe di `col` a cui manca almeno una di `langs`, come `(pk, present, missing)`. Qualsiasi tabella con chiave primaria. |
| `i18n_coverage_of(tabella, col, langs)` | Per lingua: righe totali, righe a cui manca, percentuale completata. |
| vista `i18n_missing_translations` | Ogni riga e colonna configurata in `i18n_auto` a cui manca ancora una lingua, con un flag `queued`. |
| vista `i18n_coverage` | Per colonna configurata e lingua: `total`, `missing`, `done_pct`. |

Tabelle: `i18n_auto` (configurazione, una riga per tabella e colonna) e
`i18n_queue` (job). Entrambe vengono incluse da `pg_dump` quando installate
come estensione.

### Impostazioni di sessione

| Impostazione | Predefinito | Usata da |
|---|---|---|
| `i18n.lang` | il valore di `i18n.default_lang` | `i18n_get` a un argomento, `i18n_set` a due argomenti, viste generate |
| `i18n.default_lang` | `en` | ripiego in lettura, lingua di promozione in scrittura |

Sono normali GUC personalizzati. Si impostano per connessione (`SET`), per
transazione (`SET LOCAL`, la scelta giusta dietro un pooler in modalità
transazione come PgBouncer) oppure in modo permanente per ruolo o database:

```sql
ALTER ROLE api_user SET i18n.lang = 'it';
ALTER DATABASE mydb SET i18n.default_lang = 'en';
```

## Lasciare intatta un'applicazione basata su stringhe

Se l'applicazione legge e scrive già queste colonne come stringhe semplici e
non potete o non volete modificarla, nascondete il JSON dietro una vista:

```sql
ALTER TABLE products RENAME TO products_i18n;
SELECT i18n_wrap_table('products_i18n', '{name,description}', 'products');
```

`i18n_wrap_table(tabella, colonne, vista)` crea `vista` con le stesse colonne
di `tabella`, dove ogni colonna elencata in `colonne` è esposta come
`i18n_get(col)`, più un trigger `INSTEAD OF INSERT / UPDATE / DELETE` che
riscrive attraverso `i18n_set`. La tabella deve avere una chiave primaria.

L'applicazione continua quindi a usare `products` e deve solo avere
`i18n.lang` impostata (vedi sopra). Quello che vede:

- **SELECT** restituisce la traduzione per `i18n.lang`, con ripiego.
- **INSERT** salva `{"<lang>": valore}`. Le colonne omesse dall'insert
  mantengono i loro default (serial, `now()`, ...).
- **UPDATE** cambia solo la lingua corrente dentro il JSON, lasciando intatte
  le altre. Una stringa semplice preesistente viene promossa a
  `i18n.default_lang` alla prima scrittura. Le colonne il cui valore visibile
  non è cambiato non vengono toccate.
- **DELETE** elimina la riga.
- `RETURNING` funziona e restituisce la riga tradotta.

Per rimuovere lo strato: `DROP VIEW products;` e rinominare la tabella
all'indietro.

## Migrare a jsonb

Quando tutti gli scrittori passano dalle funzioni o dalla vista, potete
trasformare le colonne di testo in vero `jsonb` con un vincolo, ottenendo
gratis query di contenimento e indici GIN.

```sql
BEGIN;
SELECT * FROM i18n_migration_report('products_i18n', 'name');
--  col_type | total | nulls | plain | translated | other_json
--  text     | 12040 |    15 |  9871 |       2154 |          0

DROP VIEW IF EXISTS products;               -- ALTER COLUMN TYPE rifiuta una vista dipendente
SELECT i18n_migrate_table('products_i18n', '{name,description}', 'en');
SELECT i18n_wrap_table('products_i18n', '{name,description}', 'products');
COMMIT;
```

`i18n_migrate_column(tabella, col [, lang])` (e `i18n_migrate_table` per una
lista di colonne) esegue, su una colonna `text`, `varchar` o `char`:

1. `UPDATE` di ogni valore non NULL che non è già un oggetto di traduzioni in
   `{"<lang>": valore}`. `lang` è per default `i18n.default_lang`. Le stringhe
   vuote diventano `{"<lang>": ""}` così la semantica `NOT NULL` è preservata.
2. `ALTER COLUMN ... TYPE jsonb`. Un eventuale default della colonna viene
   prima rimosso, perché un default testuale non è più valido; se serve
   ricreatelo come `'{"en": "..."}'::jsonb`.
3. Aggiunta di un vincolo `CHECK (col IS NULL OR i18n_is_json(col))` chiamato
   `<col>_i18n_check`.

Su una colonna già `jsonb` vengono eseguiti solo i passi 1 e 3 (le stringhe
JSON nude vengono promosse a oggetti).

La riscrittura tiene un lock `ACCESS EXCLUSIVE` sulla tabella per tutta la
durata. `other_json` nel report conta i valori che iniziano con `{` ma non sono
un oggetto di traduzioni, per esempio `{"foo": 1}`; vengono promossi come
stringhe semplici, che probabilmente non è quello che volete, quindi
controllateli prima.

## Automazione: riempire le lingue mancanti

`i18n_auto.sql` (incluso nell'estensione) mantiene compilate le lingue scelte
tramite un servizio di traduzione esterno. PostgreSQL non può chiamare API
HTTP in modo portabile, quindi il lavoro è diviso:

- **database**: una tabella di configurazione, trigger che rilevano le righe
  a cui manca una lingua configurata e le mettono in coda, e funzioni che
  scrivono le traduzioni senza mai sovrascriverne una esistente;
- **worker** (`worker/pg_i18n_worker.py`): prende i job dalla coda, chiama il
  provider, scrive il risultato. Provider: `deepl`, `google`, `openrouter`
  ed `echo` (offline, restituisce `[lang] testo`, per i test).

### Lato database

```sql
-- mantieni en, it e de compilate per products.name; hint viene passato ai provider LLM
SELECT i18n_auto_enable('products_i18n', 'name', '{en,it,de}',
                        NULL,                     -- lingua sorgente (NULL: lingua predefinita, altrimenti la prima disponibile)
                        'openrouter',             -- provider (NULL: predefinito del worker)
                        'nomi di prodotti di arredamento, non tradurre i marchi');

SELECT i18n_backfill('products_i18n', 'name');    -- mette in coda ogni riga esistente a cui manca una lingua
SELECT i18n_auto_disable('products_i18n', 'name');
```

`i18n_auto_enable` registra la configurazione in `i18n_auto` e aggiunge un
trigger `AFTER INSERT OR UPDATE OF col`. Ogni scrittura che lascia una lingua
configurata mancante o vuota crea un job in `i18n_queue` (un solo job aperto
per riga e colonna; scritture ripetute lo aggiornano) e invia un
`NOTIFY i18n_queue`. Anche le scritture attraverso una vista generata contano.

Il testo sorgente è la lingua sorgente configurata se ha un testo, altrimenti
la prima lingua non vuota. Vengono richieste solo le lingue mancanti e
vengono scritte solo le lingue mancanti: una traduzione umana inserita
mentre un job è in corso ha la precedenza. Cambiare il testo sorgente non
ritraduce le lingue già esistenti.

I job passano da `pending` a `processing` e poi `done` oppure `error` (dopo
`max_attempts`). Per controllarli:

```sql
SELECT status, count(*) FROM i18n_queue GROUP BY 1;
SELECT id, tbl, col, pk, target_langs, attempts, error FROM i18n_queue WHERE status = 'error';
UPDATE i18n_queue SET status = 'pending', attempts = 0 WHERE status = 'error';   -- riprova
```

Funzioni di supporto usabili da sole: `i18n_missing(v, langs)` restituisce
quali tra `langs` sono assenti o vuote, `i18n_fill(v, '{"it": "..."}')`
aggiunge solo le lingue ancora mancanti, `i18n_exact(v, lang, default)` legge
una lingua senza ripiego.

### Controllare cosa manca

Due viste rispondono a "cosa non è ancora tradotto" per ogni colonna
configurata con `i18n_auto_enable`, abilitata o no:

```sql
SELECT * FROM i18n_coverage;
--      tbl       | col  | enabled | lang | total | missing | done_pct
--  products_i18n | name | t       | de   |     5 |       5 |      0.0
--  products_i18n | name | t       | en   |     5 |       2 |     60.0
--  products_i18n | name | t       | it   |     5 |       0 |    100.0

SELECT * FROM i18n_missing_translations WHERE NOT queued;
--      tbl       | col  | enabled |    pk     | present | missing | queued
--  products_i18n | name | t       | {"id": 6} | {it}    | {de,en} | f
```

`queued` indica se per quella riga esiste già un job di traduzione aperto.
Le righe senza alcun testo mostrano tutte le lingue come mancanti;
l'automazione le salta perché non c'è nulla da cui tradurre.

Per una colonna non configurata, o per limitare la scansione a una sola
tabella, chiamate direttamente le funzioni sottostanti:

```sql
SELECT * FROM i18n_missing_rows('products_i18n', 'description', '{en,it,de}');
SELECT * FROM i18n_coverage_of('products_i18n', 'description', '{en,it,de}');
```

Entrambe le viste eseguono una scansione per ogni colonna configurata a ogni
query; un filtro `WHERE tbl =` sulla vista non riduce la scansione, la forma
a funzione sì.

### Worker

```sh
cd worker && pip install -r requirements.txt
export PG_I18N_DSN=postgresql://user:pw@host/db
export PG_I18N_PROVIDER=deepl DEEPL_API_KEY=...            # oppure
export PG_I18N_PROVIDER=google GOOGLE_TRANSLATE_API_KEY=...  # oppure
export PG_I18N_PROVIDER=openrouter OPENROUTER_API_KEY=... OPENROUTER_MODEL=anthropic/claude-sonnet-4.5
./pg_i18n_worker.py            # gira per sempre: LISTEN/NOTIFY più un poll ogni PG_I18N_POLL secondi
./pg_i18n_worker.py --once     # svuota la coda ed esce, per cron
```

Oppure come container: `docker build -t pg_i18n-worker worker/` e avviatelo
con le stesse variabili d'ambiente. Tutte le impostazioni:

| Variabile | Predefinito | Significato |
|---|---|---|
| `PG_I18N_DSN` (o `DATABASE_URL`) | | stringa di connessione libpq |
| `PG_I18N_SCHEMA` | | schema in cui è installato pg_i18n, se non è nel search_path |
| `PG_I18N_PROVIDER` | `echo` | provider per i job la cui configurazione non ne indica uno |
| `PG_I18N_BATCH` | `10` | job presi per ciclo |
| `PG_I18N_POLL` | `30` | secondi tra un poll e l'altro quando la coda è vuota |
| `PG_I18N_MAX_ATTEMPTS` | `3` | fallimenti prima che un job sia marcato `error` |
| `PG_I18N_STALE_MINUTES` | `10` | i job rimasti `processing` per questo tempo vengono rimessi in coda |
| `DEEPL_API_KEY` | | le chiavi che finiscono in `:fx` usano l'endpoint gratuito |
| `DEEPL_TARGET_MAP` | `en=EN-US,pt=PT-PT,zh=ZH-HANS` | varianti regionali DeepL, es. `en=EN-GB,pt=PT-BR` |
| `DEEPL_FORMALITY` | | `more`, `less`, `prefer_more`, `prefer_less` |
| `GOOGLE_TRANSLATE_API_KEY` | | chiave API con la Cloud Translation API abilitata (edizione Basic, v2) |
| `GOOGLE_TRANSLATE_FORMAT` | `text` | `text` oppure `html`; usate `html` per colonne che contengono markup |
| `OPENROUTER_API_KEY` | | |
| `OPENROUTER_MODEL` | `openai/gpt-4o-mini` | qualsiasi id di modello OpenRouter |

DeepL e Google ricevono una richiesta per ogni lingua di destinazione; DeepL
riceve lo `hint` come `context`, Google lo ignora. I codici lingua di Google
sono BCP-47 (`en`, `pt-BR`, `zh-CN`), quindi se lo usate nominate le lingue
in quel modo. OpenRouter riceve una richiesta per job con tutte le lingue
richieste come oggetto JSON; lo `hint` della configurazione viene aggiunto
al prompt. Più worker possono girare
in parallelo: i claim usano `FOR UPDATE SKIP LOCKED`.

Il worker ha bisogno solo di poter chiamare le funzioni `i18n_queue_*` e di
aggiornare le tabelle di destinazione. Per usare un altro servizio aggiungete
a `PROVIDERS` una classe con un metodo `translate(text, source_lang,
target_langs, hint)` che restituisce `{lang: testo}`.

## Ricerca con LIKE

Tutto questo funziona sulle colonne `text` originali, prima di qualsiasi
migrazione, sia sulle righe semplici che su quelle JSON, e continua a
funzionare su `jsonb` dopo.

```sql
-- una lingua (con ripiego)
SELECT * FROM products_i18n WHERE i18n_get(name, 'it', 'en') ILIKE '%sedia%';

-- qualsiasi lingua
SELECT * FROM products_i18n WHERE i18n_all(name) ILIKE '%chair%';

-- attraverso la vista: la lingua di sessione, non indicizzabile
SET i18n.lang = 'it';
SELECT * FROM products WHERE name ILIKE '%sedia%';
```

Non fate `LIKE` sulla colonna grezza: sulle righe JSON corrisponderebbe anche
alle chiavi di lingua, alle virgolette e alle sequenze `\uXXXX`, e una ricerca
di `Sedia` troverebbe una riga la cui traduzione tedesca la contiene, mancando
una italiana scritta con una sequenza di escape.

### Indici

`i18n_get(v, lang, fallback)` e `i18n_all(v)` sono IMMUTABLE, quindi entrambe
si possono indicizzare. Per pattern `%termine%` usate pg_trgm:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- una lingua
CREATE INDEX ON products_i18n USING gin (i18n_get(name, 'it', 'en') gin_trgm_ops);
-- qualsiasi lingua
CREATE INDEX ON products_i18n USING gin (i18n_all(name) gin_trgm_ops);
```

Entrambi servono `LIKE`, `ILIKE`, `~` e l'operatore di similarità `%`. Per
uguaglianza o `LIKE 'sed%'` ancorato a sinistra basta un B-tree sulla stessa
espressione (usate `text_pattern_ops` se la collation del database non è `C`).

Questi indici su espressione sopravvivono alla migrazione a jsonb:
`ALTER COLUMN TYPE` li ricostruisce sugli overload jsonb.

```sql
-- solo jsonb: contenimento ed esistenza di chiave
CREATE INDEX ON products_i18n USING gin (name);
SELECT * FROM products_i18n WHERE name @> '{"it": "Sedia"}';
SELECT * FROM products_i18n WHERE NOT name ? 'de';          -- righe senza tedesco
```

I filtri scritti sulla vista usano la lingua di sessione e non possono usare
questi indici. Quando conta la velocità interrogate la tabella base con la
forma esplicita.

## Dettagli di comportamento

- L'ordine di ripiego in lettura è sempre: lingua richiesta, lingua di
  ripiego, prima lingua disponibile ordinata per chiave. Impostate il ripiego
  esplicitamente se "la prima disponibile" non è accettabile.
- `i18n_is_json` richiede un oggetto i cui valori sono tutti stringhe. Un
  valore salvato come `{"en": "a", "count": 3}` per pg_i18n è una stringa
  semplice e verrà promosso in blocco alla scrittura.
- I codici lingua sono chiavi opache. Nulla vieta di usare `en-GB` ed `en`
  fianco a fianco, ma nulla risolve nemmeno tra i due.
- `i18n_set` con un valore `NULL` che svuota l'oggetto restituisce `NULL`,
  non `{}`.
- L'automazione aggiunge soltanto lingue. Richiede solo ciò che manca o è
  vuoto, `i18n_fill` scrive solo ciò che manca ancora al momento della
  scrittura, e un testo sorgente modificato non ritraduce le lingue già
  esistenti. Svuotate una lingua (`i18n_set(v, 'it', NULL)`) per farla
  rifare.
- I trigger dell'automazione scattano sulla tabella base, quindi le scritture
  attraverso le viste generate e quelle dirette sono trattate allo stesso
  modo. Anche la scrittura del worker fa scattare il trigger, che non trova
  nulla di mancante e si ferma lì.

## Eseguire i test

```sh
make test                          # equivale a ./test.sh; esistono anche make test-ext e make test-worker
./test.sh                          # script semplice, container postgres:16-alpine usa e getta
EXT=1 ./test.sh                    # compila e installa l'estensione con PGXS, poi CREATE EXTENSION
EXT=1 ./test.sh postgres:17-alpine # qualsiasi immagine ufficiale
./worker/test_worker.sh            # provider contro un server HTTP finto, poi end-to-end: postgres + worker, provider echo
```

Oppure su qualsiasi database vuoto: `psql -d db_vuoto -f test.sql`
(aggiungete `-v use_ext=1` per caricare via `CREATE EXTENSION`). Lo script si
ferma alla prima istruzione che fallisce.

## Licenza

MIT
