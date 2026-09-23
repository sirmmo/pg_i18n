-- pg_i18n automation: keep chosen languages filled in by an external
-- translation service (DeepL, OpenRouter, ...).
--
-- PostgreSQL cannot call HTTP APIs portably, so the split is:
--   database (this file) : configuration, detection of missing languages,
--                          a work queue fed by triggers, apply-back functions
--   worker (worker/)     : claims queue rows, calls the provider, writes back
--
-- Load after i18n.sql (the extension script includes both).
--
-- Public API
--   i18n_missing(v, langs [, default_lang])   -> text[] : languages in langs absent or empty in v
--   i18n_fill(v, translations jsonb)          -> same type as v : add only languages still missing
--   i18n_auto_enable(tbl, col, langs [, source_lang, provider, hint, detect])
--   i18n_relocate(v, from_lang, to_lang, txt) -> same type as v : move txt from one language key to another
--   i18n_auto_disable(tbl, col)
--   i18n_backfill(tbl, col)                   -> bigint : enqueue every row with missing languages
--   i18n_queue_claim(n, worker)               -> SETOF i18n_queue  (worker side)
--   i18n_queue_complete(id, translations [, detected_lang])        (worker side)
--   i18n_queue_fail(id, error [, max_attempts])                    (worker side)
--   i18n_queue_requeue_stale([interval])      -> bigint
--   i18n_present(v, default_lang)             -> text[] : languages with non-empty text
--   i18n_missing_rows(tbl, col, langs)        -> rows of (pk, present, missing) for one column
--   i18n_coverage_of(tbl, col, langs)         -> rows of (lang, total, missing, done_pct)
--   VIEW i18n_missing_translations            : every configured row/column with missing languages
--   VIEW i18n_coverage                        : per configured column and language, how many rows are missing

-- ---------------------------------------------------------------- tables

CREATE TABLE IF NOT EXISTS i18n_auto (
  tbl         regclass NOT NULL,
  col         name     NOT NULL,
  langs       text[]   NOT NULL,       -- languages to keep filled
  source_lang text,                    -- preferred source; NULL = i18n.default_lang, else first available
  provider    text,                    -- NULL = worker default (deepl | google | openrouter | echo)
  hint        text,                    -- free-text context handed to LLM providers
  detect      boolean  NOT NULL DEFAULT false,  -- detect the language of inserted text (see README)
  enabled     boolean  NOT NULL DEFAULT true,
  PRIMARY KEY (tbl, col)
);
-- upgrade path for installs made before these columns existed
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'i18n_auto'::regclass AND attname = 'detect' AND NOT attisdropped) THEN
    ALTER TABLE i18n_auto ADD COLUMN detect boolean NOT NULL DEFAULT false;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS i18n_queue (
  id           bigserial PRIMARY KEY,
  tbl          regclass NOT NULL,
  col          name     NOT NULL,
  pk           jsonb    NOT NULL,      -- {"id": 5} or {"a": .., "b": ..} for composite keys
  source_lang  text     NOT NULL,
  source_text  text     NOT NULL,
  target_langs text[]   NOT NULL,
  langs        text[],                 -- all configured languages (for re-planning after detection)
  provider     text,
  hint         text,
  detect       boolean  NOT NULL DEFAULT false,
  detected_lang text,                  -- what the worker detected, when it differs from source_lang
  status       text     NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'processing', 'done', 'error')),
  attempts     int      NOT NULL DEFAULT 0,
  error        text,
  claimed_by   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'i18n_queue'::regclass AND attname = 'detect' AND NOT attisdropped) THEN
    ALTER TABLE i18n_queue ADD COLUMN langs text[];
    ALTER TABLE i18n_queue ADD COLUMN detect boolean NOT NULL DEFAULT false;
    ALTER TABLE i18n_queue ADD COLUMN detected_lang text;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS i18n_queue_open_uq
  ON i18n_queue (tbl, col, pk) WHERE status IN ('pending', 'processing');
CREATE INDEX IF NOT EXISTS i18n_queue_status_idx ON i18n_queue (status, id);

-- Inside CREATE EXTENSION, mark the tables as data to be dumped by pg_dump.
-- Outside (plain \i), the tables are ordinary and this is a no-op.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_depend
             WHERE classid = 'pg_class'::regclass AND objid = 'i18n_auto'::regclass AND deptype = 'e') THEN
    PERFORM pg_catalog.pg_extension_config_dump('i18n_auto', '');
    PERFORM pg_catalog.pg_extension_config_dump('i18n_queue', '');
    PERFORM pg_catalog.pg_extension_config_dump('i18n_queue_id_seq', '');
  END IF;
