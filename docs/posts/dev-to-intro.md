---
title: "pg_i18n: translatable columns in PostgreSQL without rewriting your app"
published: false
description: "Store translations inside the row as JSON, keep a string-only API working through a view, migrate to jsonb when ready, and let a worker fill missing languages with DeepL, Google Translate or any LLM."
tags: postgres, sql, i18n, opensource
canonical_url: https://ingmmo.com/pg_i18n/
---

Every project I have worked on eventually needed a second language for some text stored in the database. Product names, category labels, descriptions, menu entries. And every time, the same thing happened: the schema was already there, the API was already reading and writing those columns as plain strings, and nobody wanted to touch either.

So the pragmatic hack appeared: someone started writing JSON into the text column.

```
name
-----------------------------------
Chair
{"en": "Chair", "it": "Sedia"}
```

Half the rows plain strings, half of them JSON objects, and the application still treating everything as a string. It works until someone asks for a proper list of Italian product names.

I wrote [pg_i18n](https://github.com/sirmmo/pg_i18n) to make this state of affairs a feature instead of a bug. It is pure SQL and PL/pgSQL, no compiled code, and it installs either as a PostgreSQL extension or as a script you load with `psql`. It works on PostgreSQL 9.5 and up, tested on 14, 16 and 17.

## Reading and writing one language

The core is two functions that understand both shapes of the column:

```sql
SET i18n.lang = 'it';

SELECT i18n_get(name) FROM products;
-- 'Chair'                       -> Chair     (plain string, returned as-is)
-- {"en":"Chair","it":"Sedia"}   -> Sedia

UPDATE products SET name = i18n_set(name, 'Sedia rossa') WHERE id = 1;
-- 'Chair' -> {"en": "Chair", "it": "Sedia rossa"}
```

A plain string is taken to be in the default language, so writing Italian to it promotes it to a JSON object instead of losing the English. Reading falls back as far as you want: requested language, then default language, then whatever exists. Or not at all, if you set `i18n.fallback = 'none'` and want a NULL or an empty string for a language that is not there.

Everything exists for both `text` and `jsonb` columns, and the explicit forms are `IMMUTABLE`, so they go into expression indexes:

```sql
CREATE INDEX ON products USING gin (i18n_get(name, 'it', 'en') gin_trgm_ops);
SELECT * FROM products WHERE i18n_get(name, 'it', 'en') ILIKE '%sedia%';
```

## The part I actually needed: the app does not change

The API reads and writes plain strings and it is not going to be rewritten this quarter. Fine. Rename the table and put a view in its place:

```sql
ALTER TABLE products RENAME TO products_i18n;
SELECT i18n_wrap_table('products_i18n', '{name,description}', 'products');
```

The view exposes `name` and `description` as plain strings in the session language. `INSTEAD OF` triggers write back into the JSON, touching only the current language. The application keeps running its old queries against `products`. The only thing it needs is the language, and that can be set per connection, per transaction, or once per database role:

```sql
ALTER ROLE api_it SET i18n.lang = 'it';
```

Inserts store `{"it": "..."}`, updates change only Italian and leave the other languages alone, `RETURNING` gives back the translated row, defaults on omitted columns still apply. I was surprised how little the application notices.

## Cleaning up: migrating to jsonb

Once every writer goes through the functions or the view, the text columns can become real `jsonb` with a constraint:

```sql
SELECT * FROM i18n_migration_report('products_i18n', 'name');
--  col_type | total | nulls | plain | translated | other_json
--  text     | 12040 |    15 |  9871 |       2154 |          0

SELECT i18n_migrate_table('products_i18n', '{name,description}', 'en');
```

Plain strings become `{"en": "..."}`, the column type changes, and a `CHECK` makes sure only translation objects get in from now on. The same queries keep working because PostgreSQL picks the `jsonb` overloads by column type.

## Filling the gaps automatically

This is where it got fun. With the languages in the row, "which rows are missing German" is a cheap question, and answering it with a machine translation is a good first draft for product names and labels.

PostgreSQL cannot call HTTP APIs portably, so the split is: the database detects rows missing a configured language and puts them on a queue table, a small Python worker outside the database calls the provider and writes back.

```sql
SELECT i18n_auto_enable('products_i18n', 'name', '{en,it,de}',
                        NULL, 'deepl', 'furniture product names, keep brand names untranslated');
SELECT i18n_backfill('products_i18n', 'name');
```

```sh
PG_I18N_PROVIDER=deepl DEEPL_API_KEY=... ./pg_i18n_worker.py
```

Providers are DeepL, Google Cloud Translation, and OpenRouter, which means any LLM with a prompt that includes the per-column hint above. The rules that keep it safe:

- only missing languages are requested, and only what is still missing at write-back time is written. A human translation entered while a job is in flight wins;
- a changed source text does not retranslate existing languages;
- claims use `FOR UPDATE SKIP LOCKED`, so you can run several workers;
- two views, `i18n_coverage` and `i18n_missing_translations`, show what is done and what is still open.

### Detecting the language of what was inserted

One more real-world problem: the API knows nothing about languages, so a plain string is assumed to be English, and someone in an Italian session pastes an English text that lands under `it`. With detection enabled on a column, the worker asks the provider what language the text actually is. If it disagrees with the key the text was stored under, the text moves to the right key and the other languages are filled from it. A language outside your configured set stays under its own key:

```
inserted, {en,it} configured:  'Bonjour'
after the worker:              {"en": "Hello", "fr": "Bonjour", "it": "Ciao"}
```

## Where it fits, and where it does not

It fits when translations belong inside the row and the application is not going to change: legacy databases with mixed content, string-only APIs, catalogues, CMS labels, multi-tenant apps where each role has its own language.

It does not fit long documents that need per-language versioning and an approval workflow. There a translations table or a translation management system is the better tool.

## Try it

```sh
git clone https://github.com/sirmmo/pg_i18n
cd pg_i18n && make install
psql -d mydb -c 'CREATE EXTENSION pg_i18n'
```

Or `psql -d mydb -f i18n.sql -f i18n_auto.sql` on a managed database where you cannot install extensions. The test suite runs against throwaway Docker containers, including an end-to-end run of the worker with an offline provider.

Docs: https://ingmmo.com/pg_i18n/ · Source: https://github.com/sirmmo/pg_i18n · MIT.

I would like to hear how other people have handled the "JSON in a text column" situation, and which provider you would want next.
