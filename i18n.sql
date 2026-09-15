-- pg_i18n: helpers for columns that hold either a plain string
-- or a JSON object of translations: {"en":"Hello","it":"Ciao"}
--
-- Requires PostgreSQL >= 9.5. Tested on 14, 16 and 17.
--
-- Functions that call other pg_i18n functions are declared with
-- SET search_path FROM CURRENT, so they keep working when PostgreSQL 17+
-- runs index builds and constraint checks under a restricted search_path.
-- This pins the schema they were installed in: install with the intended
-- schema on the search_path (or CREATE EXTENSION ... SCHEMA x).
--
-- Session settings (custom GUCs, no postgresql.conf change needed):
--   SET i18n.lang = 'it';          -- language used by the 1-arg functions / views
--   SET i18n.default_lang = 'en';  -- fallback + language a plain string is promoted to
--   SET i18n.fallback = 'any';     -- any | default | none: how far i18n_get falls back
--   SET i18n.missing = 'null';     -- null | empty: what a missing translation reads as
--
-- Public API
--   i18n_is_json(v)                 -> bool   : is v a {"lang":"text",...} object?
--   i18n_langs(v)                   -> text[] : languages present in v
--   i18n_get(v)                     -> text   : translation for session lang, session policy
--   i18n_get(v, lang)               -> text   : translation for lang, session policy
--   i18n_get(v, lang, fallback)     -> text   : IMMUTABLE, lang -> fallback -> first available
--   i18n_get(v, lang, dflt, mode)   -> text   : IMMUTABLE, mode any | default | none; NULL when missing
--   i18n_exact(v, lang, dflt)       -> text   : IMMUTABLE, = mode none
--   i18n_set(v, lang, val)          -> text   : return v with lang set to val (NULL val removes lang)
--   i18n_set(v, lang, val, promote) -> text   : same, plain-string v is promoted as {promote: v}
--   i18n_values(v)                  -> text[] : every translation (for search across languages)
--   i18n_all(v)                     -> text   : translations joined by newline, indexable with pg_trgm
--   i18n_wrap_table(tbl, cols, view)          : create an updatable view that exposes
--                                               translatable columns as plain strings
--   i18n_migration_report(tbl, col)           : count null / plain / json / invalid rows
--   i18n_migrate_column(tbl, col [, lang])    : promote plain strings to {lang: v}, then
--                                               ALTER the column to jsonb + CHECK constraint
--   i18n_migrate_table(tbl, cols [, lang])    : same for several columns
--
-- Every read/write function exists for both text and jsonb columns, so the
-- same queries and the same view layer work before and after the migration.

-- ---------------------------------------------------------------- settings

CREATE OR REPLACE FUNCTION i18n_default_lang() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('i18n.default_lang', true), ''), 'en')
$$;

CREATE OR REPLACE FUNCTION i18n_lang() RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
  SELECT COALESCE(NULLIF(current_setting('i18n.lang', true), ''), i18n_default_lang())
$$;

-- Fallback policy for the session-driven i18n_get forms and the wrapped views:
--   any     (default) requested lang -> default lang -> first available
--   default           requested lang -> default lang -> missing
--   none              requested lang only
CREATE OR REPLACE FUNCTION i18n_fallback() RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE m text := COALESCE(NULLIF(current_setting('i18n.fallback', true), ''), 'any');
BEGIN
  IF m NOT IN ('any', 'default', 'none') THEN
    RAISE EXCEPTION 'i18n.fallback must be any, default or none (got %)', m;
  END IF;
  RETURN m;
END $$;

-- What a missing translation reads as: NULL (default) or '' (i18n.missing = 'empty').
CREATE OR REPLACE FUNCTION i18n_on_missing() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE COALESCE(NULLIF(current_setting('i18n.missing', true), ''), 'null')
           WHEN 'empty' THEN '' ELSE NULL END
$$;

-- ---------------------------------------------------------------- inspection