END $$;

-- ---------------------------------------------------------------- detection

-- Languages from langs that are absent or empty in v.
CREATE OR REPLACE FUNCTION i18n_missing(v jsonb, langs text[], default_lang text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT COALESCE(array_agg(l ORDER BY l), '{}')
  FROM unnest(langs) l
  WHERE COALESCE(i18n_exact(v, l, default_lang), '') = ''
$$;

CREATE OR REPLACE FUNCTION i18n_missing(v text, langs text[], default_lang text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT COALESCE(array_agg(l ORDER BY l), '{}')
  FROM unnest(langs) l
  WHERE COALESCE(i18n_exact(v, l, default_lang), '') = ''
$$;

CREATE OR REPLACE FUNCTION i18n_missing(v jsonb, langs text[]) RETURNS text[]
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$ SELECT i18n_missing(v, langs, i18n_default_lang()) $$;

CREATE OR REPLACE FUNCTION i18n_missing(v text, langs text[]) RETURNS text[]
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$ SELECT i18n_missing(v, langs, i18n_default_lang()) $$;

-- Source for a translation: preferred language if it has text, else the first
-- non-empty one. Returns NULL lang when there is nothing to translate.
CREATE OR REPLACE FUNCTION i18n_source(v text, preferred text, default_lang text,
                                       OUT lang text, OUT txt text)
LANGUAGE plpgsql IMMUTABLE SET search_path FROM CURRENT AS $$
BEGIN
  txt := i18n_exact(v, preferred, default_lang);
  IF COALESCE(txt, '') <> '' THEN
    lang := preferred;
    RETURN;
  END IF;
  IF i18n_is_json(v) THEN
    SELECT key, value INTO lang, txt
    FROM jsonb_each_text(v::jsonb) WHERE value <> '' ORDER BY key LIMIT 1;
  ELSIF COALESCE(v, '') <> '' THEN
    lang := default_lang; txt := v;
  END IF;
  IF txt IS NULL THEN lang := NULL; END IF;
END $$;

-- Add translations for languages that are still missing; never overwrite.
CREATE OR REPLACE FUNCTION i18n_fill(v jsonb, translations jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE r record; dflt text := i18n_default_lang(); out_v jsonb := v;
BEGIN
  FOR r IN SELECT key, value FROM jsonb_each_text(COALESCE(translations, '{}')) LOOP
    CONTINUE WHEN COALESCE(r.value, '') = '';
    IF COALESCE(i18n_exact(out_v, r.key, dflt), '') = '' THEN
      out_v := i18n_set(out_v, r.key, r.value, dflt);
    END IF;
  END LOOP;
  RETURN out_v;
END $$;

CREATE OR REPLACE FUNCTION i18n_fill(v text, translations jsonb) RETURNS text
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE r record; dflt text := i18n_default_lang(); out_v text := v;
BEGIN
  FOR r IN SELECT key, value FROM jsonb_each_text(COALESCE(translations, '{}')) LOOP
    CONTINUE WHEN COALESCE(r.value, '') = '';
    IF COALESCE(i18n_exact(out_v, r.key, dflt), '') = '' THEN
      out_v := i18n_set(out_v, r.key, r.value, dflt);
    END IF;
  END LOOP;
  RETURN out_v;
END $$;

-- Move txt from from_lang to to_lang, used when the worker detected that the
-- inserted text was not in the language it was stored under. Only acts when
-- from_lang still holds exactly txt and to_lang is empty; otherwise v is
-- returned unchanged (a human edit in the meantime wins).
CREATE OR REPLACE FUNCTION i18n_relocate(v jsonb, from_lang text, to_lang text, txt text) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE dflt text := i18n_default_lang();
BEGIN
  IF from_lang = to_lang OR i18n_exact(v, from_lang, dflt) IS DISTINCT FROM txt
     OR COALESCE(i18n_exact(v, to_lang, dflt), '') <> '' THEN
    RETURN v;
  END IF;
  RETURN i18n_set(i18n_set(v, to_lang, txt, dflt), from_lang, NULL, dflt);
END $$;

CREATE OR REPLACE FUNCTION i18n_relocate(v text, from_lang text, to_lang text, txt text) RETURNS text
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE dflt text := i18n_default_lang();
BEGIN
  IF from_lang = to_lang OR i18n_exact(v, from_lang, dflt) IS DISTINCT FROM txt
     OR COALESCE(i18n_exact(v, to_lang, dflt), '') <> '' THEN
    RETURN v;
  END IF;
  RETURN i18n_set(i18n_set(v, to_lang, txt, dflt), from_lang, NULL, dflt);
END $$;

-- ---------------------------------------------------------------- helpers

CREATE OR REPLACE FUNCTION i18n_pk_columns(p_table regclass) RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT array_agg(a.attname::text ORDER BY k.ord)
  FROM pg_index i
  JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
  WHERE i.indrelid = p_table AND i.indisprimary
$$;

-- WHERE clause (as text, values inlined and typed) matching the row identified by pk.
CREATE OR REPLACE FUNCTION i18n_pk_where(p_table regclass, p_pk jsonb) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT string_agg(format('%I = %L::%s', a.attname, p_pk ->> a.attname::text,
                           format_type(a.atttypid, a.atttypmod)), ' AND ')
  FROM pg_attribute a
  WHERE a.attrelid = p_table AND a.attname::text IN (SELECT jsonb_object_keys(p_pk))
$$;

-- ---------------------------------------------------------------- queue: producer side

-- Enqueue one row/column if it misses configured languages. Returns true if queued.
CREATE OR REPLACE FUNCTION i18n_enqueue(p_table regclass, p_col name, p_pk jsonb, p_value text)
RETURNS boolean LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
  cfg      i18n_auto;
  dflt     text := i18n_default_lang();
  src      record;
  targets  text[];
  qid      bigint;
BEGIN
  SELECT * INTO cfg FROM i18n_auto WHERE tbl = p_table AND col = p_col AND enabled;
  IF NOT FOUND THEN RETURN false; END IF;

  src := i18n_source(p_value, COALESCE(cfg.source_lang, dflt), dflt);
  IF src.lang IS NULL THEN RETURN false; END IF;

  SELECT COALESCE(array_agg(l ORDER BY l), '{}') INTO targets
  FROM unnest(i18n_missing(p_value, cfg.langs, dflt)) l WHERE l <> src.lang;
  IF targets = '{}' THEN RETURN false; END IF;

  INSERT INTO i18n_queue (tbl, col, pk, source_lang, source_text, target_langs, langs, provider, hint, detect)
  VALUES (p_table, p_col, p_pk, src.lang, src.txt, targets, cfg.langs, cfg.provider, cfg.hint, cfg.detect)
  ON CONFLICT (tbl, col, pk) WHERE status IN ('pending', 'processing')
  DO UPDATE SET source_lang = EXCLUDED.source_lang, source_text = EXCLUDED.source_text,
                target_langs = EXCLUDED.target_langs, langs = EXCLUDED.langs,
                detect = EXCLUDED.detect, updated_at = now()
  RETURNING id INTO qid;

  PERFORM pg_notify('i18n_queue', qid::text);
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION i18n_auto_trigger() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
  col    text   := TG_ARGV[0];
  pkcols text[] := TG_ARGV[1]::text[];
  newj   jsonb  := to_jsonb(NEW);
  pk     jsonb;
BEGIN
  SELECT jsonb_object_agg(k, newj -> k) INTO pk FROM unnest(pkcols) k;
  PERFORM i18n_enqueue(TG_RELID::regclass, col, pk, newj ->> col);
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION i18n_auto_enable(p_table regclass, p_col name, p_langs text[],
                                            p_source_lang text DEFAULT NULL,
                                            p_provider text DEFAULT NULL,
                                            p_hint text DEFAULT NULL,
                                            p_detect boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE pkcols text[] := i18n_pk_columns(p_table); tg text := 'i18n_auto_' || p_col;
BEGIN
  IF pkcols IS NULL THEN
    RAISE EXCEPTION 'i18n_auto_enable: % has no primary key', p_table;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = p_table AND attname = p_col AND NOT attisdropped) THEN
    RAISE EXCEPTION 'i18n_auto_enable: column %.% does not exist', p_table, p_col;
  END IF;

  INSERT INTO i18n_auto (tbl, col, langs, source_lang, provider, hint, detect, enabled)
  VALUES (p_table, p_col, p_langs, p_source_lang, p_provider, p_hint, p_detect, true)
  ON CONFLICT (tbl, col) DO UPDATE
    SET langs = EXCLUDED.langs, source_lang = EXCLUDED.source_lang,
        provider = EXCLUDED.provider, hint = EXCLUDED.hint,
        detect = EXCLUDED.detect, enabled = true;

  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = p_table AND tgname = tg) THEN
    EXECUTE format('DROP TRIGGER %I ON %s', tg, p_table);
  END IF;
  EXECUTE format(
    'CREATE TRIGGER %I AFTER INSERT OR UPDATE OF %I ON %s FOR EACH ROW EXECUTE PROCEDURE i18n_auto_trigger(%L, %L)',
    tg, p_col, p_table, p_col, pkcols::text);
END $$;

CREATE OR REPLACE FUNCTION i18n_auto_disable(p_table regclass, p_col name)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = p_table AND tgname = 'i18n_auto_' || p_col) THEN
    EXECUTE format('DROP TRIGGER %I ON %s', 'i18n_auto_' || p_col, p_table);
  END IF;
  UPDATE i18n_auto SET enabled = false WHERE tbl = p_table AND col = p_col;
END $$;

-- Enqueue every existing row that misses a configured language.
CREATE OR REPLACE FUNCTION i18n_backfill(p_table regclass, p_col name)
RETURNS bigint LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE pkcols text[] := i18n_pk_columns(p_table); n bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM i18n_auto WHERE tbl = p_table AND col = p_col AND enabled) THEN
    RAISE EXCEPTION 'i18n_backfill: %.% is not enabled, call i18n_auto_enable first', p_table, p_col;
  END IF;
  EXECUTE format(
    'SELECT count(*) FILTER (WHERE i18n_enqueue(%L, %L, '
    '  (SELECT jsonb_object_agg(k, to_jsonb(t) -> k) FROM unnest(%L::text[]) k), %I::text)) FROM %s t',
    p_table, p_col, pkcols::text, p_col, p_table) INTO n;
  RETURN n;
