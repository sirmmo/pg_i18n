#!/usr/bin/env python3
"""pg_i18n worker: fills missing translations using an external provider.

Claims jobs from the i18n_queue table (see i18n_auto.sql), asks a provider
for the translations and writes them back with i18n_queue_complete(), which
only fills languages that are still missing.

Configuration is by environment variables:

  PG_I18N_DSN            libpq connection string (or DATABASE_URL)
  PG_I18N_SCHEMA         schema pg_i18n is installed in, if not on the search_path
  PG_I18N_PROVIDER       default provider: deepl | google | openrouter | echo   (default: echo)
  PG_I18N_BATCH          jobs claimed per round                        (default: 10)
  PG_I18N_POLL           seconds between polls when idle               (default: 30)
  PG_I18N_MAX_ATTEMPTS   attempts before a job is marked 'error'       (default: 3)
  PG_I18N_STALE_MINUTES  requeue 'processing' jobs older than this     (default: 10)

  DEEPL_API_KEY          DeepL key; keys ending in ":fx" use the free endpoint
  DEEPL_API_URL          override endpoint (default chosen from the key)
  DEEPL_TARGET_MAP       e.g. "en=EN-GB,pt=PT-BR" for DeepL's regional targets
  DEEPL_FORMALITY        default | more | less | prefer_more | prefer_less

  GOOGLE_TRANSLATE_API_KEY  Google Cloud Translation API key (Basic / v2 API)
  GOOGLE_TRANSLATE_URL   (default: https://translation.googleapis.com/language/translate/v2)
  GOOGLE_TRANSLATE_FORMAT   text | html                     (default: text)

  OPENROUTER_API_KEY     OpenRouter key
  OPENROUTER_MODEL       model id                       (default: openai/gpt-4o-mini)
  OPENROUTER_URL         (default: https://openrouter.ai/api/v1/chat/completions)

Usage:  pg_i18n_worker.py            run forever (LISTEN/NOTIFY + polling)
        pg_i18n_worker.py --once     drain the queue and exit (cron friendly)
"""
import json
import logging
import os
import select
import socket
import sys
import time
import urllib.error
import urllib.request

import psycopg
from psycopg.rows import dict_row

log = logging.getLogger("pg_i18n")


# ---------------------------------------------------------------- providers

class ProviderError(Exception):
    """A failure that should be retried later (network, quota, bad output)."""


def _http_json(url, payload, headers, timeout=60):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:500]
        raise ProviderError(f"HTTP {e.code} from {url}: {body}") from None
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        raise ProviderError(f"{url}: {e}") from None


class EchoProvider:
    """Offline provider for tests and dry runs: '[it] source text'."""
    name = "echo"

    def translate(self, text, source_lang, target_langs, hint=None):
        return {lang: f"[{lang}] {text}" for lang in target_langs}


class DeepLProvider:
    name = "deepl"
    DEFAULT_TARGET_MAP = {"en": "EN-US", "pt": "PT-PT", "zh": "ZH-HANS"}

    def __init__(self):
        self.key = os.environ.get("DEEPL_API_KEY")
        if not self.key:
            raise SystemExit("DEEPL_API_KEY is not set")
        default_url = ("https://api-free.deepl.com/v2/translate" if self.key.endswith(":fx")
                       else "https://api.deepl.com/v2/translate")
        self.url = os.environ.get("DEEPL_API_URL", default_url)
        self.target_map = dict(self.DEFAULT_TARGET_MAP)
        for pair in filter(None, os.environ.get("DEEPL_TARGET_MAP", "").split(",")):
            k, v = pair.split("=", 1)
            self.target_map[k.strip().lower()] = v.strip()
        self.formality = os.environ.get("DEEPL_FORMALITY")

    def translate(self, text, source_lang, target_langs, hint=None):
        out = {}
        for lang in target_langs:
            payload = {"text": [text],
                       "source_lang": source_lang.split("-")[0].upper(),
                       "target_lang": self.target_map.get(lang.lower(), lang.upper())}
            if hint:
                payload["context"] = hint
            if self.formality:
                payload["formality"] = self.formality
            data = _http_json(self.url, payload, {"Authorization": f"DeepL-Auth-Key {self.key}"})
            try:
                out[lang] = data["translations"][0]["text"]
            except (KeyError, IndexError, TypeError):
                raise ProviderError(f"unexpected DeepL response: {json.dumps(data)[:300]}")
        return out


