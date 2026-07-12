#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/docs/baselines"
ZI_BIN="$ROOT/zig-out/bin/zi"

mkdir -p "$OUT_DIR"
cd "$ROOT"
zig build

python3 - "$ROOT" "$ZI_BIN" "$OUT_DIR" <<'PY'
import json
import os
import fcntl
import pathlib
import pty
import re
import select
import shutil
import struct
import termios
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1])
zi_bin = pathlib.Path(sys.argv[2])
out_dir = pathlib.Path(sys.argv[3])

TRACE_RE = re.compile(r"zi tui trace: (\S+)")


def encode_cwd(cwd: str) -> str:
    start = 1 if cwd.startswith(("/", "\\")) else 0
    body = "".join("-" if ch in "/\\:" else ch for ch in cwd[start:])
    return f"--{body}--"


def write_faux_settings(agent_dir: pathlib.Path):
    (agent_dir / "settings.json").write_text(
        json.dumps({"defaultProvider": "faux", "defaultModel": "faux-default"}),
        encoding="utf-8",
    )


def faux_env(agent_dir: pathlib.Path, text: str):
    script = agent_dir / "faux-script.txt"
    script.write_text(text, encoding="utf-8")
    return {"ZI_ENABLE_FAUX_PROVIDER": "1", "ZI_FAUX_SCRIPT": str(script)}


def write_multimb_session(agent_dir: pathlib.Path, repo: pathlib.Path) -> str:
    leaf = "2026-07-04T00:00:00Z_baseline-multimb.jsonl"
    session_dir = agent_dir / "sessions" / encode_cwd(str(repo.resolve()))
    session_dir.mkdir(parents=True, exist_ok=True)
    path = session_dir / leaf
    usage = {
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "totalTokens": 0,
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0},
    }
    with path.open("w", encoding="utf-8") as f:
        f.write(json.dumps({
            "type": "session",
            "version": 3,
            "id": "baseline-multimb",
            "timestamp": "2026-07-04T00:00:00Z",
            "cwd": str(repo.resolve()),
        }, separators=(",", ":")) + "\n")
        parent = None
        for i in range(1, 7):
            text = f"entry {i}\n" + ("x" * (512 * 1024))
            entry_id = f"{i:08x}"
            entry = {
                "type": "message",
                "id": entry_id,
                "parentId": parent,
                "timestamp": f"2026-07-04T00:00:0{i}Z",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": text}],
                    "api": "openai-responses",
                    "provider": "openai",
                    "model": "gpt-5.1",
                    "responseId": None,
                    "usage": usage,
                    "stopReason": "stop",
                    "errorMessage": None,
                    "timestamp": 0,
                },
            }
            f.write(json.dumps(entry, separators=(",", ":")) + "\n")
            parent = entry_id
    return leaf


def strip_ansi(text: str) -> str:
    text = re.sub(r"\x1b\][^\x07]*(?:\x07|\x1b\\)", "", text)
    return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)


def run_tui(name: str, args, actions, timeout=12.0, env_extra=None, assert_text=None):
    with tempfile.TemporaryDirectory(prefix=f"zi-baseline-{name}-") as tmp_raw:
        tmp = pathlib.Path(tmp_raw)
        repo = tmp / "repo"
        agent = tmp / "agent"
        repo.mkdir()
        agent.mkdir()
        extra_args = list(args(agent, repo)) if callable(args) else list(args)
        env = os.environ.copy()
        env.update({
            "ZI_TUI_TRACE": "1",
            "ZI_CODING_AGENT_DIR": str(agent),
            "TERM": env.get("TERM") or "xterm-256color",
        })
        if env_extra:
            env.update(env_extra(agent, repo) if callable(env_extra) else env_extra)

        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(repo)
            os.execve(str(zi_bin), [str(zi_bin), *extra_args], env)

        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.set_blocking(fd, False)
        output = bytearray()
        start = time.monotonic()
        next_action = 0
        actions = list(actions)
        status = None
        try:
            while True:
                now = time.monotonic() - start
                while next_action < len(actions) and now >= actions[next_action][0]:
                    data = memoryview(actions[next_action][1])
                    while data:
                        try:
                            written = os.write(fd, data)
                            data = data[written:]
                        except BlockingIOError:
                            select.select([], [fd], [], 0.05)
                    next_action += 1
                ready, _, _ = select.select([fd], [], [], 0.05)
                if ready:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        chunk = b""
                    if chunk:
                        output.extend(chunk)
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    break
                if now > timeout:
                    os.write(fd, b"\x03\x03")
                    time.sleep(0.25)
                    done, status = os.waitpid(pid, os.WNOHANG)
                    if not done:
                        os.kill(pid, 15)
                        done, status = os.waitpid(pid, 0)
                    break
        finally:
            try:
                os.close(fd)
            except OSError:
                pass

        text = output.decode("utf-8", "replace")
        if assert_text and assert_text not in strip_ansi(text):
            raise SystemExit(f"{name}: expected text not found: {assert_text!r}; output was:\n{strip_ansi(text)[-4000:]}")
        match = TRACE_RE.search(text)
        if not match:
            raise SystemExit(f"{name}: no trace path found; output was:\n{text[-4000:]}")
        trace_path = pathlib.Path(match.group(1))
        target = out_dir / f"{name}.trace"
        shutil.copyfile(trace_path, target)
        print(f"captured {target}")


run_tui(
    "resume-multimb",
    lambda agent, repo: ["--session", write_multimb_session(agent, repo)],
    [(1.0, b"\x04"), (3.0, b"\x03\x03")],
    timeout=15.0,
)

paste = b"\x1b[200~" + (b"p" * (17 * 1024)) + b"\x1b[201~"
run_tui(
    "paste-17kb",
    [],
    [(1.0, paste), (3.0, b"\r"), (5.0, b"\x04"), (8.0, b"\x03\x03")],
    timeout=12.0,
)

prompt_stream_text = "FRONTDOORFAUXSENTINEL streamed through settings registry and TUI.\n"
run_tui(
    "prompt-stream-faux",
    lambda agent, repo: (write_faux_settings(agent) or []),
    [(1.0, b"hello faux\r"), (4.0, b"\x04"), (7.0, b"\x03\x03")],
    timeout=12.0,
    env_extra=lambda agent, repo: faux_env(agent, prompt_stream_text),
    assert_text="FRONTDOORFAUXSENTINEL",
)

# faux uses the buffered synthetic stream: 252 text deltas plus 4 lifecycle events.
flood_bytes = 252 * 64
flood_text = ("F" * (flood_bytes - len("FAUXFLOODDONE\n"))) + "FAUXFLOODDONE\n"
run_tui(
    "assistant-flood",
    lambda agent, repo: (write_faux_settings(agent) or []),
    [(1.0, b"flood please\r"), (8.0, b"\x04"), (14.0, b"\x03\x03")],
    timeout=20.0,
    env_extra=lambda agent, repo: faux_env(agent, flood_text),
)
PY
