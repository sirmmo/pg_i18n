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
--   i18n_exact(v, lang, default_lang)         -> text   : translation for lang, no fallback
--   i18n_fill(v, translations jsonb)          -> same type as v : add only languages still missing
--   i18n_auto_enable(tbl, col, langs [, source_lang, provider, hint])
--   i18n_auto_disable(tbl, col)
--   i18n_backfill(tbl, col)                   -> bigint : enqueue every row with missing languages
--   i18n_queue_claim(n, worker)               -> SETOF i18n_queue  (worker side)
--   i18n_queue_complete(id, translations)                          (worker side)
--   i18n_queue_fail(id, error [, max_attempts])                    (worker side)
--   i18n_queue_requeue_stale([interval])      -> bigint

-- ---------------------------------------------------------------- tables

CREATE TABLE IF NOT EXISTS i18n_auto (
  tbl         regclass NOT NULL,
  col         name     NOT NULL,
  langs       text[]   NOT NULL,       -- languages to keep filled
  source_lang text,                    -- preferred source; NULL = i18n.default_lang, else first available
  provider    text,                    -- NULL = worker default (deepl | openrouter | echo)
  hint        text,                    -- free-text context handed to LLM providers
  enabled     boolean  NOT NULL DEFAULT true,
  PRIMARY KEY (tbl, col)
);

CREATE TABLE IF NOT EXISTS i18n_queue (
  id           bigserial PRIMARY KEY,
  tbl          regclass NOT NULL,
  col          name     NOT NULL,
  pk           jsonb    NOT NULL,      -- {"id": 5} or {"a": .., "b": ..} for composite keys
  source_lang  text     NOT NULL,
  source_text  text     NOT NULL,
  target_langs text[]   NOT NULL,
  provider     text,
  hint         text,
  status       text     NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'processing', 'done', 'error')),
  attempts     int      NOT NULL DEFAULT 0,
  error        text,
  claimed_by   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

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

-- Translation for exactly lang, no fallback. A plain string counts as default_lang.
CREATE OR REPLACE FUNCTION i18n_exact(v jsonb, lang text, default_lang text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL THEN NULL
    WHEN jsonb_typeof(v) = 'object' THEN v ->> lang
    WHEN lang = default_lang AND jsonb_typeof(v) = 'string' THEN v #>> '{}'
    WHEN lang = default_lang THEN v::text
    ELSE NULL
  END
$$;

CREATE OR REPLACE FUNCTION i18n_exact(v text, lang text, default_lang text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT CASE
    WHEN v IS NULL THEN NULL
    WHEN i18n_is_json(v) THEN v::jsonb ->> lang
    WHEN lang = default_lang THEN v
    ELSE NULL
  END
$$;

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

  INSERT INTO i18n_queue (tbl, col, pk, source_lang, source_text, target_langs, provider, hint)
  VALUES (p_table, p_col, p_pk, src.lang, src.txt, targets, cfg.provider, cfg.hint)
  ON CONFLICT (tbl, col, pk) WHERE status IN ('pending', 'processing')
  DO UPDATE SET source_lang = EXCLUDED.source_lang, source_text = EXCLUDED.source_text,
                target_langs = EXCLUDED.target_langs, updated_at = now()
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
                                            p_hint text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE pkcols text[] := i18n_pk_columns(p_table); tg text := 'i18n_auto_' || p_col;
BEGIN
  IF pkcols IS NULL THEN
    RAISE EXCEPTION 'i18n_auto_enable: % has no primary key', p_table;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = p_table AND attname = p_col AND NOT attisdropped) THEN
    RAISE EXCEPTION 'i18n_auto_enable: column %.% does not exist', p_table, p_col;
  END IF;

  INSERT INTO i18n_auto (tbl, col, langs, source_lang, provider, hint, enabled)
  VALUES (p_table, p_col, p_langs, p_source_lang, p_provider, p_hint, true)
  ON CONFLICT (tbl, col) DO UPDATE
    SET langs = EXCLUDED.langs, source_lang = EXCLUDED.source_lang,
        provider = EXCLUDED.provider, hint = EXCLUDED.hint, enabled = true;

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
CREATE OR REPLACE FUNCTION i18n_queue_complete(p_id bigint, p_translations jsonb)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE q i18n_queue;
BEGIN
  SELECT * INTO q FROM i18n_queue WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'i18n_queue_complete: no job %', p_id; END IF;

  EXECUTE format('UPDATE %s SET %I = i18n_fill(%I, %L::jsonb) WHERE %s',
                 q.tbl, q.col, q.col, p_translations, i18n_pk_where(q.tbl, q.pk));

  UPDATE i18n_queue SET status = 'done', error = NULL, updated_at = now() WHERE id = p_id;
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
