\set ON_ERROR_STOP on
\if :{?use_ext}
CREATE EXTENSION pg_i18n;
\else
\i i18n.sql
\i i18n_auto.sql
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

-- fallback modes (immutable form) and i18n_exact
SELECT i18n_get('{"en":"Hello","it":"Ciao"}', 'de', 'en', 'any')     AS any_d,     -- Hello
       i18n_get('{"en":"Hello","it":"Ciao"}', 'de', 'en', 'default') AS default_d, -- Hello
       i18n_get('{"en":"Hello","it":"Ciao"}', 'de', 'en', 'none')    AS none_d,    -- NULL
       i18n_get('{"fr":"Salut"}', 'de', 'en', 'any')                 AS any_f,     -- Salut
       i18n_get('{"fr":"Salut"}', 'de', 'en', 'default')             AS default_f, -- NULL
       i18n_get('{"en":"Hello","it":""}', 'it', 'en', 'none')        AS empty_is_unset, -- NULL
       i18n_get('{"en":"Hello","it":""}', 'it', 'en', 'any')         AS empty_falls,    -- Hello
       i18n_get('plain', 'it', 'en', 'none')                         AS plain_none,     -- NULL
       i18n_get('plain', 'en', 'en', 'none')                         AS plain_none_en,  -- plain
       i18n_get('plain', 'it', 'en', 'default')                      AS plain_default,  -- plain
       i18n_exact('{"en":"Hello"}'::jsonb, 'it', 'en')               AS exact_j,        -- NULL
       i18n_exact('"Hello"'::jsonb, 'en', 'en')                      AS exact_bare;     -- Hello

-- session policy: i18n.fallback and i18n.missing
SET i18n.lang = 'de';
SELECT i18n_get('{"en":"Hello","it":"Ciao"}') AS pol_any;                        -- Hello
SET i18n.fallback = 'none';
SELECT i18n_get('{"en":"Hello","it":"Ciao"}') AS pol_none_null,                  -- NULL
       i18n_get('{"en":"Hello","it":"Ciao"}') IS NULL AS is_null;                -- t
SET i18n.missing = 'empty';
SELECT i18n_get('{"en":"Hello","it":"Ciao"}') AS pol_none_empty,                 -- ''
       length(i18n_get('{"en":"Hello","it":"Ciao"}')) AS len,                    -- 0
       i18n_get(NULL::text) AS null_stays_null,                                  -- NULL
       i18n_get('{"de":"Hallo"}'::jsonb) AS present;                             -- Hallo
SET i18n.fallback = 'default';
SELECT i18n_get('{"fr":"Salut"}') AS pol_default_empty,                          -- ''
       i18n_get('{"en":"Hello","fr":"Salut"}') AS pol_default_hit;               -- Hello
SET i18n.fallback = 'bogus';
DO $$ BEGIN
  PERFORM i18n_get('x');
  RAISE EXCEPTION 'no error raised';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM NOT LIKE 'i18n.fallback must be%' THEN RAISE; END IF;
  RAISE NOTICE 'invalid policy rejected';
END $$;
RESET i18n.fallback; RESET i18n.missing; RESET i18n.lang;

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

-- the wrapped view follows the session policy, RETURNING included
SET i18n.fallback = 'none'; SET i18n.missing = 'empty';
SELECT id, sku, name, description FROM products ORDER BY id;
-- expected: A -> Plain name / Plain desc ; B -> Chair / A chair ; C -> '' / '' (only it exists)
UPDATE products SET price = 10 WHERE sku = 'C' RETURNING sku, name, length(name) AS len;   -- '' , 0
RESET i18n.fallback; RESET i18n.missing;

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

