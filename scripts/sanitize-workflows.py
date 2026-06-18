#!/usr/bin/env python3
"""Sanitize n8n workflow exports for public git (no secrets, no PII)."""
from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "workflows" / "export-real"
OUT = ROOT / "workflows" / "export"

# Real token found in exports — scrub everywhere
BOT_TOKEN_RE = re.compile(r"bot\d{8,10}:[A-Za-z0-9_-]{20,}")
CHAT_ID_HARDCODED = "274609118"

NAME_MAP = {
    "WF-01 Ingest & Transcribe": "WF-01-ingest-transcribe.json",
    "WF-02 Analyze": "WF-02-analyze.json",
    "WF-03 Notify Employee": "WF-03-notify-employee.json",
    "WF-04: Notify Regional": "WF-04-notify-regional.json",
    "WF-05 Training Gate": "WF-05-training-gate.json",
    "WF-06 Coach": "WF-06-coach.json",
    "WF-07 Memory Write": "WF-07-write-memory.json",
    "WF-08 Kaizen": "WF-08-kaizen.json",
    "WF-09": "WF-09-dashboard-feed.json",
}

SKIP_NAMES = {"My workflow"}

STRIP_TOP_KEYS = {
    "id",
    "createdAt",
    "updatedAt",
    "versionId",
    "activeVersionId",
    "versionCounter",
    "triggerCount",
    "shared",
    "sourceWorkflowId",
    "versionMetadata",
    "isArchived",
    "description",
    "active",
    "meta",
    "pinData",
    "staticData",
}

TELEGRAM_METHODS = {
    "sendMessage": "sendMessage",
    "answerCallbackQuery": "answerCallbackQuery",
}


def scrub_string(text: str) -> str:
    if not isinstance(text, str):
        return text

    # Bot token in URLs (regex leaves .../bot<TOKEN>/ → .../<TOKEN>/)
    text = BOT_TOKEN_RE.sub("<TOKEN>", text)
    for method in ("sendMessage", "answerCallbackQuery"):
        expr = f"={{{{ 'https://api.telegram.org/bot' + $env.TELEGRAM_BOT_TOKEN + '/{method}' }}}}"
        text = text.replace(f"https://api.telegram.org/bot<TOKEN>/{method}", expr)
        text = text.replace(f"https://api.telegram.org/<TOKEN>/{method}", expr)

    # Internal n8n webhooks — use container hostname
    text = text.replace("http://127.0.0.1:5678/webhook/", "http://localhost:5678/webhook/")
    text = text.replace("http://localhost:5678/webhook/", "={{ $env.N8N_WEBHOOK_BASE || 'http://localhost:5678/webhook/' }}")

    # Hardcoded pilot chat_id fallback
    text = text.replace(f"'{CHAT_ID_HARDCODED}'", "String($env.SEED_REGIONAL_TELEGRAM_CHAT_ID || '0')")
    text = text.replace(f'"{CHAT_ID_HARDCODED}"', "String($env.SEED_REGIONAL_TELEGRAM_CHAT_ID || '0')")
    text = text.replace(
        f"|| '{CHAT_ID_HARDCODED}'",
        "|| String($env.SEED_EMPLOYEE_TELEGRAM_CHAT_ID || '0')",
    )

    # Email from n8n project metadata leaking into exports
    text = re.sub(r"greenbeesy@gmail\.com", "user@example.com", text)

    return text


def scrub_obj(obj):
    if isinstance(obj, dict):
        return {k: scrub_obj(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub_obj(v) for v in obj]
    if isinstance(obj, str):
        return scrub_string(obj)
    return obj


def normalize_credentials(node: dict) -> None:
    creds = node.get("credentials") or {}
    if "postgres" in creds:
        creds["postgres"] = {
            "id": "__POSTGRES_CRED_ID__",
            "name": "Sales Flow Postgres",
        }
    if "telegramApi" in creds:
        creds["telegramApi"] = {
            "id": "__TELEGRAM_CRED_ID__",
            "name": "Telegram Bot",
        }
    if creds:
        node["credentials"] = creds


def prepare_workflow(raw: dict) -> dict:
    wf = scrub_obj(raw)
    for key in STRIP_TOP_KEYS:
        wf.pop(key, None)

    wf["active"] = False
    wf["settings"] = wf.get("settings") or {"executionOrder": "v1"}
    wf["meta"] = {"templateCredsSetupCompleted": True}
    wf["tags"] = [{"name": "sales-flow"}]

    for node in wf.get("nodes", []):
        normalize_credentials(node)
        params = node.get("parameters") or {}
        url = params.get("url")
        if isinstance(url, str) and ("<TOKEN>" in url or "bot<TOKEN>" in url):
            if "answerCallbackQuery" in url:
                params["url"] = "={{ 'https://api.telegram.org/bot' + $env.TELEGRAM_BOT_TOKEN + '/answerCallbackQuery' }}"
            else:
                params["url"] = "={{ 'https://api.telegram.org/bot' + $env.TELEGRAM_BOT_TOKEN + '/sendMessage' }}"

    # Broken rename in pilot export (HTTP Request1 → TG Answer Skip)
    conns = wf.get("connections") or {}
    for src, branches in conns.items():
        if not isinstance(branches, dict):
            continue
        for branch in branches.values():
            if not isinstance(branch, list):
                continue
            for lane in branch:
                if not isinstance(lane, list):
                    continue
                for link in lane:
                    if isinstance(link, dict) and link.get("node") == "HTTP Request1":
                        link["node"] = "TG Answer Skip"

    return wf


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"Missing source exports: {SRC}")

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    exported = 0
    for path in sorted(SRC.glob("*.json")):
        raw = json.loads(path.read_text(encoding="utf-8"))
        name = raw.get("name", path.stem)
        if name in SKIP_NAMES:
            print(f"skip: {name}")
            continue
        out_name = NAME_MAP.get(name)
        if not out_name:
            raise SystemExit(f"Unknown workflow name: {name}")
        clean = prepare_workflow(raw)
        out_path = OUT / out_name
        out_path.write_text(json.dumps(clean, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        exported += 1
        print(f"ok: {name} -> {out_name}")

    # Safety scan
    blob = "\n".join(p.read_text(encoding="utf-8") for p in OUT.glob("*.json"))
    if BOT_TOKEN_RE.search(blob):
        raise SystemExit("FAIL: bot token still present after sanitize")
    if CHAT_ID_HARDCODED in blob:
        raise SystemExit("FAIL: hardcoded chat_id still present")
    if "greenbeesy@gmail.com" in blob:
        raise SystemExit("FAIL: email still present")

    print(f"\nSanitized {exported} workflows -> {OUT}")


if __name__ == "__main__":
    main()
