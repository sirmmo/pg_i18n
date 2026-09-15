# pg_i18n

*English · [Italiano](README.it.md)*

Translatable text columns for PostgreSQL, in plain SQL and PL/pgSQL.

A column holds either a plain string or a JSON object of translations:

```
name
-----------------------------------
Chair
{"en": "Chair", "it": "Sedia"}
```

pg_i18n gives you functions to read and write one language out of such a
column, an updatable view layer so an application that only knows about plain
strings keeps working, a migration that turns the whole thing into proper
`jsonb`, and an optional automation that fills missing languages through
DeepL, Google Translate or any model on OpenRouter.

Pure SQL and PL/pgSQL, no compiled code, no superuser needed. Installable as an
extension or as a plain script. Tested on PostgreSQL 14, 16 and 17; needs 9.5+.

**Contents:** [Install](#install) · [Quick start](#quick-start) · [Function reference](#function-reference) · [String-based apps](#keeping-a-string-based-application-untouched) · [Migrating to jsonb](#migrating-to-jsonb) · [Automation](#automation-filling-missing-languages) · [Searching](#searching-with-like) · [Behaviour details](#behaviour-details) · [Tests](#running-the-tests)

## Repository layout

| File | Purpose |
|---|---|
| `i18n.sql` | core: read/write functions, view layer, migration |
| `i18n_auto.sql` | automation: config, queue, triggers, worker-side functions |
| `pg_i18n.control`, `Makefile` | extension packaging; `make install` builds `pg_i18n--1.0.sql` from the two files above |
| `worker/pg_i18n_worker.py` | translation worker (DeepL, OpenRouter, echo) with `Dockerfile` and `requirements.txt` |
| `test.sql`, `test.sh`, `worker/test_worker.sh` | test suite and runners |

## Install

### As an extension

```sh
make install                # uses pg_config from PATH, or PG_CONFIG=/path/to/pg_config make install
psql -d mydb -c 'CREATE EXTENSION pg_i18n'
```

`make install` only copies two files (`pg_i18n.control` and the generated
`pg_i18n--1.0.sql`, which is `i18n.sql` plus `i18n_auto.sql`) into
`$(pg_config --sharedir)/extension/`, so on a host without `make` you can
copy them by hand. No superuser is required to run
`CREATE EXTENSION`, only `CREATE` privilege on the database.

To put the functions in their own schema:

```sql
CREATE EXTENSION pg_i18n SCHEMA i18n;
```

The extension is not relocatable: the functions pin the schema they were
installed in (see [search_path](#search_path)), so drop and recreate it rather
than `ALTER EXTENSION ... SET SCHEMA`.

### As a plain script

```sh
psql -d mydb -f i18n.sql -f i18n_auto.sql     # i18n_auto.sql is optional, see Automation
```

Everything is created in the first schema of the current `search_path`.
Re-running the file is safe (`CREATE OR REPLACE` throughout).

### search_path

Functions that call other pg_i18n functions are declared
`SET search_path FROM CURRENT`, so they keep working when PostgreSQL 17+
builds indexes and checks constraints under a restricted `search_path`, and
when the extension lives in a schema that callers do not have on their path.
This means the schema is fixed at install time: install with the intended
schema first on the `search_path`, or use `CREATE EXTENSION ... SCHEMA`.

## Quick start

```sql
SET i18n.default_lang = 'en';       -- fallback language (default: en)
SET i18n.lang = 'it';               -- language for this session

SELECT i18n_get(name) FROM products;
-- 'Chair'  -> Chair          (plain string, returned as-is)
-- {"en":"Chair","it":"Sedia"} -> Sedia

UPDATE products SET name = i18n_set(name, 'Sedia rossa') WHERE id = 1;
-- 'Chair'  -> {"en": "Chair", "it": "Sedia rossa"}   (plain string promoted to default_lang)
```

## Function reference

All functions come in a `text` and a `jsonb` flavour. PostgreSQL picks the one
matching the column type, so the same queries work before and after the
[migration](#migrating-to-jsonb).

### Reading

| Function | Volatility | Description |
|---|---|---|
| `i18n_get(v, lang, default_lang, mode)` | IMMUTABLE | Core resolver. `mode` is `any` (`lang`, then `default_lang`, then the first non-empty language by key), `default` (`lang`, then `default_lang`) or `none` (`lang` only). NULL when nothing matches. A plain string is the `default_lang` text. |
| `i18n_get(v, lang, fallback)` | IMMUTABLE | Same as mode `any` with `fallback` as the default language. |
| `i18n_exact(v, lang, default_lang)` | IMMUTABLE | Same as mode `none`: exactly `lang` or NULL. |
| `i18n_get(v, lang)` | STABLE | Mode from `i18n.fallback`, default language from `i18n.default_lang`, missing value from `i18n.missing`. |
| `i18n_get(v)` | STABLE | As above with `lang` = `i18n.lang`. |
| `i18n_langs(v)` | IMMUTABLE | `text[]` of languages present. `{}` for a plain string. |
| `i18n_is_json(v)` | IMMUTABLE | True only for a JSON object whose values are all strings, so a text column that happens to contain some other JSON is still treated as a plain string. |
| `i18n_values(v)` | IMMUTABLE | `text[]` of every translation. A plain string gives a one-element array. |
| `i18n_all(v)` | IMMUTABLE | Every translation joined by newline. For `LIKE` search across languages. |

Use the three- or four-argument forms in expression indexes; the shorter forms
depend on session state and cannot be indexed.

An empty-string translation counts as not set, so `{"en": "Chair", "it": ""}`
falls through to English for Italian and shows up as missing in the
automation views.

#### Missing translations: fallback, NULL or empty string

By default a language that is not set falls back as far as needed, so the
application always gets some text. Two session settings change that for the
session-driven forms and for the wrapped views:

```sql
SET i18n.fallback = 'none';     -- any (default) | default | none
SET i18n.missing  = 'empty';    -- null (default) | empty

SELECT i18n_get('{"en":"Chair","it":"Sedia"}', 'de');
-- fallback any:      Chair
-- fallback default:  Chair
-- fallback none:     NULL, or '' with i18n.missing = 'empty'
SELECT i18n_get('{"fr":"Chaise"}', 'de');
-- fallback any:      Chaise
-- fallback default:  NULL / ''
```

A NULL column value stays NULL whatever the settings. For a fixed choice in
one query, use the immutable forms: `i18n_exact(v, 'de', 'en')` or
`i18n_get(v, 'de', 'en', 'default')`, with `COALESCE(..., '')` if you want
the empty string.

### Writing

`i18n_set` returns the new value to store in the column. It never mutates
anything itself.

| Function | Volatility | Description |
|---|---|---|
| `i18n_set(v, lang, val, promote_as)` | IMMUTABLE | Sets `lang` to `val`. A plain-string `v` is first promoted to `{promote_as: v}`. `NULL` or `''` starts from `{}`. A `NULL` `val` removes the language; when nothing is left the result is `NULL`. |
| `i18n_set(v, lang, val)` | STABLE | `promote_as` is `i18n.default_lang`. |
| `i18n_set(v, val)` | STABLE | `lang` is `i18n.lang`. |

```sql
SELECT i18n_set('Chair', 'it', 'Sedia', 'en');           -- {"en": "Chair", "it": "Sedia"}
SELECT i18n_set('{"en":"Chair"}', 'en', 'Armchair', 'en'); -- {"en": "Armchair"}
SELECT i18n_set('{"en":"Chair","it":"Sedia"}', 'it', NULL, 'en'); -- {"en": "Chair"}
```

### Session helpers

| Function | Volatility | Description |
|---|---|---|
| `i18n_lang()` | STABLE | Current language: `i18n.lang`, else `i18n.default_lang`. |
| `i18n_default_lang()` | STABLE | `i18n.default_lang`, else `en`. |

### Schema and migration

| Function | Description |
|---|---|
| `i18n_wrap_table(table, cols, view)` | Create `view` exposing `cols` as plain strings in the session language, with `INSTEAD OF` triggers writing back. See [below](#keeping-a-string-based-application-untouched). |
| `i18n_migration_report(table, col)` | Count null, plain, translated and other-JSON rows in a column. |
| `i18n_migrate_column(table, col [, lang])` | Promote plain strings to `{lang: v}`, alter the column to `jsonb`, add a CHECK constraint. |
| `i18n_migrate_table(table, cols [, lang])` | Same for several columns. |

### Automation

| Function | Description |
|---|---|
| `i18n_missing(v, langs [, default_lang])` | `text[]` of the languages in `langs` that are absent or empty in `v`. IMMUTABLE with the third argument. |
| `i18n_fill(v, translations)` | Return `v` with the languages from the `{"lang": "text"}` object added, only where still missing. STABLE. |
| `i18n_auto_enable(table, col, langs [, source_lang, provider, hint])` | Configure `col` to be kept filled for `langs` and attach the trigger. |
| `i18n_auto_disable(table, col)` | Drop the trigger and mark the configuration disabled. |
| `i18n_backfill(table, col)` | Queue every existing row that misses a configured language. Returns the count. |
| `i18n_queue_claim(n, worker)` | Worker side: take up to `n` pending jobs (`SKIP LOCKED`), returns them. |
| `i18n_queue_complete(id, translations)` | Worker side: apply translations through `i18n_fill` and mark the job done. |
| `i18n_queue_fail(id, error [, max_attempts])` | Worker side: back to pending, or `error` after `max_attempts`. |
| `i18n_queue_requeue_stale([interval])` | Return jobs stuck in `processing` for longer than `interval` to pending. |
| `i18n_present(v, default_lang)` | `text[]` of the languages that have non-empty text. A plain string counts as `default_lang`. IMMUTABLE. |
| `i18n_missing_rows(table, col, langs)` | Rows of `col` missing any of `langs`, as `(pk, present, missing)`. Any table with a primary key. |
| `i18n_coverage_of(table, col, langs)` | Per language: rows total, rows missing it, percentage done. |
| view `i18n_missing_translations` | Every row and column configured in `i18n_auto` that still misses a language, with a `queued` flag. |
| view `i18n_coverage` | Per configured column and language: `total`, `missing`, `done_pct`. |

Tables: `i18n_auto` (configuration, one row per table and column) and
`i18n_queue` (jobs). Both are dumped by `pg_dump` when installed as an
extension.

### Session settings

| Setting | Default | Used by |
|---|---|---|
| `i18n.lang` | value of `i18n.default_lang` | one-argument `i18n_get`, two-argument `i18n_set`, wrapped views |
| `i18n.default_lang` | `en` | fallback on read, promotion language on write |
| `i18n.fallback` | `any` | how far the session-driven `i18n_get` falls back: `any`, `default` or `none` |
| `i18n.missing` | `null` | what a missing translation reads as: `null` or `empty` |

These are ordinary custom GUCs. Set them per connection (`SET`), per transaction
(`SET LOCAL`, the right choice behind a transaction-mode pooler such as
PgBouncer) or permanently per role or database:

```sql
ALTER ROLE api_user SET i18n.lang = 'it';
ALTER DATABASE mydb SET i18n.default_lang = 'en';
```

## Keeping a string-based application untouched

If the application already reads and writes these columns as plain strings and
you cannot or do not want to change it, hide the JSON behind a view:

```sql
ALTER TABLE products RENAME TO products_i18n;
SELECT i18n_wrap_table('products_i18n', '{name,description}', 'products');
```

`i18n_wrap_table(table, cols, view)` creates `view` with the same columns as
`table`, where every column listed in `cols` is exposed as
`i18n_get(col)`, plus an `INSTEAD OF INSERT / UPDATE / DELETE` trigger that
writes back through `i18n_set`. The table needs a primary key.

The application then keeps using `products` and only has to have `i18n.lang`
set (see above). What it sees:

- **SELECT** returns the translation for `i18n.lang`, following
  `i18n.fallback` and `i18n.missing`.
- **INSERT** stores `{"<lang>": value}`. Columns left out of the insert keep
  their defaults (serials, `now()`, ...).
- **UPDATE** changes only the current language inside the JSON, leaving the
  others intact. A legacy plain string is promoted to `i18n.default_lang` on
  the first write. Columns whose visible value did not change are not touched.
- **DELETE** deletes the row.
- `RETURNING` works and returns the translated row.

To remove the layer: `DROP VIEW products;` and rename the table back.

## Migrating to jsonb

Once every writer goes through the functions or the view, you can turn the
text columns into real `jsonb` with a constraint, and get containment queries
and GIN indexes for free.

```sql
BEGIN;
SELECT * FROM i18n_migration_report('products_i18n', 'name');
--  col_type | total | nulls | plain | translated | other_json
--  text     | 12040 |    15 |  9871 |       2154 |          0

DROP VIEW IF EXISTS products;               -- ALTER COLUMN TYPE refuses a dependent view
SELECT i18n_migrate_table('products_i18n', '{name,description}', 'en');
SELECT i18n_wrap_table('products_i18n', '{name,description}', 'products');
COMMIT;
```

`i18n_migrate_column(table, col [, lang])` (and `i18n_migrate_table` for a
list of columns) does, for a `text`, `varchar` or `char` column:

1. `UPDATE` every non-NULL value that is not already a translation object to
   `{"<lang>": value}`. `lang` defaults to `i18n.default_lang`. Empty strings
   become `{"<lang>": ""}` so `NOT NULL` semantics are preserved.
2. `ALTER COLUMN ... TYPE jsonb`. Any column default is dropped first, since a
   text default is no longer valid; re-add one as `'{"en": "..."}'::jsonb` if
   needed.
3. Add a `CHECK (col IS NULL OR i18n_is_json(col))` constraint named
   `<col>_i18n_check`.

On a column that is already `jsonb` only steps 1 and 3 run (bare JSON strings
get promoted to objects).

The rewrite takes an `ACCESS EXCLUSIVE` lock on the table for its duration.
`other_json` in the report counts values that start with `{` but are not a
translation object, for example `{"foo": 1}`; they are promoted like plain
strings, which is probably not what you want, so inspect them first.

## Automation: filling missing languages

`i18n_auto.sql` (included in the extension) keeps chosen languages filled in
by an external translation service. PostgreSQL cannot call HTTP APIs portably,
so the work is split:

- **database**: a configuration table, triggers that detect rows missing a
  configured language and put them on a queue, and functions that write the
  translations back without ever overwriting an existing one;
- **worker** (`worker/pg_i18n_worker.py`): claims queue jobs, calls the
  provider, writes back. Providers: `deepl`, `google`, `openrouter`, and
  `echo` (offline, returns `[lang] text`, for tests).

### Database side

```sql
-- keep en, it and de filled for products.name; hint is passed to LLM providers
SELECT i18n_auto_enable('products_i18n', 'name', '{en,it,de}',
                        NULL,                     -- source language (NULL: default lang, else first available)
                        'openrouter',             -- provider (NULL: worker default)
                        'furniture product names, keep brand names untranslated');

SELECT i18n_backfill('products_i18n', 'name');    -- queue every existing row that misses a language
SELECT i18n_auto_disable('products_i18n', 'name');
```

`i18n_auto_enable` records the configuration in `i18n_auto` and adds an
`AFTER INSERT OR UPDATE OF col` trigger. Each write that leaves a configured
language missing or empty creates one job in `i18n_queue` (one open job per
row and column; repeated writes update it) and sends a `NOTIFY i18n_queue`.
Writes through a wrapped view count too.

The source text is the configured source language if it has text, otherwise
the first non-empty language. Only missing languages are requested and only
missing languages are written: a human translation entered while a job is in
flight wins. Changing the source text does not retranslate languages that
already exist.

Queue jobs go `pending` → `processing` → `done` or `error` (after
`max_attempts`). Watch it with:

```sql
SELECT status, count(*) FROM i18n_queue GROUP BY 1;
SELECT id, tbl, col, pk, target_langs, attempts, error FROM i18n_queue WHERE status = 'error';
UPDATE i18n_queue SET status = 'pending', attempts = 0 WHERE status = 'error';   -- retry
```

Helper functions usable on their own: `i18n_missing(v, langs)` returns which
of `langs` are absent or empty, `i18n_fill(v, '{"it": "..."}')` adds only
the languages still missing, `i18n_exact(v, lang, default)` reads one language
without fallback.

### Checking what is missing

Two views answer "what is still untranslated" for every column configured
with `i18n_auto_enable`, enabled or not:

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

`queued` tells whether a translation job is already open for that row.
Rows with no text at all show every language as missing; the automation
skips them since there is nothing to translate from.

For a column that is not configured, or to restrict the scan to one table,
call the underlying functions directly:

```sql
SELECT * FROM i18n_missing_rows('products_i18n', 'description', '{en,it,de}');
SELECT * FROM i18n_coverage_of('products_i18n', 'description', '{en,it,de}');
```

Both views run a scan per configured column on every query; a `WHERE tbl =`
filter on the view does not shrink the scan, the function form does.

### Worker

```sh
cd worker && pip install -r requirements.txt
export PG_I18N_DSN=postgresql://user:pw@host/db
export PG_I18N_PROVIDER=deepl DEEPL_API_KEY=...            # or
export PG_I18N_PROVIDER=google GOOGLE_TRANSLATE_API_KEY=...  # or
export PG_I18N_PROVIDER=openrouter OPENROUTER_API_KEY=... OPENROUTER_MODEL=anthropic/claude-sonnet-4.5
./pg_i18n_worker.py            # runs forever: LISTEN/NOTIFY plus a poll every PG_I18N_POLL seconds
./pg_i18n_worker.py --once     # drain the queue and exit, for cron
```

Or as a container: `docker build -t pg_i18n-worker worker/` and run it with
the same environment variables. All settings:

| Variable | Default | Meaning |
|---|---|---|
| `PG_I18N_DSN` (or `DATABASE_URL`) | | libpq connection string |
| `PG_I18N_SCHEMA` | | schema pg_i18n is installed in, if not on the search_path |
| `PG_I18N_PROVIDER` | `echo` | provider for jobs whose config has none |
| `PG_I18N_BATCH` | `10` | jobs claimed per round |
| `PG_I18N_POLL` | `30` | seconds between polls when idle |
| `PG_I18N_MAX_ATTEMPTS` | `3` | failures before a job is marked `error` |
| `PG_I18N_STALE_MINUTES` | `10` | jobs left `processing` this long are requeued |
| `DEEPL_API_KEY` | | keys ending in `:fx` use the free endpoint |
| `DEEPL_TARGET_MAP` | `en=EN-US,pt=PT-PT,zh=ZH-HANS` | DeepL regional targets, e.g. `en=EN-GB,pt=PT-BR` |
| `DEEPL_FORMALITY` | | `more`, `less`, `prefer_more`, `prefer_less` |
| `GOOGLE_TRANSLATE_API_KEY` | | API key with the Cloud Translation API enabled (Basic edition, v2) |
| `GOOGLE_TRANSLATE_FORMAT` | `text` | `text` or `html`; use `html` for columns holding markup |
| `OPENROUTER_API_KEY` | | |
| `OPENROUTER_MODEL` | `openai/gpt-4o-mini` | any OpenRouter model id |

DeepL and Google make one request per target language; DeepL receives the
`hint` as `context`, Google ignores it. Google's language codes are BCP-47
(`en`, `pt-BR`, `zh-CN`), so name your languages that way if you use it.
OpenRouter gets one request per job asking for all target languages as a
JSON object; the `hint` from the configuration is added to the prompt. Several workers can run at once: claims
use `FOR UPDATE SKIP LOCKED`.

The worker only needs the ability to call the `i18n_queue_*` functions and to
update the target tables. To use another service, add a class with a
`translate(text, source_lang, target_langs, hint)` method returning
`{lang: text}` to `PROVIDERS`.

## Searching with LIKE

All of this works on the original `text` columns, before any migration, on
plain and JSON rows alike, and keeps working on `jsonb` afterwards.

```sql
-- one language (with fallback)
SELECT * FROM products_i18n WHERE i18n_get(name, 'it', 'en') ILIKE '%sedia%';

-- any language
SELECT * FROM products_i18n WHERE i18n_all(name) ILIKE '%chair%';

-- through the wrapped view: the session language, not indexable
SET i18n.lang = 'it';
SELECT * FROM products WHERE name ILIKE '%sedia%';
```

Do not `LIKE` the raw column: on JSON rows it also matches language keys,
quotes and `\uXXXX` escapes, and a search for `Sedia` would match a row whose
German translation contains it while missing an Italian one written with an
escape.

### Indexes

`i18n_get(v, lang, fallback)` and `i18n_all(v)` are IMMUTABLE, so both can be
indexed. For `%term%` patterns use pg_trgm:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- one language
CREATE INDEX ON products_i18n USING gin (i18n_get(name, 'it', 'en') gin_trgm_ops);
-- any language
CREATE INDEX ON products_i18n USING gin (i18n_all(name) gin_trgm_ops);
```

Both serve `LIKE`, `ILIKE`, `~` and the `%` similarity operator. For equality
or left-anchored `LIKE 'sed%'` a plain B-tree on the same expression is
enough (use `text_pattern_ops` if the database collation is not `C`).

These expression indexes survive the migration to jsonb: `ALTER COLUMN TYPE`
rebuilds them against the jsonb overloads.

```sql
-- jsonb only: containment and key existence
CREATE INDEX ON products_i18n USING gin (name);
SELECT * FROM products_i18n WHERE name @> '{"it": "Sedia"}';
SELECT * FROM products_i18n WHERE NOT name ? 'de';          -- rows missing German
```

Filters written against the wrapped view use the session language and cannot
use these indexes. Query the base table with the explicit form when speed
matters.

## Behaviour details

- Fallback order on read is: requested language, default language, first
  non-empty language sorted by key. `i18n.fallback` or the `mode` argument
  stop it earlier; a missing translation then reads as NULL, or `''` with
  `i18n.missing = 'empty'`.
- An empty-string translation is treated as not set everywhere: reads fall
  through it, automation counts it as missing and will fill it.
- `i18n_is_json` requires an object whose values are all strings. A stored
  value like `{"en": "a", "count": 3}` is a plain string as far as pg_i18n is
  concerned and will be promoted wholesale on write.
- Language codes are opaque keys. Nothing stops you from using `en-GB` and
  `en` side by side, but nothing resolves between them either.
- `i18n_set` with a `NULL` value that empties the object returns `NULL`, not
  `{}`.
- Automation only ever adds languages. It requests only what is missing or
  empty, `i18n_fill` writes only what is still missing at write-back time, and
  a changed source text does not retranslate languages that already exist.
  Clear a language (`i18n_set(v, 'it', NULL)`) to have it redone.
- Automation triggers fire on the base table, so writes through wrapped views
  and direct writes are treated the same. The worker's own write-back fires
  the trigger too, which finds nothing missing and stops there.

## Running the tests

```sh
make test                          # same as ./test.sh; also make test-ext, make test-worker
./test.sh                          # plain script, throwaway postgres:16-alpine container
EXT=1 ./test.sh                    # build + install the extension with PGXS, then CREATE EXTENSION
EXT=1 ./test.sh postgres:17-alpine # any official image
./worker/test_worker.sh            # providers against a mock HTTP server, then end-to-end: postgres + worker, echo provider
```

Or against any empty database: `psql -d empty_db -f test.sql` (add
`-v use_ext=1` to load via `CREATE EXTENSION`). The script stops at the first
failing statement.

## License

MIT
