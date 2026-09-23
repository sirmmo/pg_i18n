#!/usr/bin/env python3
"""Offline checks of the provider request/response handling against a mock HTTP server."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(__file__))
import pg_i18n_worker as w  # noqa: E402

REQUESTS = []


class Mock(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        REQUESTS.append((self.path, dict(self.headers), body))
        if self.path.startswith("/deepl"):
            resp = {"translations": [{"detected_source_language": "FR",
                                      "text": f"deepl:{body['target_lang']}:{body['text'][0]}"}]}
        elif self.path.startswith("/google"):
            tr = {"translatedText": f"google:{body['target']}:{body['q'][0]}"}
            if "source" not in body:
                tr["detectedSourceLanguage"] = "fr"
            resp = {"data": {"translations": [tr]}}
        elif self.path.startswith("/openrouter"):
            sysmsg = body["messages"][0]["content"]
            langs = [l.strip() for l in sysmsg.split("languages:")[1].split(".")[0].split(",")]
            obj = {l: f"llm:{l}:{body['messages'][1]['content']}" for l in langs}
            if '"detected"' in sysmsg:
                obj = {"detected": "fr", "translations": obj}
            resp = {"choices": [{"message": {"content": "```json\n" + json.dumps(obj) + "\n```"}}]}
        elif self.path.startswith("/fail"):
            self.send_response(456); self.end_headers(); self.wfile.write(b"quota exceeded"); return
        else:
            resp = {}
        out = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


def main():
    srv = HTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"

    os.environ.update({
        "DEEPL_API_KEY": "k:fx", "DEEPL_API_URL": base + "/deepl", "DEEPL_TARGET_MAP": "en=EN-GB",
        "GOOGLE_TRANSLATE_API_KEY": "gk", "GOOGLE_TRANSLATE_URL": base + "/google",
        "OPENROUTER_API_KEY": "ok", "OPENROUTER_URL": base + "/openrouter", "OPENROUTER_MODEL": "test/model",
    })

    r, d = w.DeepLProvider().translate("Hello", "en", ["it", "en"], hint="greeting")
    assert r == {"it": "deepl:IT:Hello", "en": "deepl:EN-GB:Hello"} and d is None, (r, d)
    path, headers, body = REQUESTS[-1]
    assert headers["Authorization"] == "DeepL-Auth-Key k:fx" and body["context"] == "greeting", (headers, body)
    assert body["source_lang"] == "EN"
    r, d = w.DeepLProvider().translate("Bonjour", "en", ["it"], detect=True)
    assert d == "fr" and "source_lang" not in REQUESTS[-1][2], (d, REQUESTS[-1][2])

    r, d = w.GoogleTranslateProvider().translate("Hello", "en", ["it", "de"])
    assert r == {"it": "google:it:Hello", "de": "google:de:Hello"} and d is None, (r, d)
    path, headers, body = REQUESTS[-1]
    assert headers["X-Goog-Api-Key"] == "gk" and body == {"q": ["Hello"], "source": "en", "target": "de", "format": "text"}, body
    r, d = w.GoogleTranslateProvider().translate("Bonjour", "en", ["it"], detect=True)
    assert d == "fr" and "source" not in REQUESTS[-1][2], (d, REQUESTS[-1][2])

    r, d = w.OpenRouterProvider().translate("Hello", "en", ["it", "de"], hint="a greeting")
    assert r == {"it": "llm:it:Hello", "de": "llm:de:Hello"} and d is None, (r, d)
    path, headers, body = REQUESTS[-1]
    assert headers["Authorization"] == "Bearer ok" and body["model"] == "test/model"
    assert "a greeting" in body["messages"][0]["content"]
    r, d = w.OpenRouterProvider().translate("Bonjour", "en", ["it"], detect=True)
    assert r == {"it": "llm:it:Bonjour"} and d == "fr", (r, d)

    # code normalization against the configured languages
    assert w.normalize_lang("EN", ["en", "it"]) == "en"
    assert w.normalize_lang("en", ["en-GB", "it"]) == "en-GB"
    assert w.normalize_lang("zh-CN", ["zh", "en"]) == "zh"
    assert w.normalize_lang("pt-BR", ["pt-PT", "pt-BR"]) == "pt-BR"
    assert w.normalize_lang("fr", ["en", "it"]) == "fr"
    assert w.same_language("en-GB", "en") and not w.same_language("en", "it")

    # job planning with provider detection: text stored under 'it' is actually French
    class Fake:
        name = "fake"
        def __init__(self): self.calls = []
        def translate(self, text, src, targets, hint=None, detect=False):
            self.calls.append((src, list(targets), detect))
            return {t: f"{src}>{t}" for t in targets}, ("fr" if detect else None)
    wk = w.Worker.__new__(w.Worker); wk.detect_mode = "provider"
    fake = Fake()
    job = {"source_text": "Bonjour", "source_lang": "it", "target_langs": ["en", "de"],
           "langs": ["en", "it", "de"], "hint": None, "detect": True}
    tr, det = wk.translate_job(fake, job)
    assert det == "fr" and tr == {"en": "it>en", "de": "it>de", "it": "fr>it"}, (tr, det)
    assert fake.calls == [("it", ["en", "de"], True), ("fr", ["it"], False)], fake.calls
    # detection agreeing with the stored language: nothing moves
    class Agree(Fake):
        def translate(self, text, src, targets, hint=None, detect=False):
            return super().translate(text, src, targets, hint, detect)[0], "IT"
    tr, det = wk.translate_job(Agree(), job)
    assert det is None and tr == {"en": "it>en", "de": "it>de"}, (tr, det)
    # detect not enabled on the job: plain path
    tr, det = wk.translate_job(Fake(), dict(job, detect=False))
    assert det is None and tr == {"en": "it>en", "de": "it>de"}

    os.environ["DEEPL_API_URL"] = base + "/fail"
    try:
        w.DeepLProvider().translate("x", "en", ["it"])
        raise AssertionError("expected ProviderError")
    except w.ProviderError as e:
        assert "HTTP 456" in str(e) and "quota" in str(e), e

    assert w._parse_json_object('Sure! {"it": "Ciao"} hope this helps') == {"it": "Ciao"}
    assert w.EchoProvider().translate("Hi", "en", ["fr"]) == ({"fr": "[fr] Hi"}, None)
    assert w.EchoProvider().translate("fr:Salut", "en", ["it"], detect=True)[1] == "fr"
    print("providers OK (%d mock requests)" % len(REQUESTS))


if __name__ == "__main__":
    main()
