from __future__ import annotations

import re

SECRET_PATTERNS = [
    re.compile(r"(password\s*[=:]\s*)([^\s,;]+)", re.IGNORECASE),
    re.compile(r"(token\s*[=:]\s*)([^\s,;]+)", re.IGNORECASE),
    re.compile(r"(secret\s*[=:]\s*)([^\s,;]+)", re.IGNORECASE),
    re.compile(r"(authorization\s*[=:]\s*)([^\s,;]+)", re.IGNORECASE),
    re.compile(r"(-----BEGIN (?:(?:[A-Z]+ )*)PRIVATE KEY-----)(.*?)(-----END (?:(?:[A-Z]+ )*)PRIVATE KEY-----)", re.DOTALL),
]

REDACTED = "[REDACTED]"


def redact(text: str) -> str:
    redacted = text
    for pat in SECRET_PATTERNS:
        if "PRIVATE KEY" in pat.pattern:
            redacted = pat.sub(lambda m: m.group(1) + "\n" + REDACTED + "\n" + m.group(3), redacted)
        else:
            redacted = pat.sub(lambda m: m.group(1) + REDACTED, redacted)
    return redacted
