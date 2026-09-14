#!/usr/bin/env sh
# Run test.sql against a throwaway PostgreSQL container.
# Usage: ./test.sh [postgres image]   (default: postgres:16-alpine)
set -eu
IMAGE="${1:-postgres:16-alpine}"
NAME="pg_i18n_test_$$"
HERE="$(cd "$(dirname "$0")" && pwd)"

docker run -d --rm --name "$NAME" -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v "$HERE:/pg_i18n:ro" "$IMAGE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null' EXIT

i=0
until docker exec "$NAME" pg_isready -U postgres -q; do
  i=$((i+1)); [ "$i" -lt 30 ] || { echo "postgres did not start"; exit 1; }
  sleep 1
done

docker exec "$NAME" psql -U postgres -q -c 'CREATE DATABASE t' >/dev/null
docker exec -w /pg_i18n "$NAME" psql -U postgres -d t -v ON_ERROR_STOP=1 -f /pg_i18n/test.sql "$@" >/dev/null 2>"$HERE/.test.err" \
  && echo "OK ($IMAGE)" \
  || { echo "FAILED ($IMAGE)"; cat "$HERE/.test.err"; exit 1; }
rm -f "$HERE/.test.err"