class GoogleTranslateProvider:
    """Google Cloud Translation, Basic edition (v2 REST API with an API key).

    Enable "Cloud Translation API" in the project and create an API key.
    The v2 API takes one target language per request; source languages are
    BCP-47 codes such as 'en', 'pt-BR', 'zh-CN'.
    """
    name = "google"

    def __init__(self):
        self.key = os.environ.get("GOOGLE_TRANSLATE_API_KEY")
        if not self.key:
            raise SystemExit("GOOGLE_TRANSLATE_API_KEY is not set")
        self.url = os.environ.get("GOOGLE_TRANSLATE_URL",
                                  "https://translation.googleapis.com/language/translate/v2")
        self.format = os.environ.get("GOOGLE_TRANSLATE_FORMAT", "text")

    def translate(self, text, source_lang, target_langs, hint=None):
        out = {}
        for lang in target_langs:
            payload = {"q": [text], "source": source_lang, "target": lang, "format": self.format}
            data = _http_json(self.url, payload, {"X-Goog-Api-Key": self.key})
            try:
                out[lang] = data["data"]["translations"][0]["translatedText"]
            except (KeyError, IndexError, TypeError):
                raise ProviderError(f"unexpected Google response: {json.dumps(data)[:300]}")
        return out


class OpenRouterProvider:
    name = "openrouter"

    def __init__(self):
        self.key = os.environ.get("OPENROUTER_API_KEY")
        if not self.key:
            raise SystemExit("OPENROUTER_API_KEY is not set")
        self.model = os.environ.get("OPENROUTER_MODEL", "openai/gpt-4o-mini")
        self.url = os.environ.get("OPENROUTER_URL", "https://openrouter.ai/api/v1/chat/completions")

    def translate(self, text, source_lang, target_langs, hint=None):
        system = (
            "You are a translation engine. Translate the user's text from language "
            f"'{source_lang}' into each of these languages: {', '.join(target_langs)}. "
            "Preserve placeholders, markup, numbers, line breaks and the tone of the original. "
            "Reply with ONLY a JSON object whose keys are exactly the requested language codes "
            "and whose values are the translations. No commentary, no code fences."
        )
        if hint:
            system += f"\nContext about the text: {hint}"
        payload = {"model": self.model,
                   "messages": [{"role": "system", "content": system},
                                {"role": "user", "content": text}],
                   "temperature": 0.2}
        data = _http_json(self.url, payload, {"Authorization": f"Bearer {self.key}",
                                              "HTTP-Referer": "https://github.com/sirmmo/pg_i18n",
                                              "X-Title": "pg_i18n worker"})
        try:
            content = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError):
            raise ProviderError(f"unexpected OpenRouter response: {json.dumps(data)[:300]}")
        parsed = _parse_json_object(content)
        out = {lang: parsed[lang] for lang in target_langs
               if isinstance(parsed.get(lang), str) and parsed[lang].strip()}
        if not out:
            raise ProviderError(f"model returned no usable translations: {content[:300]}")
        return out


def _parse_json_object(content):
    s = content.strip()
    if s.startswith("```"):
        s = s.strip("`")
        if s.startswith("json"):
            s = s[4:]
    start, end = s.find("{"), s.rfind("}")
    if start < 0 or end < 0:
        raise ProviderError(f"no JSON object in model output: {content[:300]}")
    try:
        obj = json.loads(s[start:end + 1])
    except json.JSONDecodeError as e:
        raise ProviderError(f"invalid JSON from model: {e}: {content[:300]}")
    if not isinstance(obj, dict):
        raise ProviderError("model output is not a JSON object")
    return obj


PROVIDERS = {"echo": EchoProvider, "deepl": DeepLProvider, "google": GoogleTranslateProvider,
             "openrouter": OpenRouterProvider}


