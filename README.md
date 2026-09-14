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
strings keeps working, and a migration that turns the whole thing into proper
`jsonb`.

No extension, no superuser, no dependencies. Tested on PostgreSQL 16, needs 9.5+.

## Install

```sh
psql -d mydb -f i18n.sql
```

Everything is created in the current schema. Re-running the file is safe
(`CREATE OR REPLACE` throughout).

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
| `i18n_get(v, lang, fallback)` | IMMUTABLE | Translation for `lang`, else `fallback`, else the first available language (sorted by key). A plain string is returned unchanged. |
| `i18n_get(v, lang)` | STABLE | Fallback is `i18n.default_lang`. |
| `i18n_get(v)` | STABLE | Language is `i18n.lang`. |
| `i18n_langs(v)` | IMMUTABLE | `text[]` of languages present. `{}` for a plain string. |
| `i18n_is_json(v)` | IMMUTABLE | True only for a JSON object whose values are all strings, so a text column that happens to contain some other JSON is still treated as a plain string. |
| `i18n_values(v)` | IMMUTABLE | `text[]` of every translation. A plain string gives a one-element array. |
| `i18n_all(v)` | IMMUTABLE | Every translation joined by newline. For `LIKE` search across languages. |

Use the three-argument form in expression indexes; the shorter forms depend on
session state and cannot be indexed.

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

### Session settings

| Setting | Default | Used by |
|---|---|---|
| `i18n.lang` | value of `i18n.default_lang` | one-argument `i18n_get`, two-argument `i18n_set`, wrapped views |
| `i18n.default_lang` | `en` | fallback on read, promotion language on write |

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

- **SELECT** returns the translation for `i18n.lang`, with fallback.
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

- Fallback order on read is always: requested language, fallback language,
  first available language sorted by key. Set the fallback explicitly if
  "first available" is not acceptable.
- `i18n_is_json` requires an object whose values are all strings. A stored
  value like `{"en": "a", "count": 3}` is a plain string as far as pg_i18n is
  concerned and will be promoted wholesale on write.
- Language codes are opaque keys. Nothing stops you from using `en-GB` and
  `en` side by side, but nothing resolves between them either.
- `i18n_set` with a `NULL` value that empties the object returns `NULL`, not
  `{}`.

## Running the tests

```sh
./test.sh            # starts a throwaway postgres:16-alpine container, runs test.sql
```

Or against any empty database: `psql -d empty_db -f test.sql`. The script
stops at the first failing statement.

## License

MIT
