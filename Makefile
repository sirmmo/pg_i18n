EXTENSION  = pg_i18n
EXTVERSION = $(shell grep default_version $(EXTENSION).control | sed -E "s/.*'([^']+)'.*/\1/")

DATA_built = $(EXTENSION)--$(EXTVERSION).sql
EXTRA_CLEAN = $(DATA_built)

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# The extension script is the standalone i18n.sql with the usual guard on top,
# so there is a single source of truth for both install methods.
$(EXTENSION)--$(EXTVERSION).sql: i18n.sql i18n_auto.sql
	printf '\\echo Use "CREATE EXTENSION %s" to load this file. \\quit\n\n' $(EXTENSION) > $@
	cat $^ >> $@

test:
	./test.sh

test-ext:
	EXT=1 ./test.sh

test-worker:
	./worker/test_worker.sh

.PHONY: test test-ext test-worker
