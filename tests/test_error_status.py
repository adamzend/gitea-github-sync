import subprocess
import tempfile
import threading
from pathlib import Path
from http.server import ThreadingHTTPServer

# Reuse the mock API definitions without running its full regression suite.
ns = {'__file__': str(Path(__file__).with_name('test_sync.py'))}
exec(Path(ns['__file__']).read_text().split('server=ThreadingHTTPServer')[0], ns)
class InvalidJSON(ns['Handler']):
    def do_GET(self):
        if self.path == '/gh/repos/first/alpha':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'not-json')
        else:
            super().do_GET()
ns['reset']()
ns['repos'] = ns['repos'][:1]
server = ThreadingHTTPServer(('127.0.0.1', 0), InvalidJSON)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory() as tmp:
    config = Path(tmp) / 'config'
    config.write_text(f"GITEA_TOKEN=test\nGITEA_URL=http://127.0.0.1:{server.server_port}\nGITHUB_API=http://127.0.0.1:{server.server_port}/gh\nLOCK_FILE={tmp}/lock\n")
    result = subprocess.run(['bash', ns['SCRIPT'], '--config', str(config), '--apply', '--no-git'], capture_output=True, text=True)
    assert result.returncode != 0, result.stderr
    assert 'failed=1' in result.stderr and 'unavailable=0' in result.stderr, result.stderr
    assert 'Invalid JSON' in result.stderr and not ns['writes'], result.stderr
server.shutdown()
print('PASS invalid JSON remains a genuine failure, not an unavailable source')
