// SQS-triggered: takes one queued run and launches the Fargate task that
// actually does the work (infra/fargate/task-definition.json). This is the
// serverless replacement for server/index.js's drainQueue()/start() — the
// concurrency ceiling here is the SQS trigger's ReservedConcurrentExecutions
// plus the batch size, not a box's RAM (docs/lambda-migration.md, "MAX_CONCURRENT
// stops being a lie").
//
// Env:
//   CLUSTER_ARN          ECS cluster to run tasks in
//   TASK_DEFINITION      family[:revision], e.g. poc-agent-run
//   SUBNET_IDS           comma-separated subnet ids (public subnet with
//                        auto-assign public IP — no NAT gateway; see
//                        docs/lambda-migration.md §7.4 on why that $33/mo is
//                        worth avoiding)
//   SECURITY_GROUP_IDS   comma-separated security group ids
//   RUN_TABLE            DynamoDB table to mark dispatched runs in

const { ECSClient, RunTaskCommand } = require('@aws-sdk/client-ecs');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, UpdateCommand } = require('@aws-sdk/lib-dynamodb');

const ecs = new ECSClient({});
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const RUN_TABLE = process.env.RUN_TABLE || 'poc-agent-runs';

exports.handler = async (event) => {
  const failures = [];

  for (const record of event.Records) {
    const { runId, repo, ticket, task } = JSON.parse(record.body);
    try {
      const result = await ecs.send(new RunTaskCommand({
        cluster: process.env.CLUSTER_ARN,
        taskDefinition: process.env.TASK_DEFINITION,
        launchType: 'FARGATE',
        networkConfiguration: {
          awsvpcConfiguration: {
            subnets: process.env.SUBNET_IDS.split(','),
            securityGroups: process.env.SECURITY_GROUP_IDS.split(','),
            assignPublicIp: 'ENABLED',
          },
        },
        overrides: {
          containerOverrides: [{
            name: 'agent',
            // Positional args after the Dockerfile's ENTRYPOINT, exactly like
            // `docker compose run --rm agent <repo> <ticket> <task>` today.
            command: [repo, ticket, task],
            environment: [{ name: 'RUN_ID', value: runId }],
          }],
        },
      }));

      const taskArn = result.tasks?.[0]?.taskArn;
      if (!taskArn) {
        const reason = result.failures?.[0]?.reason || 'no task returned';
        throw new Error(`RunTask failed: ${reason}`);
      }
      const taskId = taskArn.split('/').pop();
      // awslogs-stream-prefix "agent" + container name "agent" + task id —
      // see infra/fargate/task-definition.json. lambda/api's getLog reads
      // this stream from CloudWatch Logs directly; nothing tails it here.
      await ddb.send(new UpdateCommand({
        TableName: RUN_TABLE,
        Key: { id: runId },
        UpdateExpression: 'SET #st = :s, #ph = :p, taskArn = :a, logStream = :l',
        ExpressionAttributeNames: { '#st': 'state', '#ph': 'phase' },
        ExpressionAttributeValues: {
          ':s': 'starting', ':p': 'starting up',
          ':a': taskArn, ':l': `agent/agent/${taskId}`,
        },
      }));
    } catch (err) {
      console.error(`dispatch failed for run ${runId}:`, err);
      await ddb.send(new UpdateCommand({
        TableName: RUN_TABLE,
        Key: { id: runId },
        UpdateExpression: 'SET #st = :s, #ph = :p',
        ExpressionAttributeNames: { '#st': 'state', '#ph': 'phase' },
        ExpressionAttributeValues: { ':s': 'error', ':p': `dispatch failed: ${err.message}` },
      })).catch(() => {});
      // Report back to SQS so this message alone is retried/DLQ'd — a bad
      // RunTask call for one run must not block every other run behind it
      // in the same batch.
      failures.push({ itemIdentifier: record.messageId });
    }
  }

  return { batchItemFailures: failures };
};
