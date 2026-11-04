-- gh-log.sql — the GitHub call log that bin/gh writes through gh-log.py.
--
-- invocations   one gh process (a ghx call, `gh pr checks`, an ETag probe, …)
-- requests      one HTTP exchange inside it: each page of --paginate, each call gh pr checks makes
-- queries       distinct query bodies, shared by every request that sent one
-- request_params a query's GraphQL variables or REST query-string, one row per name
--
-- Mutations (GraphQL mutation; REST POST/PATCH/PUT/DELETE) keep method, path and operation
-- name only: no body, no variables, no field values (argv keeps field names, not values).
-- Response bodies are never stored. Read through the `calls` view.
-- ponytail: no retention — a watcher logs ~1 row/s while it runs. Prune by hand when it
-- matters: delete request_params, requests, then invocations older than a cutoff; VACUUM.

PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS invocations (
  id          INTEGER PRIMARY KEY,
  started_at  TEXT    NOT NULL,   -- UTC, ISO 8601
  duration_ms REAL    NOT NULL,
  session     TEXT,               -- CLAUDE_CODE_SESSION_ID
  script      TEXT,               -- the script that ran gh: pr-state.sh, pr-ops.sh, pr-report.sh, judge-features.py; NULL = the agent
  command     TEXT,               -- the outermost script command the agent ran, e.g. "pr-ops.sh sync --loop"
  caller      TEXT,               -- GH_LOG_CALLER: the bash function that called ghx
  repo        TEXT,
  pr          INTEGER,
  argv        TEXT    NOT NULL,   -- JSON array; -f/-F/-H/--body values dropped
  exit_code   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS queries (
  id     INTEGER PRIMARY KEY,
  sha256 TEXT NOT NULL UNIQUE,
  api    TEXT NOT NULL,           -- graphql: the document as sent; rest: "GET <path template>"
  body   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS requests (
  id                 INTEGER PRIMARY KEY,
  invocation_id      INTEGER NOT NULL REFERENCES invocations(id),
  seq                INTEGER NOT NULL,   -- order inside the invocation
  at                 TEXT    NOT NULL,
  duration_ms        REAL,
  api                TEXT    NOT NULL,   -- rest | graphql | other (non-API hosts, e.g. log downloads)
  intent             TEXT    NOT NULL,   -- query | mutation
  method             TEXT    NOT NULL,
  host               TEXT    NOT NULL,
  path               TEXT    NOT NULL,   -- without the query string
  operation          TEXT,               -- graphql: operation name, else the path to its first connection
                                         -- or its root fields; rest: "METHOD /path/{template}"
  query_id           INTEGER REFERENCES queries(id),   -- NULL for mutations
  conditional        INTEGER NOT NULL,   -- sent If-None-Match / If-Modified-Since
  status             INTEGER,            -- NULL: no response (network error)
  cache              TEXT,               -- etag: 304 Not Modified; gh: replayed from gh's own
                                         -- disk cache, no network call; NULL: served fresh
  rl_resource        TEXT,               -- x-ratelimit-* response headers as received (NULL on a gh-cache replay)
  rl_limit           INTEGER,
  rl_remaining       INTEGER,            -- after this request
  rl_used            INTEGER,
  rl_reset           INTEGER,
  expected_cost      INTEGER NOT NULL,   -- primary points if served fresh: REST 1 (/rate_limit 0),
                                         -- GraphQL by GitHub's published formula, other hosts 0
  expected_secondary INTEGER NOT NULL,   -- secondary-limit points: read 1, write 5 (GraphQL: mutation 5)
  UNIQUE (invocation_id, seq)
);

CREATE TABLE IF NOT EXISTS request_params (
  request_id INTEGER NOT NULL REFERENCES requests(id),
  name       TEXT    NOT NULL,
  value      TEXT,                 -- GraphQL variables as JSON; query-string values raw
  PRIMARY KEY (request_id, name)
);

CREATE INDEX IF NOT EXISTS requests_invocation ON requests(invocation_id);
CREATE INDEX IF NOT EXISTS requests_window ON requests(rl_resource, rl_reset, rl_used);

-- calls: one row per request, with what the headers imply.
--   cached          `cache` is set: a 304 (GitHub doesn't count it) or a gh-cache replay.
--   used_step       x-ratelimit-used minus the previous logged request in the same bucket
--                   window, ordered by `used` (server order, so concurrent loops don't skew it;
--                   free requests sort after the paid one that reached the same value).
--   actual_cost     0 when cached or free (/rate_limit, other hosts). Otherwise REST: 1, or 0
--                   when refused at an empty bucket
--                   — GitHub's flat price, exact. GraphQL: used_step. ponytail: that is exact only
--                   if nothing outside these skills spent GraphQL points in between, so read it
--                   as an upper bound; NULL for the first GraphQL request seen in a window, or a
--                   negative step. GitHub's regions keep separate counters, so a request can land
--                   in another region's window (its own reset and `used`) and start a new one.
--   remaining_before rl_remaining + actual_cost (expected_cost where actual is unknown).
CREATE VIEW IF NOT EXISTS calls AS
WITH w AS (
  SELECT r.*,
         r.cache IS NOT NULL OR r.expected_cost = 0 AS free,
         r.rl_used - LAG(r.rl_used) OVER (
           PARTITION BY r.rl_resource, r.rl_reset
           ORDER BY r.rl_used, r.cache IS NOT NULL OR r.expected_cost = 0, r.id) AS used_step
  FROM requests r
), c AS (
  SELECT w.*,
         CASE
           WHEN w.status IS NULL OR w.free THEN 0
           WHEN w.api = 'rest' THEN
             CASE WHEN w.rl_remaining = 0 AND w.status IN (403, 429) THEN 0 ELSE 1 END
           WHEN w.api = 'graphql' AND w.used_step >= 0 THEN w.used_step
         END AS actual_cost
  FROM w
)
SELECT c.id, c.invocation_id, i.started_at, i.session, i.script, i.command, i.caller,
       i.repo, i.pr, i.argv, i.exit_code, c.seq, c.at, c.duration_ms, c.api, c.intent, c.method,
       c.host, c.path, c.operation, c.query_id, c.conditional, c.status, c.cache,
       c.cache IS NOT NULL AS cached,
       c.rl_resource, c.rl_limit, c.rl_remaining, c.rl_used, c.rl_reset, c.used_step,
       c.rl_remaining + COALESCE(c.actual_cost, c.expected_cost) AS remaining_before,
       c.expected_cost, c.actual_cost, c.expected_secondary
FROM c JOIN invocations i ON i.id = c.invocation_id;

PRAGMA user_version = 1;