-- ================================================================ automation
SELECT i18n_missing('Chair', '{en,it,de}', 'en')                     AS m1,  -- {de,it}
       i18n_missing('{"en":"Chair","it":""}', '{en,it,de}', 'en')    AS m2,  -- {de,it}  (empty counts as missing)
       i18n_missing('{"en":"Chair","it":"Sedia"}'::jsonb, '{en,it}', 'en') AS m3, -- {}
       i18n_exact('Chair', 'it', 'en')                                AS e1,  -- NULL
       i18n_exact('Chair', 'en', 'en')                                AS e2,  -- Chair
       i18n_fill('Chair', '{"it":"Sedia","en":"IGNORED","de":""}')   AS f1,  -- {"en":"Chair","it":"Sedia"}
       i18n_fill('{"en":"Chair"}'::jsonb, '{"de":"Stuhl"}')           AS f2;  -- {"de":"Stuhl","en":"Chair"}
SELECT * FROM i18n_source('{"fr":"Chaise"}', 'en', 'en');             -- fr, Chaise
SELECT * FROM i18n_source('', 'en', 'en');                            -- NULL, NULL

CREATE TABLE articles (id serial PRIMARY KEY, title text, body jsonb);
INSERT INTO articles (title, body) VALUES ('Hello', '{"en":"World"}');

SELECT i18n_auto_enable('articles', 'title', '{en,it,de}', NULL, 'echo', 'news headlines');
SELECT i18n_auto_enable('articles', 'body',  '{en,it}');
SELECT i18n_backfill('articles', 'title') AS queued_title;             -- 1
SELECT i18n_backfill('articles', 'body')  AS queued_body;              -- 1

-- trigger: insert and update enqueue, complete rows do not
INSERT INTO articles (title) VALUES ('{"en":"Full","it":"Pieno","de":"Voll"}');   -- nothing missing
INSERT INTO articles (title) VALUES ('{"it":"Solo italiano"}');                    -- source it, targets {de,en}
UPDATE articles SET title = 'Hello again' WHERE id = 1;                            -- dedup into the open job

SELECT id, tbl, col, pk, source_lang, source_text, target_langs, provider, hint, status
FROM i18n_queue ORDER BY id;
-- expected 3 open jobs: (articles,title,{"id":1},en,'Hello again',{de,it},echo,'news headlines')
--                       (articles,body,{"id":1},en,World,{it})
--                       (articles,title,{"id":3},it,'Solo italiano',{de,en})

-- worker side, simulated
SELECT id, target_langs, status, attempts, claimed_by FROM i18n_queue_claim(2, 'test-worker') ORDER BY id;
SELECT id, status FROM i18n_queue ORDER BY id;                        -- 1,2 processing; 3 pending
SELECT i18n_queue_complete(1, '{"it":"Ciao di nuovo","de":"Hallo nochmal"}');
SELECT i18n_queue_fail(2, 'boom', 3);                                  -- back to pending (attempt 1 < 3)
SELECT id, title, body FROM articles ORDER BY id;
SELECT id, status, attempts, error FROM i18n_queue ORDER BY id;

-- a human translation arriving meanwhile is not overwritten
SELECT id FROM i18n_queue_claim(1, 'w2');                              -- job 2 (body)
UPDATE articles SET body = i18n_set(body, 'it', 'Mondo (umano)', 'en') WHERE id = 1;
SELECT i18n_queue_complete(2, '{"it":"Mondo (macchina)"}');
SELECT body FROM articles WHERE id = 1;                                -- it = Mondo (umano)

-- stale requeue and error after max attempts
SELECT id FROM i18n_queue_claim(1, 'w3');                              -- job 3
UPDATE i18n_queue SET updated_at = now() - interval '1 hour' WHERE id = 3;
SELECT i18n_queue_requeue_stale('10 minutes') AS requeued;             -- 1
SELECT i18n_queue_fail(3, 'x', 1);                                     -- attempts 2 >= 1 -> error
SELECT id, status FROM i18n_queue ORDER BY id;                         -- done, done, error

-- disable removes the trigger
SELECT i18n_auto_disable('articles', 'title');
INSERT INTO articles (title) VALUES ('No queue');
SELECT count(*) AS open_jobs FROM i18n_queue WHERE status IN ('pending','processing');  -- 0

