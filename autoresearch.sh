#!/usr/bin/env bash
set -euo pipefail

fmt_status=0
zig fmt --check src >/dev/null 2>&1 || fmt_status=1

python3 - <<'PY'
from pathlib import Path
import re

scope_roots = [
    Path('src/coding_agent'),
    Path('src/agent'),
    Path('src/tui/product'),
]
extra_paths = [
    Path('src/runtime/process_runner.zig'),
    Path('src/runtime/cancel.zig'),
    Path('src/runtime/event_pipe.zig'),
    Path('src/runtime/bounded_queue.zig'),
    Path('src/main.zig'),
    Path('src/root.zig'),
]
paths = []
for root in scope_roots:
    if root.exists():
        paths.extend(sorted(root.rglob('*.zig')))
for path in extra_paths:
    if path.exists():
        paths.append(path)
# Keep each file once while preserving order.
seen = set()
paths = [p for p in paths if not (p in seen or seen.add(p))]

texts = {p: p.read_text(errors='ignore') for p in paths}
line_counts = {p: (texts[p].count('\n') + (0 if texts[p].endswith('\n') or texts[p] == '' else 1)) for p in paths}
scoped_loc = sum(line_counts.values())
large_file_penalty = sum(max(0, n - 700) * 4 for n in line_counts.values())

public_api_count = 0
for text in texts.values():
    public_api_count += len(re.findall(r'(?m)^\s*pub\s+(?:const|var|fn)\b', text))

sdk_host_files = [Path('src/coding_agent/sdk.zig'), Path('src/coding_agent/AgentSessionRuntimeHost.zig')]
sdk_host_loc = sum(line_counts.get(p, p.read_text(errors='ignore').count('\n') if p.exists() else 0) for p in sdk_host_files)

all_code = '\n'.join(texts.values())
indirection_terms = [
    'Host', 'Manager', 'Registry', 'Mirror', 'Surface', 'Slot', 'Policy', 'Adapter',
    'Bridge', 'Handle', 'RuntimeServices', 'EventDrain', 'QueueMirror', 'Snapshot',
    'Callback', 'Dispatcher', 'Resolver', 'ProviderRegistry', 'ToolRegistry',
]
indirection_name_count = 0
for term in indirection_terms:
    indirection_name_count += len(re.findall(r'\b\w*' + re.escape(term) + r'\w*\b', all_code))

one_caller_fn_count = 0
for p, text in texts.items():
    names = [m.group(1) for m in re.finditer(r'(?m)^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)\s*\(', text)]
    for name in names:
        if len(re.findall(r'\b' + re.escape(name) + r'\b', text)) == 2:
            one_caller_fn_count += 1

# Import direction hard failures. These patterns intentionally inspect imports,
# not arbitrary comments.
boundary_violations = 0
for p in Path('src/tui').rglob('*.zig'):
    text = p.read_text(errors='ignore')
    boundary_violations += len(re.findall(r'@import\([^\)]*(?:runtime|agent|ai|coding_agent)', text))
for p in Path('src/agent').rglob('*.zig'):
    text = p.read_text(errors='ignore')
    boundary_violations += len(re.findall(r'@import\([^\)]*(?:coding_agent|tui)', text))
for p in Path('src/ai').rglob('*.zig'):
    text = p.read_text(errors='ignore')
    boundary_violations += len(re.findall(r'@import\([^\)]*(?:agent|coding_agent|tui)', text))
for p in Path('src/runtime').rglob('*.zig'):
    text = p.read_text(errors='ignore')
    boundary_violations += len(re.findall(r'@import\([^\)]*(?:coding_agent|tui|agent|ai)', text))

test_count = 0
for p in Path('src').rglob('*.zig'):
    test_count += len(re.findall(r'(?m)^\s*test\b', p.read_text(errors='ignore')))
baseline_test_count = 614
test_loss_penalty = max(0, baseline_test_count - test_count) * 120

# Weighted architecture score. LOC and giant files matter, but API/host surface and
# indirection are deliberately weighted because this session allows API breakage.
andrew_score = (
    scoped_loc
    + large_file_penalty
    + public_api_count * 9
    + sdk_host_loc * 2
    + indirection_name_count * 3
    + one_caller_fn_count * 6
    + boundary_violations * 10000
    + test_loss_penalty
)

metrics = {
    'andrew_score': andrew_score,
    'scoped_loc': scoped_loc,
    'large_file_penalty': large_file_penalty,
    'public_api_count': public_api_count,
    'sdk_host_loc': sdk_host_loc,
    'indirection_name_count': indirection_name_count,
    'one_caller_fn_count': one_caller_fn_count,
    'test_count': test_count,
    'test_loss_penalty': test_loss_penalty,
    'boundary_violations': boundary_violations,
}
for name, value in metrics.items():
    print(f'METRIC {name}={value}')
PY
printf 'METRIC fmt_status=%d\n' "$fmt_status"
