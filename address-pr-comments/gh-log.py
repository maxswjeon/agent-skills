#!/usr/bin/env python3
"""gh-log.py — files one gh invocation into the SQLite call log (schema: gh-log.sql).

Run by bin/gh, never by hand:  gh-log.py <debug-file> <exit-code> <t0> <t1> <gh argv…>
<debug-file> is gh's stderr under GH_DEBUG=api: one "* Request at … * Request took" block per
HTTP exchange. `gh-log.py --self-test` asserts the parsing, redaction and cost rules.

DB: $PR_REVIEW_LOG_DB, default ${XDG_STATE_HOME:-~/.local/state}/pr-review/gh-calls.sqlite.
Never raises: a failure is appended to <db>.errors and gh's result stands.
"""
import email.utils
import hashlib
import json
import os
import re
import sqlite3
import sys
import traceback
import urllib.parse
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.realpath(__file__))
DB = os.environ.get('PR_REVIEW_LOG_DB') or os.path.join(
    os.environ.get('XDG_STATE_HOME') or os.path.expanduser('~/.local/state'), 'pr-review', 'gh-calls.sqlite')
SCRIPTS = {'pr-ops.sh', 'pr-state.sh', 'pr-report.sh', 'judge-features.py'}
API = 'api.github.com'
READ = {'GET', 'HEAD', 'OPTIONS'}

# ------------------------------------------------------------------ gh debug log
def parse(lines):
    """[{at, took_ms, method, url, req_headers, body: [lines], status, headers}] per HTTP exchange.

    gh runs some requests concurrently (`gh pr checks` does), and then their blocks interleave
    in any order: heads, bodies, response headers. Each part is still one contiguous write.
    Request heads go to the newest open block; a body is recognised by its content (a GraphQL
    request: "GraphQL query:" or JSON with a top-level "query"; REST bodies are never read)
    and goes to the oldest GraphQL request still without one; responses and "took" lines go
    to the oldest open block. ponytail: between two overlapping requests a body or response
    can land on the wrong one (intent still follows the body's own document, so a mutation's
    text is never kept); sequential calls — all of `gh api`, its pages included — are exact."""
    out, open_, waiting, req, resp, chunk = [], [], [], None, None, None

    def done(c):
        if waiting and (c[0] == 'GraphQL query:' or (c[0] == '{' and any(x.startswith('  "query": ') for x in c))):
            waiting.pop(0)['body'] = c

    for ln in lines:
        ln = ln.rstrip('\n')
        if chunk is not None and not ln.startswith(('* Request ', '> ', '< ')):
            gq = chunk[0] == 'GraphQL query:'          # that format may hold blank lines
            if gq or ln.strip():
                chunk.append(ln)
                if gq and ln.startswith('GraphQL variables:'): done(chunk); chunk = None
            else: done(chunk); chunk = None
            continue
        if chunk is not None: done(chunk); chunk = None
        if ln.startswith('* Request at '):
            b = {'at': ln[13:], 'took_ms': None, 'method': None, 'url': None, 'req_headers': {},
                 'body': [], 'status': None, 'headers': {}}
            out.append(b); open_.append(b); continue
        if not open_: continue
        if ln.startswith('* Request took '):
            b = next((b for b in open_ if b['status'] is not None), open_[0])
            b['took_ms'] = duration_ms(ln[15:]); open_.remove(b); continue
        if ln.startswith('* Request to '):
            b = next((b for b in reversed(open_) if b['url'] is None), None)
            if b: b['url'] = ln[13:]
            continue
        if ln.startswith('> '):
            m = re.match(r'> ([A-Z]+) \S+ HTTP/', ln)
            if m:
                req = next((b for b in reversed(open_) if b['method'] is None), open_[-1])
                req['method'] = m.group(1)
                if (req['url'] or '').endswith('/graphql'): waiting.append(req)
            elif req is not None and ':' in ln:
                k, v = ln[2:].split(':', 1); req['req_headers'][k.strip().lower()] = v.strip()
            continue
        if ln.startswith('< '):
            m = re.match(r'< HTTP/\S+ (\d{3})', ln)
            if m:
                resp = next((b for b in open_ if b['status'] is None), None)
                if resp: resp['status'] = int(m.group(1))
            elif resp is not None and ':' in ln:
                k, v = ln[2:].split(':', 1); resp['headers'][k.strip().lower()] = v.strip()
            continue
        if ln.strip(): chunk = [ln]                    # a body; done() keeps GraphQL request ones
    if chunk is not None: done(chunk)
    return out

