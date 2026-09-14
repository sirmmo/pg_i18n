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
e una migrazione che trasforma il tutto in vero `jsonb`.

Nessuna estensione, nessun superuser, nessuna dipendenza. Testato su
PostgreSQL 16, richiede la 9.5 o successiva.

## Installazione

```sh
psql -d mydb -f i18n.sql
```

Tutto viene creato nello schema corrente. Rieseguire il file è sicuro
(`CREATE OR REPLACE` ovunque).

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

## Eseguire i test

```sh
./test.sh            # avvia un container postgres:16-alpine usa e getta ed esegue test.sql
```

Oppure su qualsiasi database vuoto: `psql -d db_vuoto -f test.sql`. Lo script
si ferma alla prima istruzione che fallisce.

## Licenza

MIT