-- automation on a wrapped table: writes through the view enqueue too
SELECT i18n_auto_enable('products_i18n', 'name', '{en,it,de}');
SET i18n.lang = 'it';
INSERT INTO products (sku, name) VALUES ('F', 'Scaffale');
RESET i18n.lang;
SELECT source_lang, source_text, target_langs FROM i18n_queue WHERE tbl = 'products_i18n'::regclass; -- it, Scaffale, {de,en}

-- ================================================================ coverage views
SELECT i18n_present('Chair', 'en') AS p1,                                  -- {en}
       i18n_present('{"en":"Chair","it":""}', 'en') AS p2,                 -- {en}
       i18n_present(''::text, 'en') AS p3,                                 -- {}
       i18n_present('{"en":"Chair","de":"Stuhl"}'::jsonb, 'en') AS p4;     -- {de,en}

SELECT * FROM i18n_missing_rows('articles', 'title', '{en,it,de}') ORDER BY pk;
-- expected: id 3 (only it -> missing {de,en}), id 4 ('No queue', plain -> present {en}, missing {de,it})
SELECT * FROM i18n_coverage_of('articles', 'title', '{en,it,de}');

SELECT tbl, col, enabled, pk, present, missing, queued FROM i18n_missing_translations ORDER BY tbl::text, col, pk;
SELECT tbl, col, enabled, lang, total, missing, done_pct FROM i18n_coverage ORDER BY tbl::text, col, lang;

-- ================================================================ language detection
SELECT i18n_relocate('{"it":"Hello world"}', 'it', 'en', 'Hello world')      AS moved,     -- {"en": "Hello world"}
       i18n_relocate('{"it":"Hello world"}', 'it', 'en', 'other')            AS untouched, -- unchanged (text differs)
       i18n_relocate('{"it":"Hello","en":"Hi"}'::jsonb, 'it', 'en', 'Hello') AS kept,      -- unchanged (en has text)
       i18n_relocate('Bonjour', 'en', 'fr', 'Bonjour')                       AS plain;     -- {"fr": "Bonjour"}

CREATE TABLE notes (id serial PRIMARY KEY, txt text);
SELECT i18n_auto_enable('notes', 'txt', '{en,it}', NULL, 'echo', NULL, true);
SELECT i18n_wrap_table('notes', '{txt}', 'notes_v');
SET i18n.lang = 'it';
INSERT INTO notes_v (txt) VALUES ('Hello world');          -- English text stored under it
RESET i18n.lang;
SELECT source_lang, source_text, target_langs, langs, detect FROM i18n_queue WHERE tbl = 'notes'::regclass;
-- expected: it, Hello world, {en}, {en,it}, t

-- worker reports detected 'en': text moves to en, it gets the translation
SELECT max(id) AS id FROM i18n_queue WHERE tbl = 'notes'::regclass AND status = 'pending' \gset
SELECT i18n_queue_complete(:id, '{"it":"Ciao mondo"}', 'en');
SELECT txt FROM notes;                                       -- {"en": "Hello world", "it": "Ciao mondo"}
SELECT status, detected_lang FROM i18n_queue WHERE id = :id; -- done, en

-- detected language outside the main ones: kept under its own key, main ones filled
INSERT INTO notes (txt) VALUES ('Bonjour');                  -- plain string, assumed en
SELECT max(id) AS id FROM i18n_queue WHERE tbl = 'notes'::regclass AND status = 'pending' \gset
SELECT i18n_queue_complete(:id, '{"en":"Hello","it":"Ciao"}', 'fr');
SELECT txt FROM notes WHERE id = 2;                          -- {"en": "Hello", "fr": "Bonjour", "it": "Ciao"}

-- detection agreeing with the assumed language is a no-op
INSERT INTO notes (txt) VALUES ('Good morning');
SELECT max(id) AS id FROM i18n_queue WHERE tbl = 'notes'::regclass AND status = 'pending' \gset
SELECT i18n_queue_complete(:id, '{"it":"Buongiorno"}', 'en');
SELECT txt FROM notes WHERE id = 3;                          -- {"en": "Good morning", "it": "Buongiorno"}
SELECT detected_lang FROM i18n_queue WHERE id = :id;         -- NULL
