#!/bin/bash
set -euo pipefail

# Andrew Kelley delete-loop score.
# Lower complexity_score is better. This script is intentionally static and fast:
# correctness belongs to autoresearch.checks.sh.

scoped_files=(
  src/coding_agent/AgentSession.zig
  src/coding_agent/AgentSessionRuntimeHost.zig
  src/coding_agent/interactive.zig
  src/coding_agent/session_manager.zig
  src/agent/loop.zig
  src/agent/Agent.zig
  src/agent/tool_runner.zig
  src/agent/root.zig
  src/runtime/process_runner.zig
  src/tui/product/App.zig
  src/tui/product/frame.zig
  src/tui/product/slots.zig
  src/tui/product/surface.zig
  src/tui/product/status_area.zig
  src/tui/product/loop.zig
  src/tui/product/terminal_loop.zig
)

existing_files=()
for file in "${scoped_files[@]}"; do
  if [[ -f "$file" ]]; then
    existing_files+=("$file")
  fi
done

sum_loc() {
  local total=0
  local lines
  for file in "${existing_files[@]}"; do
    lines=$(wc -l < "$file" | tr -d ' ')
    total=$((total + lines))
  done
  echo "$total"
}

large_file_penalty() {
  local total=0
  local lines over800 over1200 over2000
  for file in "${existing_files[@]}"; do
    lines=$(wc -l < "$file" | tr -d ' ')
    over800=0
    over1200=0
    over2000=0
    if (( lines > 800 )); then over800=$((lines - 800)); fi
    if (( lines > 1200 )); then over1200=$((lines - 1200)); fi
    if (( lines > 2000 )); then over2000=$((lines - 2000)); fi
    total=$((total + over800 + (over1200 * 2) + (over2000 * 4)))
  done
  echo "$total"
}

count_regex() {
  local pattern="$1"
  if ((${#existing_files[@]} == 0)); then
    echo 0
    return
  fi
  (rg -n "$pattern" "${existing_files[@]}" --glob '*.zig' 2>/dev/null || true) | wc -l | tr -d ' '
}

# These names are not automatically bad. They are pressure to inspect whether a
# current owner really needs the concept, or whether it is a future seam.
speculative_name_count=$(count_regex '\b[A-Za-z0-9_]*(Manager|Registry|Policy|Mirror|Slot|Surface|Effect|Command|Event|Queue|Store|Host)\b')
panic_like_count=$(count_regex 'catch unreachable|@panic|std\.debug\.panic|[^A-Za-z_]unreachable;')
todo_count=$(count_regex 'TODO|FIXME')
scoped_loc=$(sum_loc)
large_file_penalty_value=$(large_file_penalty)

# Current baseline from the branch this session was created on. Protects against
# metric gaming by deleting tests. If a legitimate simplification reduces test
# count, explain it in ASI and adjust this baseline deliberately.
baseline_test_count=618
test_count=$(rg '^test ' src -n --glob '*.zig' | wc -l | tr -d ' ')
test_loss_penalty=0
if (( test_count < baseline_test_count )); then
  test_loss_penalty=$(((baseline_test_count - test_count) * 100))
fi

boundary_violations=0
if rg '@import\("(\.\./)+(runtime|ai|agent|coding_agent)/|@import\("(\.\./)+coding_agent/|@import\("(\.\./)+agent/|@import\("(\.\./)+ai/' src/tui --glob '*.zig' >/dev/null 2>&1; then
  boundary_violations=$((boundary_violations + 1))
fi
if rg '@import\("(\.\./)+coding_agent/|@import\("(\.\./)+tui/' src/agent --glob '*.zig' >/dev/null 2>&1; then
  boundary_violations=$((boundary_violations + 1))
fi
if rg '@import\("(\.\./)+agent/|@import\("(\.\./)+coding_agent/|@import\("(\.\./)+tui/' src/ai --glob '*.zig' >/dev/null 2>&1; then
  boundary_violations=$((boundary_violations + 1))
fi
if rg '@import\("(\.\./)+(ai|agent|coding_agent|tui)/' src/runtime --glob '*.zig' >/dev/null 2>&1; then
  boundary_violations=$((boundary_violations + 1))
fi

fmt_status=0
zig fmt --check src build.zig >/tmp/zi-autoresearch-fmt.log 2>&1 || fmt_status=1

# Weighting:
# - raw hotspot LOC is the base pressure.
# - giant files get extra pressure because they are hard to audit.
# - speculative names and panic-like sites are prompts for deletion/proof.
# - boundary/test/fmt failures dominate and should never be kept.
complexity_score=$((
  scoped_loc +
  large_file_penalty_value +
  (speculative_name_count * 15) +
  (panic_like_count * 50) +
  (todo_count * 25) +
  test_loss_penalty +
  (fmt_status * 10000) +
  (boundary_violations * 100000)
))

printf 'METRIC complexity_score=%d\n' "$complexity_score"
printf 'METRIC scoped_loc=%d\n' "$scoped_loc"
printf 'METRIC large_file_penalty=%d\n' "$large_file_penalty_value"
printf 'METRIC speculative_name_count=%d\n' "$speculative_name_count"
printf 'METRIC panic_like_count=%d\n' "$panic_like_count"
printf 'METRIC todo_count=%d\n' "$todo_count"
printf 'METRIC test_count=%d\n' "$test_count"
printf 'METRIC test_loss_penalty=%d\n' "$test_loss_penalty"
printf 'METRIC fmt_status=%d\n' "$fmt_status"
printf 'METRIC boundary_violations=%d\n' "$boundary_violations"