-- True only for a JSON object whose values are all strings, so a text column
-- that happens to contain some other JSON is still treated as a plain string.
CREATE OR REPLACE FUNCTION i18n_is_json(v text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE j jsonb;
BEGIN
  IF v IS NULL OR left(ltrim(v), 1) <> '{' THEN
    RETURN false;
  END IF;
  j := v::jsonb;
  IF jsonb_typeof(j) <> 'object' THEN
    RETURN false;
  END IF;
  RETURN NOT EXISTS (SELECT 1 FROM jsonb_each(j) WHERE jsonb_typeof(value) <> 'string');
EXCEPTION WHEN invalid_text_representation THEN
  RETURN false;
END $$;

CREATE OR REPLACE FUNCTION i18n_langs(v text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT CASE WHEN i18n_is_json(v)
              THEN (SELECT COALESCE(array_agg(k ORDER BY k), '{}') FROM jsonb_object_keys(v::jsonb) k)
              ELSE '{}'::text[] END
$$;

-- ---------------------------------------------------------------- read

-- Core resolver. mode:
--   any      lang -> default_lang -> first non-empty translation (by key)
--   default  lang -> default_lang
--   none     lang only
-- Returns NULL when nothing matches. An empty-string translation counts as
-- not set. A plain string is the default_lang text: returned for any mode
-- except none, where it is returned only when lang = default_lang.
CREATE OR REPLACE FUNCTION i18n_get(v text, lang text, default_lang text, mode text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path FROM CURRENT AS $$
DECLARE j jsonb; r text;
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  IF NOT i18n_is_json(v) THEN
    RETURN CASE WHEN mode <> 'none' OR lang = default_lang THEN NULLIF(v, '') END;
  END IF;
  j := v::jsonb;
  r := NULLIF(j ->> lang, '');
  IF r IS NOT NULL OR mode = 'none' THEN RETURN r; END IF;
  r := NULLIF(j ->> default_lang, '');
  IF r IS NOT NULL OR mode = 'default' THEN RETURN r; END IF;
  RETURN (SELECT value FROM jsonb_each_text(j) WHERE value <> '' ORDER BY key LIMIT 1);
END $$;

-- lang -> fallback -> first available. IMMUTABLE, for expression indexes.
CREATE OR REPLACE FUNCTION i18n_get(v text, lang text, fallback text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT i18n_get(v, lang, fallback, 'any')
$$;

-- Exactly lang, no fallback at all.
CREATE OR REPLACE FUNCTION i18n_exact(v text, lang text, default_lang text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT i18n_get(v, lang, default_lang, 'none')
$$;

-- Session-driven forms: policy from i18n.fallback, missing value from i18n.missing.
CREATE OR REPLACE FUNCTION i18n_get(v text, lang text) RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
  SELECT CASE WHEN v IS NULL THEN NULL
              ELSE COALESCE(i18n_get(v, lang, i18n_default_lang(), i18n_fallback()), i18n_on_missing()) END
$$;

CREATE OR REPLACE FUNCTION i18n_get(v text) RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
  SELECT i18n_get(v, i18n_lang())
$$;

-- ---------------------------------------------------------------- write

-- Returns the new stored value for the column.
--   plain string v  -> promoted to {promote_as: v} before setting lang
--   NULL/'' v       -> starts from {}
--   NULL val        -> removes lang; if nothing is left, returns NULL
CREATE OR REPLACE FUNCTION i18n_set(v text, lang text, val text, promote_as text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path FROM CURRENT AS $$
DECLARE j jsonb;
BEGIN
  IF i18n_is_json(v) THEN
    j := v::jsonb;
  ELSIF v IS NULL OR v = '' THEN
    j := '{}'::jsonb;
  ELSE
    j := jsonb_build_object(promote_as, v);
  END IF;

  IF val IS NULL THEN
    j := j - lang;
  ELSE
    j := j || jsonb_build_object(lang, val);
  END IF;

  IF j = '{}'::jsonb THEN
    RETURN NULL;
  END IF;
  RETURN j::text;
END $$;

CREATE OR REPLACE FUNCTION i18n_set(v text, lang text, val text) RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
  SELECT i18n_set(v, lang, val, i18n_default_lang())
$$;

-- Convenience: set the session language's translation.
CREATE OR REPLACE FUNCTION i18n_set(v text, val text) RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
  SELECT i18n_set(v, i18n_lang(), val, i18n_default_lang())
$$;


-- ---------------------------------------------------------------- jsonb overloads
-- Same semantics as the text versions, minus the parsing. A bare JSON string
-- ("Chair") is tolerated and treated like a plain string.

CREATE OR REPLACE FUNCTION i18n_is_json(v jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL
     AND jsonb_typeof(v) = 'object'
     AND NOT EXISTS (SELECT 1 FROM jsonb_each(v) WHERE jsonb_typeof(value) <> 'string')
$$;

CREATE OR REPLACE FUNCTION i18n_langs(v jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT CASE WHEN i18n_is_json(v)
              THEN (SELECT COALESCE(array_agg(k ORDER BY k), '{}') FROM jsonb_object_keys(v) k)
              ELSE '{}'::text[] END
$$;

-- Kept free of SET search_path so the planner can inline it in index expressions.
CREATE OR REPLACE FUNCTION i18n_get(v jsonb, lang text, default_lang text, mode text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL THEN NULL
    WHEN jsonb_typeof(v) <> 'object' THEN
      CASE WHEN mode <> 'none' OR lang = default_lang
           THEN NULLIF(CASE WHEN jsonb_typeof(v) = 'string' THEN v #>> '{}' ELSE v::text END, '') END
    ELSE COALESCE(
      NULLIF(v ->> lang, ''),
      CASE WHEN mode = 'none' THEN NULL ELSE NULLIF(v ->> default_lang, '') END,
      CASE WHEN mode = 'any'
           THEN (SELECT value FROM jsonb_each_text(v) WHERE value <> '' ORDER BY key LIMIT 1) END)
  END
$$;

CREATE OR REPLACE FUNCTION i18n_get(v jsonb, lang text, fallback text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL THEN NULL
    WHEN jsonb_typeof(v) <> 'object' THEN
      NULLIF(CASE WHEN jsonb_typeof(v) = 'string' THEN v #>> '{}' ELSE v::text END, '')
    ELSE COALESCE(NULLIF(v ->> lang, ''), NULLIF(v ->> fallback, ''),
                  (SELECT value FROM jsonb_each_text(v) WHERE value <> '' ORDER BY key LIMIT 1))
  END
$$;

CREATE OR REPLACE FUNCTION i18n_exact(v jsonb, lang text, default_lang text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT i18n_get(v, lang, default_lang, 'none')
$$;

CREATE OR REPLACE FUNCTION i18n_get(v jsonb, lang text) RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
  SELECT CASE WHEN v IS NULL THEN NULL
              ELSE COALESCE(i18n_get(v, lang, i18n_default_lang(), i18n_fallback()), i18n_on_missing()) END
$$;

CREATE OR REPLACE FUNCTION i18n_get(v jsonb) RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$ SELECT i18n_get(v, i18n_lang()) $$;

CREATE OR REPLACE FUNCTION i18n_set(v jsonb, lang text, val text, promote_as text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path FROM CURRENT AS $$
DECLARE j jsonb;
BEGIN
  IF i18n_is_json(v) THEN
    j := v;
  ELSIF v IS NULL OR v = '""'::jsonb THEN
    j := '{}'::jsonb;
  ELSIF jsonb_typeof(v) = 'string' THEN
    j := jsonb_build_object(promote_as, v #>> '{}');
  ELSE
    j := jsonb_build_object(promote_as, v::text);
  END IF;

  IF val IS NULL THEN
    j := j - lang;
  ELSE
    j := j || jsonb_build_object(lang, val);
  END IF;

  IF j = '{}'::jsonb THEN
    RETURN NULL;
  END IF;
  RETURN j;
END $$;

CREATE OR REPLACE FUNCTION i18n_set(v jsonb, lang text, val text) RETURNS jsonb
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$ SELECT i18n_set(v, lang, val, i18n_default_lang()) $$;

CREATE OR REPLACE FUNCTION i18n_set(v jsonb, val text) RETURNS jsonb
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$ SELECT i18n_set(v, i18n_lang(), val, i18n_default_lang()) $$;

-- ---------------------------------------------------------------- migration text -> jsonb
--
-- Run BEFORE i18n_wrap_table (or DROP the view first): ALTER COLUMN TYPE
-- refuses to change a column a view depends on. Do it in a transaction;
-- it takes an ACCESS EXCLUSIVE lock and rewrites the table.

CREATE OR REPLACE FUNCTION i18n_migration_report(p_table regclass, p_col name)
RETURNS TABLE (col_type text, total bigint, nulls bigint, plain bigint, translated bigint, other_json bigint)
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
  SELECT format_type(a.atttypid, a.atttypmod) INTO col_type
  FROM pg_attribute a WHERE a.attrelid = p_table AND a.attname = p_col AND NOT a.attisdropped;
  IF col_type IS NULL THEN
    RAISE EXCEPTION 'i18n_migration_report: column %.% does not exist', p_table, p_col;
  END IF;

  RETURN QUERY EXECUTE format(
    'SELECT %L::text, count(*), count(*) FILTER (WHERE %I IS NULL),
            count(*) FILTER (WHERE %I IS NOT NULL AND NOT i18n_is_json(%I) AND left(ltrim(%I::text),1) <> ''{''),
            count(*) FILTER (WHERE i18n_is_json(%I)),
            count(*) FILTER (WHERE %I IS NOT NULL AND NOT i18n_is_json(%I) AND left(ltrim(%I::text),1) = ''{'')
     FROM %s', col_type, p_col, p_col, p_col, p_col, p_col, p_col, p_col, p_col, p_table);
END $$;

CREATE OR REPLACE FUNCTION i18n_migrate_column(p_table regclass, p_col name, p_lang text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
  lang    text := COALESCE(p_lang, i18n_default_lang());
  typ     text;
  cname   text := p_col || '_i18n_check';
BEGIN
  SELECT t.typname INTO typ
  FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
  WHERE a.attrelid = p_table AND a.attname = p_col AND NOT a.attisdropped;

  IF typ IS NULL THEN
    RAISE EXCEPTION 'i18n_migrate_column: column %.% does not exist', p_table, p_col;
  END IF;

  IF typ IN ('text', 'varchar', 'bpchar') THEN
    -- 1. promote plain strings (anything that is not already a translation object)
    EXECUTE format(
      'UPDATE %s SET %I = jsonb_build_object(%L, %I::text)::text WHERE %I IS NOT NULL AND NOT i18n_is_json(%I::text)',
      p_table, p_col, lang, p_col, p_col, p_col);
    -- 2. change the column type; also drop a default that no longer makes sense for jsonb
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I DROP DEFAULT', p_table, p_col);
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I TYPE jsonb USING %I::jsonb', p_table, p_col, p_col);
  ELSIF typ = 'jsonb' THEN
    -- already jsonb: still promote bare strings / stray scalars
    EXECUTE format(
      'UPDATE %s SET %I = i18n_set(%I, %L, i18n_get(%I, %L, %L), %L) WHERE %I IS NOT NULL AND NOT i18n_is_json(%I)',
      p_table, p_col, p_col, lang, p_col, lang, lang, lang, p_col, p_col);
  ELSE
    RAISE EXCEPTION 'i18n_migrate_column: column %.% has type %, expected text/varchar/jsonb', p_table, p_col, typ;
  END IF;

  -- 3. keep it that way
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = p_table AND conname = cname) THEN
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', p_table, cname);
  END IF;
  EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%I IS NULL OR i18n_is_json(%I))',
                 p_table, cname, p_col, p_col);
END $$;

CREATE OR REPLACE FUNCTION i18n_migrate_table(p_table regclass, p_cols text[], p_lang text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY p_cols LOOP
    PERFORM i18n_migrate_column(p_table, c, p_lang);
  END LOOP;
END $$;

-- ---------------------------------------------------------------- search helpers
-- i18n_values(v)  : all translations as text[] (a plain string gives a 1-element array)
-- i18n_all(v)     : all translations joined by newline, for LIKE / trigram search
--                   across languages. IMMUTABLE, so it can be indexed with pg_trgm.

CREATE OR REPLACE FUNCTION i18n_values(v jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT CASE
    WHEN v IS NULL THEN NULL
    WHEN i18n_is_json(v) THEN (SELECT COALESCE(array_agg(value ORDER BY key), '{}') FROM jsonb_each_text(v))
    WHEN jsonb_typeof(v) = 'string' THEN ARRAY[v #>> '{}']
    ELSE ARRAY[v::text]
  END
$$;

CREATE OR REPLACE FUNCTION i18n_values(v text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
  SELECT CASE
    WHEN v IS NULL THEN NULL
    WHEN i18n_is_json(v) THEN i18n_values(v::jsonb)
    ELSE ARRAY[v]
  END
$$;

CREATE OR REPLACE FUNCTION i18n_all(v jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$ SELECT array_to_string(i18n_values(v), E'\n') $$;

CREATE OR REPLACE FUNCTION i18n_all(v text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$ SELECT array_to_string(i18n_values(v), E'\n') $$;

-- ---------------------------------------------------------------- transparent view layer
--
-- For an API that already reads and writes plain strings and cannot change:
--   ALTER TABLE products RENAME TO products_i18n;
--   SELECT i18n_wrap_table('products_i18n', '{name,description}', 'products');
-- Then the API keeps using "products" untouched; it only needs to run
--   SET i18n.lang = 'it'   (or SET LOCAL inside each transaction when pooled,
--   or ALTER ROLE api_user SET i18n.lang = 'it' for a fixed language).
-- Reads return the translation, writes update only that language in the JSON.

CREATE OR REPLACE FUNCTION i18n_view_trigger() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
  base     text   := TG_ARGV[0];            -- already-quoted base table name
  tcols    text[] := TG_ARGV[1]::text[];    -- translatable columns
  pkcols   text[] := TG_ARGV[2]::text[];    -- primary key columns
  allcols  text[];
  lang     text := i18n_lang();
  dflt     text := i18n_default_lang();
  c        text;
  parts    text[] := '{}';
  inscols  text[] := '{}';
  coltype  jsonb;                          -- column name -> type name
  newj     jsonb;
  ret      text;
  where_sql text;
  sql      text;
BEGIN
  SELECT array_agg(attname::text ORDER BY attnum) INTO allcols
  FROM pg_attribute
  WHERE attrelid = TG_RELID AND attnum > 0 AND NOT attisdropped;

  -- types of the BASE table (the view shows translatable columns as text)
  SELECT jsonb_object_agg(attname, format_type(atttypid, atttypmod)) INTO coltype
  FROM pg_attribute
  WHERE attrelid = base::regclass AND attnum > 0 AND NOT attisdropped;

  -- RETURNING list that yields a row shaped like the view
  SELECT string_agg(
           CASE WHEN col = ANY(tcols)
                THEN format('i18n_get(%I) AS %I', col, col)
                ELSE format('%I', col) END, ', ')
    INTO ret
  FROM unnest(allcols) AS col;

  SELECT string_agg(format('%I = ($2).%I', col, col), ' AND ')
    INTO where_sql
  FROM unnest(pkcols) AS col;

  IF TG_OP = 'INSERT' THEN
    newj := to_jsonb(NEW);
    FOREACH c IN ARRAY allcols LOOP
      -- leave out NULL columns that have a default (serial, now(), ...) so the default applies
      CONTINUE WHEN jsonb_typeof(newj -> c) = 'null'
        AND EXISTS (SELECT 1 FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
                    WHERE d.adrelid = base::regclass AND a.attname = c);
      inscols := inscols || c;
      parts := parts || CASE WHEN c = ANY(tcols)
        THEN format('i18n_set(NULL::%s, %L, ($1).%I, %L)', coltype ->> c, lang, c, dflt)
        ELSE format('($1).%I', c) END;
    END LOOP;
    sql := format('INSERT INTO %s (%s) SELECT %s RETURNING %s',
                  base,
                  (SELECT string_agg(format('%I', col), ', ') FROM unnest(inscols) col),
                  array_to_string(parts, ', '),
                  ret);
    EXECUTE sql INTO NEW USING NEW;
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    FOREACH c IN ARRAY allcols LOOP
      parts := parts || CASE WHEN c = ANY(tcols)
        -- only touch the JSON when the visible string actually changed
        THEN format('%I = CASE WHEN ($1).%I IS DISTINCT FROM ($2).%I '
                    'THEN i18n_set(%I, %L, ($1).%I, %L) ELSE %I END',
                    c, c, c, c, lang, c, dflt, c)
        ELSE format('%I = ($1).%I', c, c) END;
    END LOOP;
    sql := format('UPDATE %s SET %s WHERE %s RETURNING %s',
                  base, array_to_string(parts, ', '), where_sql, ret);
    EXECUTE sql INTO NEW USING NEW, OLD;
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    sql := format('DELETE FROM %s WHERE %s', base, where_sql);
    EXECUTE sql USING OLD, OLD;
    RETURN OLD;
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION i18n_wrap_table(p_table regclass, p_cols text[], p_view text)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
  pkcols  text[];
  sel     text;
  vschema text;
BEGIN
  SELECT array_agg(a.attname::text ORDER BY k.ord) INTO pkcols
  FROM pg_index i
  JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
  WHERE i.indrelid = p_table AND i.indisprimary;

  IF pkcols IS NULL THEN
    RAISE EXCEPTION 'i18n_wrap_table: % has no primary key', p_table;
  END IF;

  SELECT n.nspname INTO vschema
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = p_table;

  SELECT string_agg(
           CASE WHEN a.attname::text = ANY(p_cols)
                THEN format('i18n_get(%I) AS %I', a.attname, a.attname)
                ELSE format('%I', a.attname) END,
           ', ' ORDER BY a.attnum) INTO sel
  FROM pg_attribute a
  WHERE a.attrelid = p_table AND a.attnum > 0 AND NOT a.attisdropped;

  EXECUTE format('CREATE VIEW %I.%I AS SELECT %s FROM %s', vschema, p_view, sel, p_table);

  EXECUTE format(
    'CREATE TRIGGER i18n_write INSTEAD OF INSERT OR UPDATE OR DELETE ON %I.%I '
    'FOR EACH ROW EXECUTE PROCEDURE i18n_view_trigger(%L, %L, %L)',
    vschema, p_view, p_table::text, p_cols::text, pkcols::text);
END $$;
