const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const crypto = require('crypto');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const AGENT_DIR = process.env.AGENT_DIR || path.join(__dirname, '..', 'agent');
const CACHE_DIR = process.env.POC_CACHE_DIR || path.join(__dirname, '..', 'cache');
const CHECKS = ['lint', 'typecheck', 'test', 'build'];

// How many agent containers may run at once. Each one is a full install plus a
// test suite plus its own Postgres and Redis, so the ceiling is the box, not
// the design: ~2 on a t3.xlarge, more if you size up. Runs beyond it queue.
const MAX_CONCURRENT = Math.max(1, Number(process.env.MAX_CONCURRENT || 2));

// The plugin form on the instance; override to `docker-compose` on a machine
// that only has the standalone binary.
const COMPOSE = (process.env.DOCKER_COMPOSE || 'docker compose').split(/\s+/);
const [COMPOSE_BIN, ...COMPOSE_ARGS] = COMPOSE;

// In-memory only. Restarting the server loses history — fine for a POC,
// and an honest thing to say out loud during the demo.
const runs = new Map();
const queue = [];
let active = 0;

function newRun({ repo, ticket, task }) {
  const id = crypto.randomBytes(4).toString('hex');
  const run = {
    id, repo, ticket, task,
    state: 'queued',
    phase: 'queued',
    checks: Object.fromEntries(CHECKS.map((c) => [c, 'pending'])),
    prUrl: null,
    lines: [],
    subscribers: new Set(),
    createdAt: Date.now(),
    startedAt: null,
    endedAt: null,
  };
  runs.set(id, run);
  return run;
}

function emit(run, event) {
  for (const res of run.subscribers) {
    res.write(`data: ${JSON.stringify(event)}\n\n`);
  }
}

function snapshot(run) {
  const { id, repo, ticket, task, state, phase, checks, prUrl, createdAt, startedAt, endedAt } = run;
  const queuePosition = state === 'queued' ? queue.indexOf(run) + 1 : 0;
  return {
    id, repo, ticket, task, state, phase, checks, prUrl,
    createdAt, startedAt, endedAt, queuePosition,
  };
}

// Read the runner's own output to drive the UI. The runner prints
// "=== phase ===" markers and "PASS <check>" / "FAIL <check>" lines.
function ingest(run, raw) {
  const line = raw.replace(/\s+$/, '');
  if (!line) return;

  run.lines.push(line);
  if (run.lines.length > 4000) run.lines.shift();
  emit(run, { type: 'line', line });

  const phase = line.match(/^===\s*(.+?)\s*===$/);
  if (phase) {
    run.phase = phase[1];
    if (/^validating/.test(phase[1])) run.state = 'validating';
    else if (/^running agent/.test(phase[1])) run.state = 'coding';
    emit(run, { type: 'state', run: snapshot(run) });
  }

  const check = line.match(/^(PASS|FAIL)\s+(\w+)$/);
  if (check && run.checks[check[2]] !== undefined) {
    run.checks[check[2]] = check[1] === 'PASS' ? 'pass' : 'fail';
    emit(run, { type: 'state', run: snapshot(run) });
  }

  const pr = line.match(/https:\/\/github\.com\/\S+\/pull\/\d+/);
  if (pr) {
    run.prUrl = pr[0];
    emit(run, { type: 'state', run: snapshot(run) });
  }
}

// One compose project per run. Without this, parallel runs would share a single
// `agent` project and therefore a single Postgres and Redis — two test suites
// truncating each other's tables. `-p` gives each run its own sidecars; the
// caches stay shared because they are bind mounts, not project-scoped volumes.
function project(run) {
  return `poc-${run.id}`;
}

