#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
REAL end-to-end test: Papuga prompt -> local Ollama (qwen3:4b, schema-constrained)
-> the SAME validator from verify_roundtrip.py.

Run after `ollama pull qwen3:4b` and `ollama serve`:
    python3 run_ollama_test.py
"""
import json, urllib.request, sys
from verify_roundtrip import build_prompt, report, MISTAKES

# strict schema handed to Ollama's request-level "format" (constrains decoding)
SCHEMA = {
    "type": "object",
    "properties": {
        "version": {"type": "integer"},
        "suggestions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "action": {"type": "string", "enum": ["rule", "dictionary", "ignore", "merge"]},
                    "target": {"type": ["string", "null"]},
                    "tag": {"type": "string", "enum": ["layout", "spelling", "domain", "confusable", "gibberish"]},
                    "clusterId": {"type": ["string", "null"]},
                    "confidence": {"type": "number"},
                    "reason": {"type": "string"},
                },
                "required": ["id", "action", "target", "tag", "clusterId", "confidence", "reason"],
            },
        },
    },
    "required": ["version", "suggestions"],
}

MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen3:4b"
prompt = build_prompt()
body = {
    "model": MODEL,
    "stream": False,
    "options": {"temperature": 0},
    "format": SCHEMA,
    "messages": [
        {"role": "system", "content": "Ти класифікуєш помилки введення українця-розробника. /no_think Відповідай ЛИШЕ JSON за схемою."},
        {"role": "user", "content": prompt},
    ],
}

print(f"→ Викликаю {MODEL} локально (перший виклик вантажить модель у памʼять)…")
req = urllib.request.Request(
    "http://localhost:11434/api/chat",
    data=json.dumps(body).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)
resp = json.load(urllib.request.urlopen(req, timeout=600))
content = resp["message"]["content"]
ms = resp.get("total_duration", 0) / 1e9

print(f"\n── СИРИЙ ВИВІД {MODEL} ({ms:.1f}s) ──\n{content}\n")
report(f"{MODEL} (локально, реальний виклик)", content)