def duration_ms(s):   # Go duration: 475.6ms, 531.7µs, 1.2s, 1m2.3s
    units = {'h': 3.6e6, 'm': 6e4, 's': 1e3, 'ms': 1, 'us': 1e-3, 'µs': 1e-3, 'ns': 1e-6}
    parts = re.findall(r'([\d.]+)(h|ms|m|s|us|µs|ns)', s.strip())
    return round(sum(float(n) * units[u] for n, u in parts), 3) if parts else None

def gql_body(body):
    """gh prints a GraphQL request as 'GraphQL query:' <doc lines> 'GraphQL variables: <json>',
    or, for some of its own requests, as the JSON body itself."""
    if 'GraphQL query:' not in [b.strip() for b in body]:
        try: j = json.loads('\n'.join(body))
        except ValueError: return None, {}
        return (j.get('query'), j.get('variables') or {}) if isinstance(j, dict) else (None, {})
    i = [b.strip() for b in body].index('GraphQL query:')
    doc, var = [], {}
    for b in body[i + 1:]:
        if b.startswith('GraphQL variables:'):
            try: var = json.loads(b[18:].strip()) or {}
            except ValueError: var = {}
            break
        doc.append(b)
    return '\n'.join(doc).strip(), var

# ------------------------------------------------------------------ GraphQL
TOK = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|#[^\n]*|\.\.\.|\$?[A-Za-z_]\w*|-?\d+|[{}():=@!\[\],]')
NAME = re.compile(r'[A-Za-z_]\w*')

def gql_info(doc, var):
    """(intent, operation, expected points) by GitHub's published estimate: each connection
    (a field with first/last) costs one request per instance of its parent connections;
    sum, divide by 100, round to nearest, minimum 1."""
    toks = [t for t in TOK.findall(doc) if not t.startswith('#')]
    # A mutation anywhere at the top level makes the request a mutation — a fragment or a
    # query may come first. No operation at all: unknown, so treated as a mutation (kept out).
    top, d, frag = [], 0, False
    for k, t in enumerate(toks):
        if t == '{':
            if d == 0 and not frag: top.append(k)        # shorthand `{ … }` is a query
            frag = frag and d != 0; d += 1
        elif t == '}': d -= 1
        elif d == 0 and t == 'fragment': frag = True     # its `{` opens no operation
        elif d == 0 and t in ('query', 'mutation', 'subscription'): top.append(k)
    kinds = [toks[k] for k in top]
    kind = 'mutation' if 'mutation' in kinds or not kinds else 'query'
    name = next((toks[k + 1] for k in top if toks[k] == kind and k + 1 < len(toks)
                 and NAME.fullmatch(toks[k + 1])), None)
    stack, total, first_conn, tops, in_frag = [], 0, None, [], False
    field = limit = None
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        if t == '(':                                   # arguments: only first/last matter
            d, j = 0, i
            while j < n:
                if toks[j] == '(': d += 1
                elif toks[j] == ')':
                    d -= 1
                    if d == 0: break
                elif d == 1 and toks[j] in ('first', 'last') and j + 2 < n and toks[j + 1] == ':':
                    v = toks[j + 2]
                    v = var.get(v[1:]) if v.startswith('$') else v
                    try: limit = int(v)
                    except (TypeError, ValueError): pass
                j += 1
            i = j + 1; continue
        if t == '@': i += 2; continue                  # directive name; its args follow
        if t == '{':
            if limit is not None:
                mult = 1
                for _, l in stack: mult *= l or 1
                total += mult
                if first_conn is None and not in_frag:
                    first_conn = '.'.join([f for f, _ in stack[1:] if f] + [field])
            stack.append((field, limit)); field = limit = None
        elif t == '}':
            if stack: stack.pop()
            field = limit = None
            in_frag = in_frag and bool(stack)
        elif NAME.fullmatch(t) and t != 'on':
            if i + 1 < n and toks[i + 1] == ':': i += 2; continue   # alias
            field, limit = t, None
            if not stack and t == 'fragment': in_frag = True   # names an operation, not a fragment
            if len(stack) == 1 and not in_frag and t not in tops: tops.append(t)
        i += 1
    cost = max(1, int(total / 100 + 0.5))   # ponytail: named fragments are costed as roots, not per spread
    return kind, (name or first_conn or ','.join(tops) or None), cost

