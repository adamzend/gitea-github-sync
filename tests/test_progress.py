import subprocess
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / 'gitea-github-sync.sh').read_text()
progress = source[source.index('PROGRESS_LAST=-1'):source.index('on_error() {')]
program = "set -Eeuo pipefail\nlog() { printf '%s\\n' \"$*\"; }\nPROGRESS_INTERVAL=60\n" + progress + """
SECONDS=0
progress "Reading comments" "processed=0"
SECONDS=59
progress "Reading comments" "processed=59"
SECONDS=60
progress "Reading comments" "processed=60"
progress "Applying issues" "processed=0"
"""
result = subprocess.run(['bash', '-c', program], capture_output=True, text=True, check=True)
lines = result.stdout.splitlines()
assert len(lines) == 3, result.stdout
assert 'processed=59' not in result.stdout
assert 'processed=60' in lines[1] and 'Applying issues' in lines[2]
print('PASS progress interval, counters and immediate stage transitions')
