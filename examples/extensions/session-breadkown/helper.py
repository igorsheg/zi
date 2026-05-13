#!/usr/bin/env python3
"""Compute zi session usage aggregates for the session-breadkown extension."""

from __future__ import annotations

import json
import math
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

RANGE_DAYS = (7, 30, 90)
DOW_NAMES = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
TOD_BUCKETS = (
    ("after-midnight", "After midnight (0-5)", 0, 5),
    ("morning", "Morning (6-11)", 6, 11),
    ("afternoon", "Afternoon (12-16)", 12, 16),
    ("evening", "Evening (17-21)", 17, 21),
    ("night", "Night (22-23)", 22, 23),
)


def parse_ts(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value).astimezone()
    except Exception:
        return None


def parse_start_from_name(path: Path) -> datetime | None:
    # 2026-05-05T07-11-02-000Z_uuid.jsonl
    name = path.name
    if len(name) < 24 or name[10] != "T":
        return None
    stamp = name[:24]
    try:
        iso = f"{stamp[:13]}:{stamp[14:16]}:{stamp[17:19]}.{stamp[20:23]}+00:00"
        return datetime.fromisoformat(iso).astimezone()
    except Exception:
        return None


def day_key(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d")


def tod_key(hour: int) -> str:
    for key, _label, start, end in TOD_BUCKETS:
        if start <= hour <= end:
            return key
    return "after-midnight"


def model_key(provider: Any, model: Any, model_id: Any = None) -> str | None:
    p = provider.strip() if isinstance(provider, str) else ""
    m_raw = model if isinstance(model, str) else model_id
    m = m_raw.strip() if isinstance(m_raw, str) else ""
    if not p and not m:
        return None
    if not p:
        return m
    if not m:
        return p
    return f"{p}/{m}"


def read_num(value: Any) -> float:
    if isinstance(value, bool) or value is None:
        return 0.0
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    if isinstance(value, str):
        try:
            n = float(value)
            return n if math.isfinite(n) else 0.0
        except Exception:
            return 0.0
    return 0.0


def tokens_total(usage: Any) -> int:
    if not isinstance(usage, dict):
        return 0
    direct = (
        read_num(usage.get("totalTokens"))
        or read_num(usage.get("total_tokens"))
        or read_num(usage.get("tokenCount"))
        or read_num(usage.get("token_count"))
    )
    if direct:
        return int(direct)
    tokens = usage.get("tokens")
    if isinstance(tokens, dict):
        nested = read_num(tokens.get("total")) or read_num(tokens.get("totalTokens")) or read_num(tokens.get("total_tokens"))
        if nested:
            return int(nested)
    elif tokens:
        return int(read_num(tokens))
    input_tokens = (
        read_num(usage.get("input"))
        or read_num(usage.get("inputTokens"))
        or read_num(usage.get("input_tokens"))
        or read_num(usage.get("promptTokens"))
        or read_num(usage.get("prompt_tokens"))
    )
    output_tokens = (
        read_num(usage.get("output"))
        or read_num(usage.get("outputTokens"))
        or read_num(usage.get("output_tokens"))
        or read_num(usage.get("completionTokens"))
        or read_num(usage.get("completion_tokens"))
    )
    return int(input_tokens + output_tokens)


def cost_total(usage: Any) -> float:
    if not isinstance(usage, dict):
        return 0.0
    cost = usage.get("cost")
    if isinstance(cost, dict):
        return read_num(cost.get("total")) or sum(read_num(cost.get(k)) for k in ("input", "output", "cacheRead", "cacheWrite"))
    return read_num(cost)


def extract_usage(obj: dict[str, Any]) -> tuple[str, int, float]:
    msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
    wrapper = obj
    mk = (
        model_key(wrapper.get("provider"), wrapper.get("model"), wrapper.get("modelId"))
        or model_key(msg.get("provider"), msg.get("model"), msg.get("modelId"))
        or "unknown"
    )
    usage = wrapper.get("usage") if isinstance(wrapper.get("usage"), dict) else msg.get("usage")
    return mk, tokens_total(usage), cost_total(usage)


def empty_day(dt: datetime) -> dict[str, Any]:
    return {
        "date": day_key(dt),
        "sessions": 0,
        "messages": 0,
        "tokens": 0,
        "cost": 0.0,
        "model": {},
        "cwd": {},
        "dow": {},
        "tod": {},
    }


def incr_nested(day: dict[str, Any], kind: str, key: str, sessions: int, messages: int, tokens: int, cost: float) -> None:
    bucket = day[kind].setdefault(key, {"sessions": 0, "messages": 0, "tokens": 0, "cost": 0.0})
    bucket["sessions"] += sessions
    bucket["messages"] += messages
    bucket["tokens"] += tokens
    bucket["cost"] += cost


def parse_session(path: Path, cutoff: datetime) -> dict[str, Any] | None:
    started = parse_start_from_name(path)
    cwd = None
    current_model = None
    messages = 0
    tokens = 0
    cost = 0.0
    by_model: dict[str, dict[str, Any]] = defaultdict(lambda: {"messages": 0, "tokens": 0, "cost": 0.0})
    models_used: set[str] = set()

    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                typ = obj.get("type")
                if typ == "session":
                    started = started or parse_ts(obj.get("timestamp"))
                    if isinstance(obj.get("cwd"), str) and obj["cwd"].strip():
                        cwd = obj["cwd"].strip()
                    continue
                if typ == "model_change":
                    mk = model_key(obj.get("provider"), obj.get("model"), obj.get("modelId"))
                    if mk:
                        current_model = mk
                        models_used.add(mk)
                    continue
                if typ != "message":
                    continue
                msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
                role = msg.get("role")
                if role not in ("user", "assistant"):
                    continue
                mk, tok, cst = extract_usage(obj)
                if mk == "unknown" and current_model:
                    mk = current_model
                messages += 1
                tokens += tok
                cost += cst
                models_used.add(mk)
                by_model[mk]["messages"] += 1
                by_model[mk]["tokens"] += tok
                by_model[mk]["cost"] += cst
    except Exception:
        return None

    if started is None or started < cutoff:
        return None
    return {
        "path": str(path),
        "started": started,
        "date": day_key(started),
        "cwd": cwd or "unknown",
        "dow": DOW_NAMES[started.weekday()],
        "tod": tod_key(started.hour),
        "messages": messages,
        "tokens": tokens,
        "cost": cost,
        "models_used": sorted(models_used) or ["unknown"],
        "by_model": by_model,
    }


def build() -> dict[str, Any]:
    root = Path(os.environ.get("ZI_SESSION_ROOT") or Path.home() / ".zi" / "agent" / "sessions")
    now = datetime.now().astimezone()
    today = datetime(now.year, now.month, now.day, tzinfo=now.tzinfo)
    cutoff = today - timedelta(days=max(RANGE_DAYS) - 1)

    files: list[Path] = []
    if root.exists():
        for path in root.rglob("*.jsonl"):
            st = parse_start_from_name(path)
            if st is None or st >= cutoff:
                files.append(path)

    sessions = []
    for path in files:
        parsed = parse_session(path, cutoff)
        if parsed:
            sessions.append(parsed)

    ranges: dict[str, Any] = {}
    for days in RANGE_DAYS:
        start = today - timedelta(days=days - 1)
        day_list = [empty_day(start + timedelta(days=i)) for i in range(days)]
        by_day = {d["date"]: d for d in day_list}
        totals = {"sessions": 0, "messages": 0, "tokens": 0, "cost": 0.0}
        breakdowns: dict[str, dict[str, dict[str, Any]]] = {"model": {}, "cwd": {}, "dow": {}, "tod": {}}

        for s in sessions:
            if s["started"] < start:
                continue
            dk = s["date"]
            day = by_day.get(dk)
            if not day:
                continue
            totals["sessions"] += 1
            totals["messages"] += s["messages"]
            totals["tokens"] += s["tokens"]
            totals["cost"] += s["cost"]
            day["sessions"] += 1
            day["messages"] += s["messages"]
            day["tokens"] += s["tokens"]
            day["cost"] += s["cost"]

            for mk in s["models_used"]:
                incr_nested(day, "model", mk, 1, 0, 0, 0.0)
                b = breakdowns["model"].setdefault(mk, {"sessions": 0, "messages": 0, "tokens": 0, "cost": 0.0})
                b["sessions"] += 1
            for mk, vals in s["by_model"].items():
                incr_nested(day, "model", mk, 0, vals["messages"], vals["tokens"], vals["cost"])
                b = breakdowns["model"].setdefault(mk, {"sessions": 0, "messages": 0, "tokens": 0, "cost": 0.0})
                b["messages"] += vals["messages"]
                b["tokens"] += vals["tokens"]
                b["cost"] += vals["cost"]

            for kind, key in (("cwd", s["cwd"]), ("dow", s["dow"]), ("tod", s["tod"])):
                incr_nested(day, kind, key, 1, s["messages"], s["tokens"], s["cost"])
                b = breakdowns[kind].setdefault(key, {"sessions": 0, "messages": 0, "tokens": 0, "cost": 0.0})
                b["sessions"] += 1
                b["messages"] += s["messages"]
                b["tokens"] += s["tokens"]
                b["cost"] += s["cost"]

        ranges[str(days)] = {"days": day_list, "totals": totals, "breakdowns": breakdowns}

    return {
        "generated_at": now.isoformat(),
        "root": str(root),
        "files_scanned": len(files),
        "sessions_parsed": len(sessions),
        "ranges": ranges,
        "tod_labels": {key: label for key, label, _a, _b in TOD_BUCKETS},
        "dow_order": list(DOW_NAMES),
        "tod_order": [key for key, _label, _a, _b in TOD_BUCKETS],
    }


if __name__ == "__main__":
    json.dump(build(), sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
