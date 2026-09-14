\set ON_ERROR_STOP on
\if :{?use_ext}
CREATE EXTENSION pg_i18n;
\else
\i i18n.sql
\endif

-- scalar functions
SELECT i18n_is_json('plain')                         AS f1,   -- f
       i18n_is_json('{"en":"a","it":"b"}')            AS t1,   -- t
       i18n_is_json('{"foo": 1}')                     AS f2,   -- f (non-string value)
       i18n_is_json('{bad json')                      AS f3,   -- f
       i18n_is_json('[1,2]')                          AS f4,   -- f
       i18n_is_json(NULL)                             AS n1;   -- f

SELECT i18n_get('plain', 'it', 'en')                  AS plain,      -- plain
       i18n_get('{"en":"Hello","it":"Ciao"}','it','en') AS it,       -- Ciao
       i18n_get('{"en":"Hello","it":"Ciao"}','de','en') AS fb,       -- Hello
       i18n_get('{"fr":"Salut"}','de','en')           AS first,      -- Salut
       i18n_get(NULL,'it','en')                       AS nul,        -- NULL
       i18n_langs('{"en":"Hello","it":"Ciao"}')       AS langs;      -- {en,it}

SELECT i18n_set('plain', 'it', 'Ciao', 'en')          AS promoted,   -- {"en":"plain","it":"Ciao"}
       i18n_set('{"en":"Hello"}', 'it', 'Ciao', 'en') AS added,      -- {"en":"Hello","it":"Ciao"}
       i18n_set('{"en":"Hello"}', 'en', 'Hi', 'en')   AS replaced,   -- {"en":"Hi"}
       i18n_set(NULL, 'it', 'Ciao', 'en')             AS fromnull,   -- {"it":"Ciao"}
       i18n_set('{"en":"Hello","it":"Ciao"}','it',NULL,'en') AS removed, -- {"en":"Hello"}
       i18n_set('{"it":"Ciao"}','it',NULL,'en')       AS emptied;    -- NULL

-- session-driven overloads
SET i18n.lang = 'it';
SELECT i18n_get('{"en":"Hello","it":"Ciao"}') AS sess_it, i18n_set('Hello', 'Ciao') AS sess_set;
RESET i18n.lang;
SELECT i18n_get('{"en":"Hello","it":"Ciao"}') AS sess_default;

-- transparent view layer
CREATE TABLE products_i18n (
  id serial PRIMARY KEY,
  sku text NOT NULL,
  name text,
  description text,
  price numeric(10,2) DEFAULT 0
);
INSERT INTO products_i18n (sku, name, description) VALUES
  ('A', 'Plain name', 'Plain desc'),
  ('B', '{"en":"Chair","it":"Sedia"}', '{"en":"A chair"}');

SELECT i18n_wrap_table('products_i18n', '{name,description}', 'products');

SET i18n.lang = 'it';
SELECT id, sku, name, description, price FROM products ORDER BY id;
-- expected: A -> Plain name / Plain desc ; B -> Sedia / A chair

INSERT INTO products (sku, name, description, price) VALUES ('C', 'Tavolo', 'Un tavolo', 9.5)
  RETURNING id, sku, name, description, price;

UPDATE products SET name = 'Sedia rossa', price = 12 WHERE sku = 'B'
  RETURNING id, name, price;
UPDATE products SET name = 'Nome piano' WHERE sku = 'A';        -- promotes plain string

SET i18n.lang = 'en';
SELECT id, sku, name, description FROM products ORDER BY id;
-- expected: A -> Plain name ; B -> Chair ; C -> Tavolo (only it exists, first available)

DELETE FROM products WHERE sku = 'C';

RESET i18n.lang;
SELECT id, sku, name, description, price FROM products_i18n ORDER BY id;
-- raw storage: A -> {"en":"Plain name","it":"Nome piano"} ; B -> {"en":"Chair","it":"Sedia rossa"}

-- expression index on the immutable form
CREATE INDEX ON products_i18n (i18n_get(name, 'it', 'en'));

