// API Gateway (HTTP API, Lambda proxy integration) handler replacing the
// spawn()-and-tail-stdout half of server/index.js. It never runs the agent
// itself — it only reads/writes DynamoDB and enqueues to SQS, which is why
// its IAM role (infra/fargate/iam/api-role-policy.json) has no ecs:RunTask,
// no S3 cache access, and no GitHub token.
//
// The console's SSE stream (`new EventSource(...)`) does not survive this
// split cleanly — API Gateway + Lambda has no long-lived connection to hold
// one open across a run that can last many minutes. server/public/index.html
// has been switched to polling GET /api/runs/:id every second instead. See
// docs/lambda-migration.md §4.5.
//
// Routes (API Gateway HTTP API, $default stage, path + method as configured
// in infra/fargate/setup.sh):
//   POST /api/runs              -> enqueue a run, return its initial snapshot
//   GET  /api/runs              -> list runs, newest first
//   GET  /api/runs/:id          -> one run's current snapshot
//   GET  /api/runs/:id/log      -> plain-text log lines accumulated so far
//   GET  /api/capacity          -> {maxConcurrent} for the console's own display
//
// Env:
//   RUN_TABLE       DynamoDB table holding run state (default poc-agent-runs)
//   RUN_QUEUE_URL   SQS queue the dispatcher Lambda consumes
//   MAX_CONCURRENT  advisory only here — the real ceiling is the dispatcher's
//                   reserved concurrency / the SQS consumer's batch size

const crypto = require('crypto');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, PutCommand, GetCommand, ScanCommand } = require('@aws-sdk/lib-dynamodb');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const { CloudWatchLogsClient, GetLogEventsCommand } = require('@aws-sdk/client-cloudwatch-logs');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sqs = new SQSClient({});
const cwl = new CloudWatchLogsClient({});

const RUN_TABLE = process.env.RUN_TABLE || 'poc-agent-runs';
const RUN_QUEUE_URL = process.env.RUN_QUEUE_URL;
const MAX_CONCURRENT = Math.max(1, Number(process.env.MAX_CONCURRENT || 2));
const CHECKS = ['lint', 'typecheck', 'test', 'build'];

const json = (statusCode, body) => ({
  statusCode,
  headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*' },
  body: JSON.stringify(body),
});

const text = (statusCode, body) => ({
  statusCode,
  headers: { 'content-type': 'text/plain', 'access-control-allow-origin': '*' },
  body,
});

function snapshot(run) {
  const { id, repo, ticket, task, state, phase, checks, prUrl, createdAt, startedAt, endedAt } = run;
  return { id, repo, ticket, task, state, phase, checks, prUrl, createdAt, startedAt, endedAt };
}

async function createRun(body) {
  const { repo, ticket, task } = JSON.parse(body || '{}');
  if (!repo || !ticket || !task) {
    return json(400, { error: 'repo, ticket and task are all required' });
  }
  const id = crypto.randomBytes(4).toString('hex');
  const run = {
    id, repo: repo.trim(), ticket: ticket.trim(), task: task.trim(),
    state: 'queued', phase: 'queued',
    checks: Object.fromEntries(CHECKS.map((c) => [c, 'pending'])),
    prUrl: null,
    lines: [],
    createdAt: Date.now(), startedAt: null, endedAt: null,
  };
  await ddb.send(new PutCommand({ TableName: RUN_TABLE, Item: run }));
  // The dispatcher Lambda (lambda/dispatcher) consumes this and calls
  // ecs:RunTask — see infra/fargate/setup.sh for the event source mapping.
  await sqs.send(new SendMessageCommand({
    QueueUrl: RUN_QUEUE_URL,
    MessageBody: JSON.stringify({ runId: id, repo: run.repo, ticket: run.ticket, task: run.task }),
  }));
  return json(200, snapshot(run));
}

async function listRuns() {
  // A Scan is fine at POC volume (dozens of items); switch to a GSI on
  // createdAt if this table ever holds more than a page's worth.
  const { Items = [] } = await ddb.send(new ScanCommand({ TableName: RUN_TABLE }));
  Items.sort((a, b) => b.createdAt - a.createdAt);
  return json(200, Items.map(snapshot));
}

async function getRun(id) {
  const { Item } = await ddb.send(new GetCommand({ TableName: RUN_TABLE, Key: { id } }));
  if (!Item) return json(404, { error: 'not found' });
  return json(200, snapshot(Item));
}

const LOG_GROUP = process.env.LOG_GROUP || '/ecs/poc-agent-run';

// The full log was never in DynamoDB to begin with — the awslogs driver on
// the Fargate task (infra/fargate/task-definition.json) already ships every
// line of container stdout to CloudWatch Logs, and the dispatcher records
// which stream (`agent/agent/<task-id>`) on the run item as soon as it starts
// the task. This just reads that stream back. See docs/lambda-migration.md §4.5.
async function getLog(id) {
  const { Item } = await ddb.send(new GetCommand({ TableName: RUN_TABLE, Key: { id } }));
  if (!Item) return text(404, '');
  if (!Item.logStream) return text(200, ''); // not dispatched yet
  try {
    const { events } = await cwl.send(new GetLogEventsCommand({
      logGroupName: LOG_GROUP,
      logStreamName: Item.logStream,
      startFromHead: true,
      limit: 10000,
    }));
    return text(200, (events || []).map((e) => e.message).join('\n'));
  } catch (err) {
    // Most common cause: the stream doesn't exist yet because the task
    // hasn't emitted its first line. Not an error worth surfacing as one.
    if (err.name === 'ResourceNotFoundException') return text(200, '');
    throw err;
  }
}

exports.handler = async (event) => {
  const method = event.requestContext?.http?.method || event.httpMethod;
  const path = event.rawPath || event.path || '';
  const id = event.pathParameters?.id;

  try {
    if (method === 'POST' && path === '/api/runs') return await createRun(event.body);
    if (method === 'GET' && path === '/api/runs') return await listRuns();
    if (method === 'GET' && id && path.endsWith('/log')) return await getLog(id);
    if (method === 'GET' && id) return await getRun(id);
    if (method === 'GET' && path === '/api/capacity') return json(200, { maxConcurrent: MAX_CONCURRENT });
    return json(404, { error: 'no such route' });
  } catch (err) {
    return json(500, { error: err.message });
  }
};