# ------------------------------------------------------------------ REST
def rest_template(path):
    p = re.sub(r'^/repositories/\d+', '/repos/{owner}/{repo}', path)   # gh follows Link pages by repo id
    p = re.sub(r'^/repos/[^/]+/[^/]+', '/repos/{owner}/{repo}', p)
    seg = []
    for s in p.split('/'):
        if re.fullmatch(r'\d+', s): s = '{n}'
        elif re.fullmatch(r'[0-9a-f]{40}', s): s = '{sha}'
        elif re.fullmatch(r'[0-9a-f]{7,40}\.\.\.[0-9a-f]{7,40}', s): s = '{base}...{head}'
        seg.append(s)
    return '/'.join(seg)

# ------------------------------------------------------------------ invocation context
FIELD_FLAGS = {'-f', '-F', '--field', '--raw-field'}           # key=value: keep the key
HEADER_FLAGS = {'-H', '--header'}                               # keep the header name
DROP_FLAGS = {'-b', '--body', '-t', '--title', '-m', '--message', '--body-file', '--notes'}

def redact(argv):
    """argv without values. `gh api`: endpoint, flags, field keys, header names. Any other
    command (label create, pr merge, …): its subcommand words and flag names only."""
    if argv[:1] != ['api']:
        words = []
        for a in argv[:2]:
            if a.startswith('-'): break
            words.append(a)
        return words + [a.split('=', 1)[0] for a in argv if a.startswith('-')]
    out, it = [], iter(argv)
    for a in it:
        m = re.fullmatch(r'(--[\w-]+)=(.*)|(-[fFHbtm])(.+)', a, re.DOTALL)   # --flag=v, glued -fk=v
        flag, val = (m[1] or m[3], m[2] if m[1] else m[4]) if m else (a, None)
        if flag not in FIELD_FLAGS | HEADER_FLAGS | DROP_FLAGS: out.append(a); continue
        if not m:
            out.append(a); val = next(it, None)                 # value in the next arg
            if val is None: continue
        red = (val.split('=', 1)[0] + '=…' if flag in FIELD_FLAGS
               else val.split(':', 1)[0] + ': …' if flag in HEADER_FLAGS else '…')
        out.append((flag + ('=' if m[1] else '') + red) if m else red)
    return out