# ---------------------------------------------------------------- worker

class Worker:
    def __init__(self):
        dsn = os.environ.get("PG_I18N_DSN") or os.environ.get("DATABASE_URL")
        if not dsn:
            raise SystemExit("PG_I18N_DSN (or DATABASE_URL) is not set")
        self.conn = psycopg.connect(dsn, autocommit=True, row_factory=dict_row)
        schema = os.environ.get("PG_I18N_SCHEMA")
        if schema:
            self.conn.execute(psycopg.sql.SQL("SET search_path TO {}, public").format(psycopg.sql.Identifier(schema)))
        self.default_provider = os.environ.get("PG_I18N_PROVIDER", "echo")
        self.batch = int(os.environ.get("PG_I18N_BATCH", "10"))
        self.poll = float(os.environ.get("PG_I18N_POLL", "30"))
        self.max_attempts = int(os.environ.get("PG_I18N_MAX_ATTEMPTS", "3"))
        self.stale_minutes = int(os.environ.get("PG_I18N_STALE_MINUTES", "10"))
        self.worker_id = f"{socket.gethostname()}:{os.getpid()}"
        self._providers = {}

    def provider(self, name):
        name = name or self.default_provider
        if name not in self._providers:
            cls = PROVIDERS.get(name)
            if cls is None:
                raise ProviderError(f"unknown provider '{name}' (known: {', '.join(PROVIDERS)})")
            self._providers[name] = cls()
        return self._providers[name]

    def requeue_stale(self):
        n = self.conn.execute("SELECT i18n_queue_requeue_stale(%s::interval)",
                              (f"{self.stale_minutes} minutes",)).fetchone()
        n = list(n.values())[0]
        if n:
            log.warning("requeued %d stale job(s)", n)

    def process_batch(self):
        """Claim and process one batch. Returns the number of jobs claimed."""
        jobs = self.conn.execute("SELECT * FROM i18n_queue_claim(%s, %s)",
                                 (self.batch, self.worker_id)).fetchall()
        for job in sorted(jobs, key=lambda j: j["id"]):
            self.process(job)
        return len(jobs)

    def process(self, job):
        jid = job["id"]
        try:
            prov = self.provider(job["provider"])
            translations = prov.translate(job["source_text"], job["source_lang"],
                                          list(job["target_langs"]), job["hint"])
            self.conn.execute("SELECT i18n_queue_complete(%s, %s::jsonb)", (jid, json.dumps(translations)))
            log.info("job %s: %s.%s %s -> %s via %s", jid, job["tbl"], job["col"],
                     job["source_lang"], ",".join(translations), prov.name)
        except ProviderError as e:
            self.conn.execute("SELECT i18n_queue_fail(%s, %s, %s)", (jid, str(e)[:2000], self.max_attempts))
            log.error("job %s failed (attempt %d): %s", jid, job["attempts"], e)
        except psycopg.Error as e:
            # the write-back itself failed (constraint, dropped table, ...): record it and move on
            self.conn.execute("SELECT i18n_queue_fail(%s, %s, %s)", (jid, f"db: {e}"[:2000], self.max_attempts))
            log.error("job %s: database error: %s", jid, e)

    def drain(self):
        while self.process_batch():
            pass

    def run_forever(self):
        # Notifications are only a wake-up signal; the queue table is the truth.
        self.conn.add_notify_handler(lambda n: None)
        self.conn.execute("LISTEN i18n_queue")
        last_stale = 0
        while True:
            if time.time() - last_stale > 60:
                self.requeue_stale()
                last_stale = time.time()
            self.drain()
            # sleep until a NOTIFY arrives or the poll interval elapses
            r, _, _ = select.select([self.conn.fileno()], [], [], self.poll)
            if r:
                self.conn.execute("SELECT 1")   # reads the socket, dispatches notifications


def main(argv):
    logging.basicConfig(level=os.environ.get("PG_I18N_LOG", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    w = Worker()
    log.info("worker %s, default provider %s", w.worker_id, w.default_provider)
    if "--once" in argv:
        w.requeue_stale()
        w.drain()
        return 0
    try:
        w.run_forever()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
