const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const crypto = require('crypto');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const AGENT_DIR = process.env.AGENT_DIR || path.join(__dirname, '..', 'agent');
const CHECKS = ['lint', 'typecheck', 'test', 'build'];

// In-memory only. Restarting the server loses history — fine for a POC,
// and an honest thing to say out loud during the demo.
const runs = new Map();

function newRun({ repo, ticket, task }) {
  const id = crypto.randomBytes(4).toString('hex');
  const run = {
    id, repo, ticket, task,
    state: 'starting',
    phase: 'starting up',
    checks: Object.fromEntries(CHECKS.map((c) => [c, 'pending'])),
    prUrl: null,
    lines: [],
    subscribers: new Set(),
    startedAt: Date.now(),
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
  const { id, repo, ticket, task, state, phase, checks, prUrl, startedAt, endedAt } = run;
  return { id, repo, ticket, task, state, phase, checks, prUrl, startedAt, endedAt };
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

function start(run) {
  const args = [
    'compose', 'run', '--rm', '--no-TTY', 'agent',
    run.repo, run.ticket, run.task,
  ];
  const child = spawn('docker', args, {
    cwd: AGENT_DIR,
    env: process.env,
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
    run.endedAt = Date.now();
    emit(run, { type: 'state', run: snapshot(run) });
    emit(run, { type: 'done' });
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
  });
}

app.post('/api/runs', (req, res) => {
  const { repo, ticket, task } = req.body || {};
  if (!repo || !ticket || !task) {
    return res.status(400).json({ error: 'repo, ticket and task are all required' });
  }
  const run = newRun({ repo: repo.trim(), ticket: ticket.trim(), task: task.trim() });
  start(run);
  res.json(snapshot(run));
});

app.get('/api/runs', (_req, res) => {
  res.json([...runs.values()].sort((a, b) => b.startedAt - a.startedAt).map(snapshot));
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
app.listen(port, () => console.log(`console on :${port} (agent dir ${AGENT_DIR})`));
