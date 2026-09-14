#!/usr/bin/env sh
# Run test.sql against a throwaway PostgreSQL container.
# Usage: ./test.sh [postgres image]      (default: postgres:16-alpine)
#        EXT=1 ./test.sh                  build + install the extension with PGXS and
#                                         load it via CREATE EXTENSION instead of \i
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

PSQL_ARGS=""
if [ "${EXT:-0}" = "1" ]; then
  # copy the source out of the read-only mount, build and install with PGXS
  docker exec "$NAME" sh -c 'apk add --no-cache make >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq make >/dev/null)'
  docker exec "$NAME" sh -c 'cp -r /pg_i18n /build && cd /build && make install >/dev/null'
  PSQL_ARGS="-v use_ext=1"
fi

docker exec "$NAME" psql -U postgres -q -c 'CREATE DATABASE t' >/dev/null
docker exec -w /pg_i18n "$NAME" psql -U postgres -d t -v ON_ERROR_STOP=1 $PSQL_ARGS -f test.sql >/dev/null 2>"$HERE/.test.err" \
  && echo "OK ($IMAGE${EXT:+, extension})" \
  || { echo "FAILED ($IMAGE${EXT:+, extension})"; cat "$HERE/.test.err"; exit 1; }
rm -f "$HERE/.test.err"
