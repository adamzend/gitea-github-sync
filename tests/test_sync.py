import copy
import json
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

SCRIPT = str(Path(__file__).resolve().parents[1] / 'gitea-github-sync.sh')
repos = []
reads = []
writes = []
fail_repo = None
bad_discovery = False
failure_mode = 'permission'
request_gate = None
redirect_mode = None

def make(n, source, **kwargs):
    r = dict(id=n, name=f'local-{n}', owner={'login':'adam'}, mirror=True,
             original_url=source, archived=False, has_issues=True,
             default_branch='main', description='old', website='', topics=[], issues=[], comments=[])
    r.update(kwargs)
    return r

def reset():
    global repos, fail_repo, bad_discovery
    fail_repo = None
    bad_discovery = False
    reads.clear()
    writes.clear()
    repos = [make(1, 'https://github.com/first/alpha.git'),
             make(2, 'git@github.com:second/beta.git', private=True),
             make(3, 'ssh://git@github.com:22/third/gamma.git/', has_issues=False),
             make(4, 'https://gitlab.com/other/project.git'),
             make(5, 'https://github.com/first/alpha.git', mirror=False),
             make(6, 'https://github.com/first/alpha.git', owner={'login':'someone-else'}),
             make(7, 'https://github.com.evil.invalid/a/b.git'),
             make(8, 'https://user:password@GitHub.com/Fourth/delta.git/')]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def answer(self, code, obj=None, headers=None):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        for k,v in (headers or {}).items(): self.send_header(k,str(v))
        self.end_headers()
        if obj is not None: self.wfile.write(json.dumps(obj).encode())
    def do_GET(self):
        global fail_repo
        if request_gate is not None: request_gate.wait(timeout=10)
        reads.append(self.path)
        u = urlsplit(self.path)
        page = int(parse_qs(u.query).get('page', ['1'])[0])
        if u.path == '/api/v1/user': return self.answer(200, {'login':'adam'})
        if u.path == '/api/v1/users/adam/repos':
            return self.answer(200, {'error':'invalid'} if bad_discovery else repos[page-1:page])
        if u.path.startswith('/gh/') and redirect_mode:
            if redirect_mode == 'external':
                return self.answer(301, {}, {'Location':'https://example.invalid/steal'})
            if redirect_mode == 'loop':
                return self.answer(301, {}, {'Location':self.path})
            if not u.path.startswith('/gh/moved/'):
                return self.answer(301, {}, {'Location':self.path.replace('/gh/', '/gh/moved/', 1)})
        gh = u.path.startswith('/gh/')
        parts = u.path.split('/repos/')[-1].split('/')
        owner, name = parts[:2]
        tail = '/' + '/'.join(parts[2:]) if len(parts)>2 else ''
        mapping = {'alpha':1, 'beta':2, 'gamma':3, 'delta':8}
        if gh:
            if name not in mapping: return self.answer(404, {})
            n = mapping[name]
            expected = {1:'first',2:'second',3:'third',8:'Fourth'}[n]
            assert owner == expected
        else:
            assert owner == 'adam'
            n = int(name.removeprefix('local-'))
        r = next(x for x in repos if x['id']==n)
        if gh and n == fail_repo:
            if failure_mode == 'primary':
                return self.answer(403, {'message':'API rate limit exceeded'}, {'X-RateLimit-Remaining':0,'X-RateLimit-Reset':int(time.time())+3600})
            if failure_mode == 'secondary':
                return self.answer(403, {'message':'You have exceeded a secondary rate limit'})
            if failure_mode == 'retry':
                fail_repo = None
                return self.answer(429, {'message':'Too many requests'}, {'Retry-After':1})
            if failure_mode == 'missing': return self.answer(404, {'message':'Not Found'})
            if failure_mode == 'auth': return self.answer(401, {'message':'Bad credentials'})
            return self.answer(403, {'message':'denied'})
        if tail == '': return self.answer(200, dict(id=n, default_branch='main', description=f'source-{n}', homepage=f'https://example.com/{n}') if gh else r)
        if tail == '/topics': return self.answer(200, {'names' if gh else 'topics':[f'topic-{n}'] if gh else r['topics']})
        if tail == '/issues':
            assert r['has_issues'], 'must not request disabled issues'
            data = [dict(id=100+n, number=1, title=f'Issue-{n}', body=f'Body-{n}', state='closed')] if gh else r['issues']
        elif tail == '/issues/comments':
            assert r['has_issues']
            data = [dict(id=200+n, body=f'Comment-{n}', issue_url=f'https://api.github.com/repos/{owner}/{name}/issues/1')] if gh else r['comments']
        elif tail.endswith('/comments'): return self.answer(200, r['comments'])
        else: return self.answer(404, {})
        self.answer(200, data[page-1:page])
    def write(self):
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or '{}')
        parts = self.path.split('/repos/adam/local-')[1].split('/')
        n = int(parts[0]); tail = '/'+'/'.join(parts[1:]) if len(parts)>1 else ''
        writes.append((n,self.command,tail,data))
        r = next(x for x in repos if x['id']==n)
        if tail == '': r.update(data); return self.answer(200,r)
        if tail == '/topics': r['topics']=data['topics']; return self.answer(204)
        if tail == '/mirror-sync': return self.answer(200)
        if tail == '/issues':
            item = dict(data,id=1000+n,number=10,state='closed' if data['closed'] else 'open')
            r['issues'].append(item); return self.answer(201,item)
        if tail.endswith('/comments'):
            item = dict(data,id=2000+n); r['comments'].append(item); return self.answer(201,item)
        self.answer(404,{})
    do_POST=write
    do_PATCH=write
    do_PUT=write

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory() as tmp:
    conf=Path(tmp)/'config'
    conf.write_text(f"GITEA_TOKEN='test'\nGITEA_URL='http://127.0.0.1:{server.server_port}'\nGITHUB_API='http://127.0.0.1:{server.server_port}/gh'\nLOCK_FILE='{tmp}/lock'\nGITEA_REPO='obsolete-name'\nGITHUB_RATE_LIMIT_MAX_WAIT=2\n")
    def run(mode='--apply', success=True):
        p=subprocess.run(['bash',SCRIPT,'--config',str(conf),mode,'--no-git'],capture_output=True,text=True)
        assert (p.returncode==0)==success,p.stderr
        assert 'password' not in p.stderr
        return p.stderr
    reset()
    out=run('--dry-run')
    assert not writes and 'selected=4, succeeded=4, failed=0, skipped=4' in out,out
    assert any('page=9' in p for p in reads)
    assert 'Progress: Reading gt repositories.jsonl; page=1' in out,out
    assert 'Progress: Comparing and synchronizing issues/comments' in out,out
    print('PASS account discovery, full pagination, private mirror and source URL filters')
    run()
    assert {n for n,_,_,_ in writes}=={1,2,3,8}
    for r in repos:
        if r['id'] in {1,2,8}:
            assert len(r['issues'])==len(r['comments'])==1
            assert r['issues'][0]['title']==f"Issue-{r['id']}"
            assert r['comments'][0]['body'].startswith(f"Comment-{r['id']}")
        if r['id']==3: assert not r['issues'] and r['description']=='source-3'
    writes.clear()
    run()
    assert not writes
    print('PASS isolated state, renamed destinations, disabled issues, multi-repository idempotency')
    repos[0]['comments'].extend(dict(id=9000+i,body=f'Local comment {i}') for i in range(60))
    reads.clear(); run(); assert not writes
    assert len([p for p in reads if p == '/api/v1/repos/adam/local-1/issues/10/comments']) == 1
    assert len(repos[0]['comments']) == 61
    print('PASS complete unpaginated list over 50 comments read once without duplicate writes')
    reset(); fail_repo=1
    out=run(success=False)
    assert {n for n,_,_,_ in writes}=={2,3,8}
    assert 'selected=4, succeeded=3, failed=1' in out,out
    print('PASS one repository failure does not stop remaining repositories')
    reset(); fail_repo=1; failure_mode='missing'
    out=run()
    assert 'unavailable=1' in out and 'failed=0' in out,out
    assert 'Failure at line' not in out and 'FAILED ' not in out,out
    assert {n for n,_,_,_ in writes}=={2,3,8}
    failure_mode='permission'
    print('PASS missing GitHub source preserved and counted separately without failing the run')
    reset(); repos[0]['archived']=True
    out=run(success=False)
    assert {n for n,_,_,_ in writes}=={2,3,8}
    print('PASS archived mirrors reported without blocking other repositories')
    reset(); repos=[]
    out=run()
    assert not writes and 'discovered=0' in out
    print('PASS empty account')
    reset(); bad_discovery=True
    run(success=False)
    assert not writes
    print('PASS discovery failure prevents writes')
    for failure_mode in ['primary','secondary','auth']:
        reset(); fail_repo=1
        out=run(success=False)
        assert not writes and 'Account scan aborted' in out,out
        assert len([p for p in reads if p.startswith('/gh/')])==1,reads
        if failure_mode=='primary': assert 'quota resets at' in out
        if failure_mode=='auth': assert 'Bad credentials' in out
        print(f'PASS {failure_mode} error is diagnosed and stops further GitHub requests')
    failure_mode='retry'
    reset(); fail_repo=1
    out=run()
    assert 'Waiting 1 seconds' in out and 'succeeded=4' in out,out
    assert {n for n,_,_,_ in writes}=={1,2,3,8}
    print('PASS Retry-After respected and synchronization resumes')
    reset(); redirect_mode='same'
    out=run()
    assert 'Following GitHub HTTP 301' in out and 'succeeded=4' in out,out
    writes.clear(); run(); assert not writes
    print('PASS same-origin redirects and idempotent unpaginated Gitea comments')
    for redirect_mode in ['external','loop']:
        reset(); out=run(success=False)
        assert not writes
        assert ('Rejected GitHub redirect' if redirect_mode=='external' else 'redirect limit exceeded') in out,out
    redirect_mode=None
    print('PASS cross-origin redirects and redirect loops rejected before writes')
    reset()
    quiet_log=Path(tmp)/'quiet.log'
    with conf.open('a') as f: f.write(f"QUIET_LOG_FILE='{quiet_log}'\n")
    request_gate=threading.Event()
    p=subprocess.run(['bash',SCRIPT,'--config',str(conf),'--apply-quiet','--no-git'],capture_output=True,text=True,timeout=5)
    assert p.returncode==0 and not p.stdout and not p.stderr,p
    assert not writes, 'launcher must return before blocked background work completes'
    request_gate.set()
    request_gate=None
    deadline=time.monotonic()+60
    while time.monotonic()<deadline:
        if quiet_log.exists() and 'Background worker finished:' in quiet_log.read_text(): break
        time.sleep(.1)
    out=quiet_log.read_text()
    assert 'exit_status=0' in out and 'succeeded=4' in out,out
    assert 'Progress:' in out,out
    assert {n for n,_,_,_ in writes}=={1,2,3,8}
    assert quiet_log.stat().st_mode & 0o777 == 0o600
    print('PASS quiet mode returns immediately, writes no terminal output, applies all repositories and logs completion')
    reset(); failure_mode='auth'; fail_repo=1
    quiet_log.write_text('')
    p=subprocess.run(['bash',SCRIPT,'--config',str(conf),'--apply-quiet'],capture_output=True,text=True,timeout=5)
    assert p.returncode==0 and not p.stdout and not p.stderr
    deadline=time.monotonic()+30
    while time.monotonic()<deadline:
        if 'Background worker finished:' in quiet_log.read_text(): break
        time.sleep(.1)
    assert 'exit_status=1' in quiet_log.read_text() and not writes
    print('PASS quiet background failure is retained in the log')
    badconf=Path(tmp)/'bad-config'
    badconf.write_text(conf.read_text()+f"QUIET_LOG_FILE='{tmp}/missing/log'\n")
    p=subprocess.run(['bash',SCRIPT,'--config',str(badconf),'--apply-quiet'],capture_output=True,text=True)
    assert p.returncode!=0 and not p.stdout and not p.stderr
    print('PASS inaccessible quiet log fails silently before launching')
server.shutdown()