function start(run) {
  run.state = 'starting';
  run.phase = 'starting up';
  run.startedAt = Date.now();
  active += 1;
  emit(run, { type: 'state', run: snapshot(run) });

  const args = [
    ...COMPOSE_ARGS, '-p', project(run), 'run', '--rm', '--no-TTY', 'agent',
    run.repo, run.ticket, run.task,
  ];
  const child = spawn(COMPOSE_BIN, args, {
    cwd: AGENT_DIR,
    // RUN_ID names this run's worktree and log directory inside the shared
    // cache; it has to be unique per concurrent run, so it is the run id
    // rather than the runner's timestamp fallback.
    env: { ...process.env, RUN_ID: run.id, POC_CACHE_DIR: CACHE_DIR },
  });

  let stdoutRest = '';
  let stderrRest = '';
  const pump = (chunk, restRef, setRest) => {
    const text = restRef + chunk.toString();
    const parts = text.split('\n');
    setRest(parts.pop());
    for (const p of parts) ingest(run, p);
  };

  child.stdout.on('data', (c) => pump(c, stdoutRest, (r) => { stdoutRest = r; }));
  child.stderr.on('data', (c) => pump(c, stderrRest, (r) => { stderrRest = r; }));

  child.on('error', (err) => {
    ingest(run, `harness error: ${err.message}`);
    run.state = 'error';
  });

  child.on('close', (code) => {
    if (stdoutRest) ingest(run, stdoutRest);
    if (stderrRest) ingest(run, stderrRest);
    if (run.state !== 'error') {
      run.state = code === 0 ? 'passed' : 'failed';
      run.phase = code === 0 ? 'pull request opened' : `stopped (exit ${code})`;
    }
    run.endedAt = Date.now();
    emit(run, { type: 'state', run: snapshot(run) });
    emit(run, { type: 'done' });
    finish(run);
  });
}

// `compose run` removes the agent container but leaves this project's Postgres
// and Redis behind. Without a teardown they accumulate one pair per run until
// the box runs out of memory.
function finish(run) {
  active = Math.max(0, active - 1);
  const down = spawn(COMPOSE_BIN, [...COMPOSE_ARGS, '-p', project(run), 'down', '-v', '--remove-orphans'], {
    cwd: AGENT_DIR,
    env: { ...process.env, POC_CACHE_DIR: CACHE_DIR },
    stdio: 'ignore',
  });
  down.on('error', () => {});
  drainQueue();
}

// Starts what fits, then re-labels whoever is still waiting — queue positions
// shift every time a slot frees up, and the console shows `phase` verbatim.
function drainQueue() {
  while (active < MAX_CONCURRENT && queue.length > 0) {
    start(queue.shift());
  }
  queue.forEach((run, i) => {
    const phase = `queued — position ${i + 1} (${MAX_CONCURRENT} running)`;
    if (run.phase !== phase) {
      run.phase = phase;
      emit(run, { type: 'state', run: snapshot(run) });
    }
  });
}

app.post('/api/runs', (req, res) => {
  const { repo, ticket, task } = req.body || {};
  if (!repo || !ticket || !task) {
    return res.status(400).json({ error: 'repo, ticket and task are all required' });
  }
  const run = newRun({ repo: repo.trim(), ticket: ticket.trim(), task: task.trim() });
  queue.push(run);
  drainQueue();
  res.json(snapshot(run));
});

app.get('/api/runs', (_req, res) => {
  res.json([...runs.values()].sort((a, b) => b.createdAt - a.createdAt).map(snapshot));
});

app.get('/api/capacity', (_req, res) => {
  res.json({ maxConcurrent: MAX_CONCURRENT, active, queued: queue.length });
});

// Plain text, for grepping a finished run from a script.
app.get('/api/runs/:id/log', (req, res) => {
  const run = runs.get(req.params.id);
  if (!run) return res.status(404).end();
  res.type('text/plain').send(run.lines.join('\n'));
});

app.get('/api/runs/:id/stream', (req, res) => {
  const run = runs.get(req.params.id);
  if (!run) return res.status(404).end();

  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders();

  res.write(`data: ${JSON.stringify({ type: 'state', run: snapshot(run) })}\n\n`);
  for (const line of run.lines) {
    res.write(`data: ${JSON.stringify({ type: 'line', line })}\n\n`);
  }
  if (run.endedAt) res.write(`data: ${JSON.stringify({ type: 'done' })}\n\n`);

  run.subscribers.add(res);
  const keepalive = setInterval(() => res.write(': ping\n\n'), 15000);
  req.on('close', () => {
    clearInterval(keepalive);
    run.subscribers.delete(res);
  });
});

const port = process.env.PORT || 8080;
app.listen(port, () => console.log(
  `console on :${port} (agent dir ${AGENT_DIR}, cache ${CACHE_DIR}, ${MAX_CONCURRENT} concurrent)`,
));
