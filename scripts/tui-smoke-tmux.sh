#!/usr/bin/env bash
set -euo pipefail

socket_dir="${PI_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/pi-tmux-sockets}"
mkdir -p "$socket_dir"
socket="$socket_dir/zi-tui-smoke.sock"
session="zi-tui-smoke"

cleanup() {
  tmux -S "$socket" kill-session -t "$session" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup

tmux -S "$socket" -f /dev/null new -d -s "$session" -n fixture

target="$(tmux -S "$socket" list-panes -t "$session" -F '#S:#I.#P' | head -n1)"
tmux -S "$socket" send-keys -t "$target" -l -- 'zig build tui-fixture'
tmux -S "$socket" send-keys -t "$target" Enter

# Let Zig build and the fixture enter the alt screen.
sleep 1.5

# SGR mouse wheel-up at cell 10,5. Repeated input should hit the resident
# scrollback boundary and make the fixture prepend fake older history.
for _ in $(seq 1 80); do
  tmux -S "$socket" send-keys -t "$target" -l -- $'\e[<64;10;5M'
done
sleep 0.5

capture="$(tmux -S "$socket" capture-pane -p -J -t "$target" -S -200)"
if ! grep -q 'fixture older page' <<<"$capture"; then
  printf 'expected older fixture history in tmux capture\n' >&2
  printf '%s\n' "$capture" >&2
  exit 1
fi

printf 'tui tmux smoke passed: older history rendered after wheel scroll\n'
