"""Explicit bounded text artifacts for D's WASI Python guest; no filesystem writes."""
import json
import sys


def publish(name, kind, text):
    """Offer a text/csv/svg result. The host validates it; the user chooses whether to save."""
    if not isinstance(name, str) or not isinstance(text, str) or kind not in ("plainText", "csv", "svg"):
        raise ValueError("Expected a filename, a supported text kind, and text content.")
    sys.stdout.write("D_CHAT_FILE_V1:" + json.dumps({"name": name, "kind": kind, "text": text},
                                                 ensure_ascii=False, separators=(",", ":")) + "\n")