END $$;

-- ---------------------------------------------------------------- queue: worker side

CREATE OR REPLACE FUNCTION i18n_queue_claim(p_limit int DEFAULT 10, p_worker text DEFAULT NULL)
RETURNS SETOF i18n_queue LANGUAGE sql SET search_path FROM CURRENT AS $$
  UPDATE i18n_queue q
     SET status = 'processing', claimed_by = p_worker, attempts = attempts + 1, updated_at = now()
   WHERE id IN (SELECT id FROM i18n_queue WHERE status = 'pending'
                ORDER BY id LIMIT p_limit FOR UPDATE SKIP LOCKED)
  RETURNING q.*
$$;

-- Apply translations ({"it": "...", "de": "..."}) to the row, filling only
-- what is still missing, and mark the job done.
-- p_detected_lang: the language the worker detected for source_text. When it
-- differs from source_lang the text is moved to that key first (see
-- i18n_relocate), so the translations may then fill source_lang as well.
CREATE OR REPLACE FUNCTION i18n_queue_complete(p_id bigint, p_translations jsonb,
                                               p_detected_lang text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE q i18n_queue; expr text;
BEGIN
  SELECT * INTO q FROM i18n_queue WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'i18n_queue_complete: no job %', p_id; END IF;

  expr := format('%I', q.col);
  IF p_detected_lang IS NOT NULL AND p_detected_lang <> q.source_lang THEN
    expr := format('i18n_relocate(%s, %L, %L, %L)', expr, q.source_lang, p_detected_lang, q.source_text);
  END IF;
  expr := format('i18n_fill(%s, %L::jsonb)', expr, p_translations);

  EXECUTE format('UPDATE %s SET %I = %s WHERE %s', q.tbl, q.col, expr, i18n_pk_where(q.tbl, q.pk));

  UPDATE i18n_queue
     SET status = 'done', error = NULL, updated_at = now(),
         detected_lang = CASE WHEN p_detected_lang <> source_lang THEN p_detected_lang END
   WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION i18n_queue_fail(p_id bigint, p_error text, p_max_attempts int DEFAULT 3)
RETURNS void LANGUAGE sql SET search_path FROM CURRENT AS $$
  UPDATE i18n_queue
     SET status = CASE WHEN attempts >= p_max_attempts THEN 'error' ELSE 'pending' END,
         error = p_error, updated_at = now()
   WHERE id = p_id
$$;

-- Jobs a dead worker left in 'processing' go back to 'pending'.
CREATE OR REPLACE FUNCTION i18n_queue_requeue_stale(p_age interval DEFAULT '10 minutes')
RETURNS bigint LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE n bigint;
BEGIN
  UPDATE i18n_queue SET status = 'pending', updated_at = now()
   WHERE status = 'processing' AND updated_at < now() - p_age;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ---------------------------------------------------------------- checking coverage

-- Languages that have non-empty text. A plain string counts as default_lang.
CREATE OR REPLACE FUNCTION i18n_present(v jsonb, default_lang text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT CASE
    WHEN v IS NULL THEN '{}'::text[]
    WHEN i18n_is_json(v) THEN
      (SELECT COALESCE(array_agg(key ORDER BY key), '{}') FROM jsonb_each_text(v) WHERE value <> '')
    WHEN COALESCE(i18n_get(v, default_lang, default_lang), '') = '' THEN '{}'::text[]
    ELSE ARRAY[default_lang]
  END
$$;

CREATE OR REPLACE FUNCTION i18n_present(v text, default_lang text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT CASE
    WHEN v IS NULL OR v = '' THEN '{}'::text[]
    WHEN i18n_is_json(v) THEN i18n_present(v::jsonb, default_lang)
    ELSE ARRAY[default_lang]
  END
$$;

-- Rows of one column that miss at least one of langs. Works on any table with
-- a primary key, configured for automation or not.
CREATE OR REPLACE FUNCTION i18n_missing_rows(p_table regclass, p_col name, p_langs text[],
                                             p_default_lang text DEFAULT NULL)
RETURNS TABLE (pk jsonb, present text[], missing text[])
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE
  pkcols text[] := i18n_pk_columns(p_table);
  dflt   text   := COALESCE(p_default_lang, i18n_default_lang());
BEGIN
  IF pkcols IS NULL THEN
    RAISE EXCEPTION 'i18n_missing_rows: % has no primary key', p_table;
  END IF;
  RETURN QUERY EXECUTE format(
    'SELECT (SELECT jsonb_object_agg(k, to_jsonb(t) -> k) FROM unnest(%1$L::text[]) k),
            i18n_present(%2$I, %4$L),
            i18n_missing(%2$I, %3$L::text[], %4$L)
       FROM %5$s t
      WHERE i18n_missing(%2$I, %3$L::text[], %4$L) <> ''{}''',
    pkcols::text, p_col, p_langs::text, dflt, p_table);
END $$;

-- Per-language counts for one column.
CREATE OR REPLACE FUNCTION i18n_coverage_of(p_table regclass, p_col name, p_langs text[],
                                            p_default_lang text DEFAULT NULL)
RETURNS TABLE (lang text, total bigint, missing bigint, done_pct numeric)
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE dflt text := COALESCE(p_default_lang, i18n_default_lang());
BEGIN
  RETURN QUERY EXECUTE format(
    'SELECT l, count(*), count(*) FILTER (WHERE l = ANY (i18n_missing(%1$I, %2$L::text[], %3$L))),
            round(100.0 * count(*) FILTER (WHERE NOT l = ANY (i18n_missing(%1$I, %2$L::text[], %3$L)))
                  / GREATEST(count(*), 1), 1)
       FROM %4$s t CROSS JOIN unnest(%2$L::text[]) l
      GROUP BY l ORDER BY l',
    p_col, p_langs::text, dflt, p_table);
END $$;

-- Every row/column configured in i18n_auto that still misses a language,
-- and whether a translation job is already open for it.
CREATE OR REPLACE VIEW i18n_missing_translations AS
SELECT a.tbl, a.col, a.enabled, r.pk, r.present, r.missing,
       EXISTS (SELECT 1 FROM i18n_queue q
                WHERE q.tbl = a.tbl AND q.col = a.col AND q.pk = r.pk
                  AND q.status IN ('pending', 'processing')) AS queued
FROM i18n_auto a
CROSS JOIN LATERAL i18n_missing_rows(a.tbl, a.col, a.langs) r;

-- Per configured column and language: rows total, rows missing it, percentage done.
CREATE OR REPLACE VIEW i18n_coverage AS
SELECT a.tbl, a.col, a.enabled, c.lang, c.total, c.missing, c.done_pct
FROM i18n_auto a
CROSS JOIN LATERAL i18n_coverage_of(a.tbl, a.col, a.langs) c;