-- ================================================================ LIKE search on text columns (pre-migration)
SELECT i18n_values('{"en":"Chair","it":"Sedia"}') AS vals,       -- {Chair,Sedia}
       i18n_values('plain')                        AS plain,      -- {plain}
       i18n_all('{"en":"Chair","it":"Sedia"}')     AS joined;     -- Chair\nSedia

-- one language, with fallback
SELECT sku FROM products_i18n WHERE i18n_get(name, 'it', 'en') ILIKE '%sedia%';   -- B
-- any language
SELECT sku FROM products_i18n WHERE i18n_all(name) ILIKE '%chair%' ORDER BY sku;  -- B
SELECT sku FROM products_i18n WHERE i18n_all(name) ILIKE '%plain%' ORDER BY sku;  -- A
-- through the view, in the session language
SET i18n.lang = 'it';
SELECT sku FROM products WHERE name ILIKE '%piano%';                              -- A
RESET i18n.lang;

-- trigram indexes on the text column
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX products_name_it_trgm ON products_i18n USING gin (i18n_get(name, 'it', 'en') gin_trgm_ops);
CREATE INDEX products_name_all_trgm ON products_i18n USING gin (i18n_all(name) gin_trgm_ops);
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT sku FROM products_i18n WHERE i18n_all(name) ILIKE '%chair%';
RESET enable_seqscan;

-- ================================================================ migration to jsonb
DROP VIEW products;                                   -- ALTER TYPE needs no dependent view
INSERT INTO products_i18n (sku, name, description) VALUES ('D', 'Legacy', NULL);
SELECT * FROM i18n_migration_report('products_i18n', 'name');
-- expected: text, total 3, nulls 0, plain 1 (D), translated 2

SELECT i18n_migrate_table('products_i18n', '{name,description}', 'en');
SELECT * FROM i18n_migration_report('products_i18n', 'name');
-- expected: jsonb, translated 3, plain 0
SELECT id, sku, name, description FROM products_i18n ORDER BY id;
-- expected raw jsonb: A {"en":"Plain name","it":"Nome piano"} ; B {"en":"Chair","it":"Sedia rossa"} ; D {"en":"Legacy"} / NULL

-- constraint rejects non-translation JSON
DO $$ BEGIN
  INSERT INTO products_i18n (sku, name) VALUES ('X', '{"en": 1}');
  RAISE EXCEPTION 'constraint did not fire';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'check ok'; END $$;

-- jsonb overloads
SELECT i18n_get('{"en":"Hello","it":"Ciao"}'::jsonb, 'it', 'en') AS it,
       i18n_get('"bare"'::jsonb, 'it', 'en')                      AS bare,
       i18n_set('{"en":"Hello"}'::jsonb, 'it', 'Ciao', 'en')      AS added,
       i18n_set('"Hello"'::jsonb, 'it', 'Ciao', 'en')             AS promoted,
       i18n_set('{"it":"Ciao"}'::jsonb, 'it', NULL, 'en')         AS emptied,
       i18n_langs('{"en":"Hello","it":"Ciao"}'::jsonb)            AS langs;

-- the same view layer on top of jsonb columns
SELECT i18n_wrap_table('products_i18n', '{name,description}', 'products');
SET i18n.lang = 'it';
SELECT id, sku, name, description FROM products ORDER BY id;
INSERT INTO products (sku, name, description) VALUES ('E', 'Lampada', 'Una lampada') RETURNING id, name, description;
UPDATE products SET name = 'Legacy IT' WHERE sku = 'D' RETURNING id, name;
SET i18n.lang = 'en';
SELECT id, sku, name FROM products ORDER BY id;
-- expected: A Plain name ; B Chair ; D Legacy ; E Lampada (fallback to only language)
RESET i18n.lang;
SELECT id, sku, name, description FROM products_i18n ORDER BY id;

-- indexes on jsonb: expression index for equality/LIKE, GIN for containment
CREATE INDEX ON products_i18n (i18n_get(name, 'it', 'en'));
CREATE INDEX ON products_i18n USING gin (name);
SELECT sku FROM products_i18n WHERE name @> '{"it":"Legacy IT"}';