def ancestry():
    """(script, command, script args): the innermost PR-review script above this gh, and the
    outermost one (the command the agent ran) as "name subcommand --flags" — flag values and
    free text (judge reasons, issue titles) left out."""
    chain, pid = [], os.getppid()
    for _ in range(12):
        try:
            with open(f'/proc/{pid}/cmdline', 'rb') as f:
                args = [a.decode(errors='replace') for a in f.read().split(b'\0') if a]
            with open(f'/proc/{pid}/stat') as f:
                ppid = int(f.read().rsplit(')', 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
        for k, a in enumerate(args[:3]):
            if os.path.basename(a) in SCRIPTS:
                chain.append((os.path.basename(a), args[k + 1:])); break
        if ppid <= 1: break
        pid = ppid
    if not chain: return None, None, []
    name, args = chain[-1]
    cmd = [name] + [a for j, a in enumerate(args)
                    if (j == 0 and re.fullmatch(r'[a-z][a-z-]*', a)) or re.fullmatch(r'--[a-z][a-z-]*', a)]
    return chain[0][0], ' '.join(cmd), args

def repo_pr(script_args, argv, reqs):
    for args in (script_args, argv):
        for k, a in enumerate(args):
            m = re.match(r'https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)', a)
            if m: return m.group(1), int(m.group(2))
            if re.fullmatch(r'[\w-][\w.-]*/[\w.-]+', a):         # owner/repo, then a PR number
                num = [x for x in args[k + 1:k + 2] if x.isdigit()] or [x for x in args if x.isdigit()][:1]
                return a, int(num[0]) if num else None
    for r in reqs:
        m = re.match(r'https://api\.github\.com/repos/([\w.-]+/[\w.-]+)(?:/(?:pulls|issues)/(\d+))?', r['url'] or '')
        if m: return m.group(1), int(m.group(2)) if m.group(2) else None
    return None, None

def gh_cache_hit(r):
    """gh replays cached responses without a network call (its own feature checks, tagged
    X-Gh-Cache-Ttl; `gh api --cache`, untagged but answered in well under the 20 ms no round
    trip to GitHub makes). A replay keeps the original Date; 30 s of slack absorbs clock skew —
    a cache entry that young is the only miss, and it costs nothing."""
    if 'date' not in r['headers']: return False
    if 'x-gh-cache-ttl' not in r['req_headers'] and not (r['took_ms'] or 1e9) < 20: return False
    try:
        sent = datetime.fromisoformat(iso(r['at']).replace('Z', '+00:00'))
        return (sent - email.utils.parsedate_to_datetime(r['headers']['date'])).total_seconds() > 30
    except (TypeError, ValueError, AttributeError):
        return False

def iso(s):
    """'2026-11-04 16:24:08.748839309 +0900 KST m=+0.04' (gh prints local time) → UTC ISO 8601, ms."""
    m = re.match(r'(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)(?:\.(\d+))? ([+-]\d{4})', s or '')
    if not m: return None
    t = datetime.strptime(f'{m[1]} {m[2]}.{(m[3] or "0")[:6]:0<6} {m[4]}', '%Y-%m-%d %H:%M:%S.%f %z')
    return t.astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

# ------------------------------------------------------------------ write
def connect(db):
    os.makedirs(os.path.dirname(db), exist_ok=True)
    con = sqlite3.connect(db, timeout=3)   # a locked DB drops this row; it never stalls the review loop
    if con.execute('PRAGMA user_version').fetchone()[0] < 1:
        with open(os.path.join(HERE, 'gh-log.sql')) as f: con.executescript(f.read())
    con.execute('PRAGMA foreign_keys = ON')
    return con

def query_id(con, api, body):
    h = hashlib.sha256(f'{api}\0{body}'.encode()).hexdigest()
    con.execute('INSERT OR IGNORE INTO queries(sha256, api, body) VALUES (?,?,?)', (h, api, body))
    return con.execute('SELECT id FROM queries WHERE sha256 = ?', (h,)).fetchone()[0]

def record(con, reqs, rc, t0, t1, argv, script, command, script_args):
    repo, pr = repo_pr(script_args, argv, reqs)
    started = datetime.fromtimestamp(t0, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    with con:
        inv = con.execute(
            'INSERT INTO invocations(started_at, duration_ms, session, script, command, caller, repo, pr, argv, exit_code)'
            ' VALUES (?,?,?,?,?,?,?,?,?,?)',
            (started, round((t1 - t0) * 1000, 3), os.environ.get('CLAUDE_CODE_SESSION_ID'), script, command,
             os.environ.get('GH_LOG_CALLER') or None, repo, pr, json.dumps(redact(argv), ensure_ascii=False), rc)
        ).lastrowid
        for seq, r in enumerate(reqs, 1):
            u = urllib.parse.urlsplit(r['url'] or '')
            method, host, path = r['method'] or '?', u.hostname or '', u.path or ''
            api = 'graphql' if host == API and path == '/graphql' else 'rest' if host == API else 'other'
            qid, params = None, []
            if api == 'graphql':
                doc, var = gql_body(r['body'])
                intent, op, cost = gql_info(doc, var) if doc else ('query', None, 1)
                if intent == 'query' and doc:
                    qid = query_id(con, 'graphql', doc)
                    params = [(k, json.dumps(v, ensure_ascii=False)) for k, v in var.items()]
                sec = 5 if intent == 'mutation' else 1
            else:
                intent = 'query' if method in READ else 'mutation'
                op = f'{method} {rest_template(path)}' if api == 'rest' else f'{method} {host}'
                cost = (0 if path == '/rate_limit' else 1) if api == 'rest' else 0
                sec = (1 if method in READ else 5) if api == 'rest' else 0
                if api == 'rest' and intent == 'query':   # other hosts: signed URLs, keep nothing
                    qid = query_id(con, 'rest', op)
                    params = urllib.parse.parse_qsl(u.query, keep_blank_values=True)
            h, cache = r['headers'], 'etag' if r['status'] == 304 else None
            if gh_cache_hit(r):                     # replayed from gh's disk cache: its
                h, cache = {}, 'gh'                 # rate-limit headers are from back then
            def num(k, h=h): return int(h[k]) if h.get(k, '').isdigit() else None
            rid = con.execute(
                'INSERT INTO requests(invocation_id, seq, at, duration_ms, api, intent, method, host, path, operation,'
                ' query_id, conditional, status, cache, rl_resource, rl_limit, rl_remaining, rl_used, rl_reset,'
                ' expected_cost, expected_secondary) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                (inv, seq, iso(r['at']) or started, r['took_ms'], api, intent, method, host, path, op, qid,
                 int('if-none-match' in r['req_headers'] or 'if-modified-since' in r['req_headers']),
                 r['status'], cache, h.get('x-ratelimit-resource'), num('x-ratelimit-limit'),
                 num('x-ratelimit-remaining'), num('x-ratelimit-used'), num('x-ratelimit-reset'), cost, sec)
            ).lastrowid
            con.executemany('INSERT OR REPLACE INTO request_params(request_id, name, value) VALUES (?,?,?)',
                            [(rid, k, v) for k, v in params])
    return inv

def main(a):
    sec = lambda x: float(x.replace(',', '.'))   # EPOCHREALTIME uses the locale's decimal mark
    dbg, rc, t0, t1, argv = a[0], int(a[1]), sec(a[2]), sec(a[3]), a[4:]
    with open(dbg, encoding='utf-8', errors='replace') as f: reqs = parse(f)
    script, command, script_args = ancestry()
    con = connect(DB)
    try: record(con, reqs, rc, t0, t1, argv, script, command, script_args)
    finally: con.close()

# ------------------------------------------------------------------ self-test
def self_test():
    ok = True
    def e(label, got, want):
        nonlocal ok
        print(('ok   ' if got == want else 'FAIL ') + label + ('' if got == want else f': got {got!r}, want {want!r}'))
        ok &= got == want
    ex = '''query { viewer { login repositories(first: 100) { edges { node { id
              issues(first: 50) { edges { node { id labels(first: 60) { edges { node { id name } } } } } } } } } } }'''
    e("cost: GitHub's worked example (1 + 100 + 5000 → 51)", gql_info(ex, {})[2], 51)
    th = '''query($owner:String!,$n:Int!,$endCursor:String){ repository(owner:$owner,name:"x"){ pullRequest(number:1){
      reviewThreads(first:50, after:$endCursor){ nodes{ id head: comments(first:1){ nodes{ body reactions(content:THUMBS_DOWN){ totalCount } } }
      tail: comments(last:$n){ totalCount nodes{ body } } } } } } }'''
    e('cost: thread query, n from variables (1 + 50 + 50)', gql_info(th, {'n': 3}), ('query', 'repository.pullRequest.reviewThreads', 1))
    e("cost: a connection's own limit scales only its children", gql_info(th, {'n': 100})[2], 1)
    e('cost: limit from a variable (1 + 100 + 100*10 → 11)',
      gql_info('query($k:Int){ a(first:$k){ nodes{ b(first:10){ nodes{ c(first:10){ totalCount } } } } } }', {'k': 100})[2], 11)
    e('mutation, root field as operation', gql_info('mutation($t:ID!){ resolveReviewThread(input:{threadId:$t}){ thread{ isResolved } } }', {}),
      ('mutation', 'resolveReviewThread', 1))
    e('named operation', gql_info('query PullRequestForBranch($o: String!) { repository(owner: $o, name: "r") { id } }', {})[:2],
      ('query', 'PullRequestForBranch'))
    e('shorthand query with a fragment', gql_info('{ node(id:"x"){ ... on Commit { history(first:3){ totalCount } } } }', {})[1],
      'node.Commit.history')
    e('a mutation after a fragment is still a mutation',
      gql_info('fragment C on IssueComment { id } mutation Add($b:String!){ addComment(input:{body:$b}){ ...C } }', {})[:2],
      ('mutation', 'Add'))
    e('a mutation after a query is still a mutation', gql_info('query A { viewer { id } } mutation B { x { id } }', {})[0], 'mutation')
    e('"""mutation""" in a description is not', gql_info('"""mutation""" query Q { viewer { id } }', {})[:2], ('query', 'Q'))
    e('no operation at all: kept out like a mutation', gql_info('fragment F on X { id }', {})[0], 'mutation')
    e("an unnamed operation is labelled by its own fields, not a fragment's",
      gql_info('fragment C on X { id url } mutation($b:String!){ addComment(input:{body:$b}){ ...C } }', {})[1], 'addComment')
    e('template: repo, number, sha', rest_template('/repos/o/r/commits/' + 'a' * 40 + '/check-runs'), '/repos/{owner}/{repo}/commits/{sha}/check-runs')
    e('template: Link page by repo id', rest_template('/repositories/1444724239/issues/12/comments'), '/repos/{owner}/{repo}/issues/{n}/comments')
    e('template: compare', rest_template('/repos/o/r/compare/abc1234...' + 'b' * 40), '/repos/{owner}/{repo}/compare/{base}...{head}')
    e('redact: field values, headers, bodies',
      redact(['api', '-X', 'POST', 'x', '-f', 'body=secret', '-F', 'n=2', '-H', 'If-None-Match: W/"e"', '--raw-field=q=v', '-b', 'secret']),
      ['api', '-X', 'POST', 'x', '-f', 'body=…', '-F', 'n=…', '-H', 'If-None-Match: …', '--raw-field=q=…', '-b', '…'])
    e('redact: glued short flags', redact(['api', 'x', '-fbody=secret', '-HAuthorization: t']), ['api', 'x', '-fbody=…', '-HAuthorization: …'])
    e('redact: other commands keep subcommand and flag names only',
      redact(['label', 'create', 'secret-name', '--color', 'ff0000', '--description=secret', '--force']),
      ['label', 'create', '--color', '--description', '--force'])
    e('time: local offset converted to UTC', iso('2026-11-04 16:24:08.748839309 +0900 KST m=+0.04'), '2026-11-04T07:24:08.748Z')
    old = {'at': '2026-11-04 16:24:08.7 +0900 KST', 'headers': {'date': 'Wed, 04 Nov 2026 07:24:08 GMT'}}
    e('gh cache: a fresh tagged reply in KST is not a replay',
      gh_cache_hit({**old, 'req_headers': {'x-gh-cache-ttl': '24h'}, 'took_ms': 300}), False)
    e('gh cache: an untagged --cache replay (old Date, < 20 ms) is',
      gh_cache_hit({**old, 'at': '2026-11-04 17:24:08.7 +0900 KST', 'req_headers': {}, 'took_ms': 0.8}), True)
    e('gh cache: a slow untagged reply with an old Date is not (clock skew)',
      gh_cache_hit({**old, 'at': '2026-11-04 17:24:08.7 +0900 KST', 'req_headers': {}, 'took_ms': 300}), False)
    e('duration units', [duration_ms('475.5ms'), duration_ms('531.781µs'), duration_ms('1m2s')], [475.5, 0.532, 62000.0])
    e('repo/pr from a script command', repo_pr(['sync', 'o/r', '12', '--loop'], [], []), ('o/r', 12))
    e('repo/pr from a PR URL', repo_pr(['resolve', 'https://github.com/o/r/pull/7'], [], []), ('o/r', 7))
    e('repo/pr from gh --repo', repo_pr([], ['pr', 'checks', '12', '--repo', 'o/r'], []), ('o/r', 12))
    e('repo from a REST path', repo_pr([], [], [{'url': 'https://api.github.com/repos/o/r/commits?x=1'}]), ('o/r', None))
    return 0 if ok else 1

if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']: sys.exit(self_test())
    try: main(sys.argv[1:])
    except Exception:   # noqa: BLE001 — logging must never fail the gh call it records
        try:
            with open(DB + '.errors', 'a') as f:
                f.write(f'{datetime.now(timezone.utc).isoformat()} {sys.argv[1:5]}\n{traceback.format_exc()}\n')
        except OSError: pass
