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
            resp = {"translations": [{"detected_source_language": "EN",
                                      "text": f"deepl:{body['target_lang']}:{body['text'][0]}"}]}
        elif self.path.startswith("/google"):
            resp = {"data": {"translations": [{"translatedText": f"google:{body['target']}:{body['q'][0]}"}]}}
        elif self.path.startswith("/openrouter"):
            langs = [l.strip() for l in body["messages"][0]["content"].split("languages:")[1].split(".")[0].split(",")]
            obj = {l: f"llm:{l}:{body['messages'][1]['content']}" for l in langs}
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

    r = w.DeepLProvider().translate("Hello", "en", ["it", "en"], hint="greeting")
    assert r == {"it": "deepl:IT:Hello", "en": "deepl:EN-GB:Hello"}, r
    path, headers, body = REQUESTS[-1]
    assert headers["Authorization"] == "DeepL-Auth-Key k:fx" and body["context"] == "greeting", (headers, body)

    r = w.GoogleTranslateProvider().translate("Hello", "en", ["it", "de"])
    assert r == {"it": "google:it:Hello", "de": "google:de:Hello"}, r
    path, headers, body = REQUESTS[-1]
    assert headers["X-Goog-Api-Key"] == "gk" and body == {"q": ["Hello"], "source": "en", "target": "de", "format": "text"}, body

    r = w.OpenRouterProvider().translate("Hello", "en", ["it", "de"], hint="a greeting")
    assert r == {"it": "llm:it:Hello", "de": "llm:de:Hello"}, r
    path, headers, body = REQUESTS[-1]
    assert headers["Authorization"] == "Bearer ok" and body["model"] == "test/model"
    assert "a greeting" in body["messages"][0]["content"]

    os.environ["DEEPL_API_URL"] = base + "/fail"
    try:
        w.DeepLProvider().translate("x", "en", ["it"])
        raise AssertionError("expected ProviderError")
    except w.ProviderError as e:
        assert "HTTP 456" in str(e) and "quota" in str(e), e

    assert w._parse_json_object('Sure! {"it": "Ciao"} hope this helps') == {"it": "Ciao"}
    assert w.EchoProvider().translate("Hi", "en", ["fr"]) == {"fr": "[fr] Hi"}
    print("providers OK (%d mock requests)" % len(REQUESTS))


if __name__ == "__main__":
    main()
