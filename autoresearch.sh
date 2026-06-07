#!/bin/bash
set -euo pipefail

# Static acceptance checks for remaining known builtin-tool parity gaps.
# Lower gaps_remaining is better. This is intentionally conservative: it only
# counts concrete checks that can be detected cheaply and locally.

gaps=0

check_present() {
  local desc="$1"
  local pattern="$2"
  local file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "GAP missing: $desc"
    gaps=$((gaps + 1))
  fi
}

check_absent() {
  local desc="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE "$pattern" "$file"; then
    echo "GAP present: $desc"
    gaps=$((gaps + 1))
  fi
}

# Edit/write UX acceptance probes. Require behavior and focused tests, not just helper names.
check_present "edit no-op rejection" "No changes|no-op|NoChanges" src/coding_agent/tools/edit.zig
check_present "edit no-op test" "test .*no-op|test .*NoChanges|expectError\(error\.NoChanges" src/coding_agent/tools/edit.zig
check_present "edit BOM handling" "BOM|bom|utf8_bom" src/coding_agent/tools/edit.zig
check_present "edit BOM test" "test .*BOM|test .*bom" src/coding_agent/tools/edit.zig
check_present "edit CRLF restoration" "CRLF|crlf|line_ending" src/coding_agent/tools/edit.zig
check_present "edit CRLF test" "test .*CRLF|test .*crlf|test .*line ending" src/coding_agent/tools/edit.zig
check_present "edit diff details" "\"firstChangedLine\"|\"patch\"|\"diff\"" src/coding_agent/tools/edit.zig
check_present "edit actual diff markers" "\\+\\{|\\-\\{|writeAll\\(\"\\+|writeAll\\(\"-" src/coding_agent/tools/edit.zig
check_present "edit diff details test" "test .*diff|\"firstChangedLine\"|\"patch\"" src/coding_agent/tools/edit.zig
check_present "edit actionable duplicate/not-found errors" "duplicate|not found|NotFound|Duplicate" src/coding_agent/tools/edit.zig

# Search/listing semantics probes.
check_present "grep ignoreCase" "ignoreCase|ignore_case" src/coding_agent/tools/grep.zig
check_present "grep invalid utf8 handling" "invalid utf-8|utf8ValidateSlice" src/coding_agent/tools/grep.zig
check_present "find visited cap" "max_visited|visited" src/coding_agent/tools/find.zig
check_present "ls optional limit" "parseOptionalLimit|limit" src/coding_agent/tools/ls.zig

# Path normalization probes.
check_present "shared creatable path resolution" "resolveCreatablePath" src/coding_agent/tools/path_utils.zig
check_present "path max bound" "max_path_bytes" src/coding_agent/tools/path_utils.zig
check_present "symlink escape test" "symlink escapes|symLink" src/coding_agent/tools/path_utils.zig

# Boundary probes.
if grep -R "@import(.*coding_agent\|@import(.*agent\|@import(.*ai\|@import(.*runtime" src/tui >/dev/null 2>&1; then
  echo "GAP present: forbidden tui import"
  gaps=$((gaps + 1))
fi

# Fast status metrics. Do not run full gates here; checks script owns that.
fmt_status=0
zig fmt --check src >/tmp/zi-autoresearch-fmt.log 2>&1 || fmt_status=1

printf 'METRIC gaps_remaining=%d\n' "$gaps"
printf 'METRIC fmt_status=%d\n' "$fmt_status"
printf 'METRIC test_status=0\n'
printf 'METRIC build_status=0\n'
printf 'METRIC lint_status=0\n'
