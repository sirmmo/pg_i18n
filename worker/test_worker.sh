#!/usr/bin/env sh
# End-to-end test: postgres + worker containers, offline "echo" provider.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
NET="pg_i18n_net_$$"; PG="pg_i18n_pg_$$"; IMG="pg_i18n_worker:test"

docker network create "$NET" >/dev/null
docker run -d --rm --name "$PG" --network "$NET" -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v "$ROOT:/pg_i18n:ro" postgres:16-alpine >/dev/null
trap 'docker rm -f "$PG" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1' EXIT
docker build -q -t "$IMG" "$HERE" >/dev/null
docker run --rm --entrypoint python -v "$HERE:/t:ro" "$IMG" /t/test_providers.py

until docker exec "$PG" pg_isready -U postgres -q; do sleep 1; done
docker exec -w /pg_i18n "$PG" psql -U postgres -v ON_ERROR_STOP=1 -q -f i18n.sql -f i18n_auto.sql
docker exec -i "$PG" psql -U postgres -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE TABLE articles (id serial PRIMARY KEY, title text, body jsonb);
INSERT INTO articles (title, body) VALUES ('Hello', '{"en":"World","it":"Mondo"}'), ('{"fr":"Salut"}', NULL);
SELECT i18n_auto_enable('articles', 'title', '{en,it,de}');
SELECT i18n_auto_enable('articles', 'body',  '{en,it,de}', NULL, 'echo', 'article bodies');
SELECT i18n_backfill('articles', 'title'), i18n_backfill('articles', 'body');
INSERT INTO articles (title) VALUES ('Inserted later');
-- detection: echo reports 'xx:' prefixes as the language
CREATE TABLE notes (id serial PRIMARY KEY, txt text);
SELECT i18n_auto_enable('notes', 'txt', '{en,it}', NULL, 'echo', NULL, true);
INSERT INTO notes (txt) VALUES ('fr:Bonjour'), ('en:Hello'), ('{"it":"de:Hallo"}');
SQL

docker run --rm --network "$NET" -e PG_I18N_DSN="postgresql://postgres@$PG/postgres" \
  -e PG_I18N_PROVIDER=echo "$IMG" --once

docker exec "$PG" psql -U postgres -At -c "SELECT id, title, body FROM articles ORDER BY id" \
                                       -c "SELECT id, txt FROM notes ORDER BY id" \
                                       -c "SELECT status, count(*) FROM i18n_queue GROUP BY 1 ORDER BY 1"
