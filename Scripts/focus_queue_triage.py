#!/usr/bin/env python3
"""Heuristic pre-classification for collected daily-report messages.

Each message is labeled promotional, automated, direct, or ambiguous and given
an importance score (higher = more important). The daily report excludes
promotional and automated mail from the LLM classification stage and orders the
remainder by this score before recency.
"""

from __future__ import annotations

import re
from email.utils import getaddresses, parseaddr
from typing import Any


PROMOTIONAL = "promotional"
AUTOMATED = "automated"
DIRECT = "direct"
AMBIGUOUS = "ambiguous"
EXCLUDED_CATEGORIES = {PROMOTIONAL, AUTOMATED}

BULK_LOCALPARTS = {
    "no-reply",
    "noreply",
    "no_reply",
    "donotreply",
    "do-not-reply",
    "newsletter",
    "newsletters",
    "marketing",
    "promo",
    "promotions",
    "offers",
    "deals",
}
AUTOMATED_LOCALPARTS = {
    "mailer-daemon",
    "postmaster",
    "notifications",
    "notification",
    "notify",
    "bounce",
    "bounces",
}
MARKETING_PHRASES = (
    "unsubscribe",
    "view in browser",
    "view this email in your browser",
    "manage your preferences",
    "email preferences",
    "update your preferences",
    "% off",
    "sale ends",
    "limited time",
    "special offer",
)
BULK_PRECEDENCE = {"bulk", "list", "junk"}
PROMOTIONAL_LABELS = {"CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"}
AUTOMATED_LABELS = {"CATEGORY_UPDATES"}
JUNK_MAILBOXES = {"junk", "spam"}
THREAD_PREFIX = re.compile(r"^\s*(re|fwd?)\s*:", re.IGNORECASE)


def _addresses(values: Any) -> set[str]:
    if isinstance(values, str):
        values = [values]
    if not isinstance(values, list):
        return set()
    return {
        address.lower()
        for _, address in getaddresses([str(value) for value in values])
        if address
    }


def classify_message(
    message: dict[str, Any],
    *,
    user_addresses: frozenset[str] | set[str] = frozenset(),
    known_domains: frozenset[str] | set[str] = frozenset(),
) -> dict[str, Any]:
    headers = message.get("headers") if isinstance(message.get("headers"), dict) else {}
    labels = {str(value).upper() for value in message.get("labels") or []}
    sender_address = parseaddr(
        str(headers.get("from") or message.get("senderAddress") or message.get("sender") or "")
    )[1].lower()
    localpart, _, domain = sender_address.partition("@")
    subject = str(message.get("subject") or message.get("title") or "")
    text = f"{subject}\n{message.get('text') or ''}".casefold()

    promotional = 0
    direct = 0
    automated = False

    if headers.get("listUnsubscribe"):
        promotional += 2
    if str(headers.get("precedence") or "").strip().lower() in BULK_PRECEDENCE:
        promotional += 2
    auto_submitted = str(headers.get("autoSubmitted") or "").strip().lower()
    if auto_submitted and auto_submitted != "no":
        automated = True
    if localpart in BULK_LOCALPARTS:
        promotional += 1
    if localpart in AUTOMATED_LOCALPARTS:
        automated = True
    promotional += min(3, sum(1 for phrase in MARKETING_PHRASES if phrase in text))
    if labels & PROMOTIONAL_LABELS:
        promotional += 3
    if labels & AUTOMATED_LABELS:
        automated = True
    if str(message.get("mailbox") or "").strip().lower() in JUNK_MAILBOXES:
        promotional += 3

    if _addresses(headers.get("to")) & user_addresses:
        direct += 3
    elif _addresses(headers.get("cc")) & user_addresses:
        direct += 1
    if THREAD_PREFIX.match(subject):
        direct += 1
    if domain and domain in known_domains:
        direct += 3
    if message.get("flagged"):
        direct += 2

    if automated and direct < 3:
        category = AUTOMATED
    elif promotional >= 3 and direct < 4:
        category = PROMOTIONAL
    elif direct >= 2:
        category = DIRECT
    else:
        category = AMBIGUOUS
    return {"category": category, "score": direct - promotional}


def triage_messages(
    messages: list[dict[str, Any]],
    config: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    user_addresses = {
        str(value).strip().lower()
        for value in (config.get("emailAddresses") or [config.get("emailAddress") or ""])
        if str(value).strip()
    }
    known_domains = {
        str(value).strip().lower()
        for value in config.get("knownSenderDomains") or []
        if str(value).strip()
    }
    results: dict[str, dict[str, Any]] = {}
    for message in messages:
        source_key = str(message.get("sourceKey") or "")
        if not source_key:
            continue
        results[source_key] = classify_message(
            message,
            user_addresses=user_addresses,
            known_domains=known_domains,
        )
    return results
