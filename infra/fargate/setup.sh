#!/usr/bin/env bash
# Provisions the serverless replacement for launch-instance.sh +
# ec2-userdata.sh: S3 cache bucket, DynamoDB tables, SQS queue, IAM roles,
# ECS cluster + task definition, the three Lambda functions, API Gateway, the
# EventBridge rule that triggers publish, and the static console. See
# docs/lambda-migration.md for the design this implements (Option B: Lambda
# control plane + Fargate worker).
#
# Prerequisites (one-time, not handled here):
#   - AWS credentials active in this shell with room to create IAM roles,
#     ECS/Lambda/API Gateway/EventBridge resources (an admin-ish role for
#     first-time setup; the runtime roles this script creates are narrow).
#   - Docker running locally (build-images.sh needs it).
#   - node, npm, zip, jq on PATH.
#   - BEDROCK_MODEL_ID from README step 1.
#
# This is a from-scratch provisioning script, not a hardened one: it checks
# for existing resources before creating most of them, but re-run it after
# reading what failed rather than expecting it to be idempotent under every
# partial-failure state. That matches launch-instance.sh's own scope.
#
# Usage:
#   BEDROCK_MODEL_ID=... GITHUB_ORG=... ./setup.sh
#
# Optional env: AWS_REGION (us-east-1), CACHE_BUCKET, SITE_BUCKET,
#   BASE_BRANCH (main), MAX_TURNS (40)

set -euo pipefail
: "${BEDROCK_MODEL_ID:?set BEDROCK_MODEL_ID — see README step 1}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GITHUB_ORG="${GITHUB_ORG:-drcastanoj}"
BASE_BRANCH="${BASE_BRANCH:-main}"
MAX_TURNS="${MAX_TURNS:-40}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IAM_DIR="$SCRIPT_DIR/iam"

log() { printf '\n=== %s ===\n' "$*"; }

for bin in aws docker node npm zip jq; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin"; exit 1; }
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CACHE_BUCKET="${CACHE_BUCKET:-poc-agent-cache-${ACCOUNT_ID}}"
SITE_BUCKET="${SITE_BUCKET:-poc-agent-console-${ACCOUNT_ID}}"
CLUSTER_NAME="poc-agent-cluster"
LOG_GROUP="/ecs/poc-agent-run"
RUN_TABLE="poc-agent-runs"
LOCK_TABLE="poc-agent-locks"
QUEUE_NAME="poc-agent-runs"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "account: $ACCOUNT_ID   region: $AWS_REGION"
echo "cache bucket: $CACHE_BUCKET   site bucket: $SITE_BUCKET"

# --- 1. S3 cache bucket ------------------------------------------------------
log "S3 cache bucket"
if ! aws s3api head-bucket --bucket "$CACHE_BUCKET" 2>/dev/null; then
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$CACHE_BUCKET" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$CACHE_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  aws s3api put-bucket-lifecycle-configuration --bucket "$CACHE_BUCKET" --lifecycle-configuration '{
    "Rules": [{"ID": "expire-run-handoffs", "Status": "Enabled",
      "Filter": {"Prefix": "runs/"}, "Expiration": {"Days": 7}}]
  }'
  echo "created $CACHE_BUCKET (runs/ expires after 7 days; repos/ and deps/ kept indefinitely)"
else
  echo "reusing $CACHE_BUCKET"
fi

# --- 2. DynamoDB tables -------------------------------------------------------
log "DynamoDB tables"
aws dynamodb describe-table --table-name "$RUN_TABLE" --region "$AWS_REGION" >/dev/null 2>&1 || {
  aws dynamodb create-table --region "$AWS_REGION" --table-name "$RUN_TABLE" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --region "$AWS_REGION" --table-name "$RUN_TABLE"
  echo "created $RUN_TABLE"
}
aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$AWS_REGION" >/dev/null 2>&1 || {
  aws dynamodb create-table --region "$AWS_REGION" --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=pk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --region "$AWS_REGION" --table-name "$LOCK_TABLE"
  aws dynamodb update-time-to-live --region "$AWS_REGION" --table-name "$LOCK_TABLE" \
    --time-to-live-specification "Enabled=true,AttributeName=expires" >/dev/null
  echo "created $LOCK_TABLE (TTL on 'expires')"
}

# --- 3. SQS queue --------------------------------------------------------------
log "SQS queue"
QUEUE_URL=$(aws sqs get-queue-url --region "$AWS_REGION" --queue-name "$QUEUE_NAME" \
  --query QueueUrl --output text 2>/dev/null || echo "None")
if [ "$QUEUE_URL" = "None" ]; then
  QUEUE_URL=$(aws sqs create-queue --region "$AWS_REGION" --queue-name "$QUEUE_NAME" \
    --attributes VisibilityTimeout=60 --query QueueUrl --output text)
  echo "created $QUEUE_URL"
else
  echo "reusing $QUEUE_URL"
fi
QUEUE_ARN=$(aws sqs get-queue-attributes --region "$AWS_REGION" --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

# --- 4. IAM roles --------------------------------------------------------------
# Five roles, each scoped to exactly what docs/lambda-migration.md §4.6 step
# 11 says it should have. Substitute the cache bucket name into the policy
# templates before applying them.
log "IAM roles"
ECS_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

create_role() {
  local name="$1" trust="$2" policy_file="$3"
  aws iam get-role --role-name "$name" >/dev/null 2>&1 || {
    aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" >/dev/null
    echo "created role $name"
  }
  local doc
  doc=$(sed -e "s/REPLACE_WITH_CACHE_BUCKET/${CACHE_BUCKET}/g" \
            -e "s/REPLACE_WITH_ACCOUNT_ID/${ACCOUNT_ID}/g" "$policy_file")
  aws iam put-role-policy --role-name "$name" --policy-name "${name}-policy" \
    --policy-document "$doc" >/dev/null
}

create_role poc-agent-task-execution-role "$ECS_TRUST" "$IAM_DIR/task-execution-role-policy.json"
create_role poc-agent-task-role           "$ECS_TRUST" "$IAM_DIR/task-role-policy.json"
create_role poc-agent-dispatcher-role     "$LAMBDA_TRUST" "$IAM_DIR/dispatcher-role-policy.json"
create_role poc-agent-api-role            "$LAMBDA_TRUST" "$IAM_DIR/api-role-policy.json"
create_role poc-agent-publish-role        "$LAMBDA_TRUST" "$IAM_DIR/publish-role-policy.json"

# Basic Lambda execution (CloudWatch Logs for the function's own log group,
# distinct from the ECS task's) isn't in any of our custom policies above.
for role in poc-agent-dispatcher-role poc-agent-api-role poc-agent-publish-role; do
  aws iam attach-role-policy --role-name "$role" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
done

TASK_EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/poc-agent-task-execution-role"
TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/poc-agent-task-role"
DISPATCHER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/poc-agent-dispatcher-role"
API_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/poc-agent-api-role"
PUBLISH_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/poc-agent-publish-role"

log "waiting for IAM roles to propagate"
sleep 10

# --- 5. network: default VPC, a public subnet, one no-inbound SG ------------
# No NAT gateway — deliberately. See docs/lambda-migration.md §7.4: a NAT
# gateway is a ~$33/mo fixed cost this design has no other reason to pay,
# since nothing here needs a private subnet. The task gets a public IP only
# so it can reach GitHub, Bedrock, S3, DynamoDB and SQS; the security group
# still has no inbound rules at all.
log "network"
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" != "None" ] || { echo "no default VPC — pass subnets/SG explicitly and adapt this section"; exit 1; }
SUBNET_IDS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters Name=group-name,Values=poc-agent-fargate Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name poc-agent-fargate --description "poc-agent Fargate tasks — outbound only" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  echo "created $SG_ID (no ingress rules)"
else
  echo "reusing $SG_ID"
fi
echo "subnets: $SUBNET_IDS"

# --- 6. container images -----------------------------------------------------
log "building and pushing images"
"$SCRIPT_DIR/build-images.sh" "$ACCOUNT_ID" "$AWS_REGION"

# --- 7. ECS cluster + task definition -----------------------------------------
log "ECS cluster"
aws ecs describe-clusters --region "$AWS_REGION" --clusters "$CLUSTER_NAME" \
  --query 'clusters[0].status' --output text 2>/dev/null | grep -q ACTIVE || {
  aws ecs create-cluster --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" >/dev/null
  echo "created cluster $CLUSTER_NAME"
}

log "CloudWatch log group"
aws logs describe-log-groups --region "$AWS_REGION" --log-group-name-prefix "$LOG_GROUP" \
  --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -qx "$LOG_GROUP" || {
  aws logs create-log-group --region "$AWS_REGION" --log-group-name "$LOG_GROUP"
  echo "created $LOG_GROUP"
}

log "registering task definition"
TASK_DEF=$(jq \
  --arg exec_role "$TASK_EXEC_ROLE_ARN" \
  --arg task_role "$TASK_ROLE_ARN" \
  --arg image "${REGISTRY}/poc-agent:latest" \
  --arg region "$AWS_REGION" \
  --arg model "$BEDROCK_MODEL_ID" \
  --arg org "$GITHUB_ORG" \
  --arg base "$BASE_BRANCH" \
  --arg turns "$MAX_TURNS" \
  --arg bucket "$CACHE_BUCKET" \
  --arg account "$ACCOUNT_ID" \
  '.executionRoleArn = $exec_role | .taskRoleArn = $task_role
   | .containerDefinitions[0].image = $image
   | (.containerDefinitions[0].environment[] | select(.name=="AWS_REGION") .value) = $region
   | (.containerDefinitions[0].environment[] | select(.name=="BEDROCK_MODEL_ID") .value) = $model
   | (.containerDefinitions[0].environment[] | select(.name=="GITHUB_ORG") .value) = $org
   | (.containerDefinitions[0].environment[] | select(.name=="BASE_BRANCH") .value) = $base
   | (.containerDefinitions[0].environment[] | select(.name=="MAX_TURNS") .value) = $turns
   | (.containerDefinitions[0].environment[] | select(.name=="CACHE_BUCKET") .value) = $bucket
   | (.containerDefinitions[0].secrets[] | select(.name=="GH_TOKEN") .valueFrom) =
       "arn:aws:ssm:\($region):\($account):parameter/poc/github-token-read"
   | (.containerDefinitions[] | select(.name=="postgres") .logConfiguration.options."awslogs-region") = $region
   | (.containerDefinitions[] | select(.name=="redis") .logConfiguration.options."awslogs-region") = $region
   | (.containerDefinitions[0].logConfiguration.options."awslogs-region") = $region' \
  "$SCRIPT_DIR/task-definition.json")
aws ecs register-task-definition --region "$AWS_REGION" --cli-input-json "$TASK_DEF" >/dev/null
echo "registered poc-agent-run"

CLUSTER_ARN="arn:aws:ecs:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"

# --- 8. Lambda functions ------------------------------------------------------
log "packaging api + dispatcher"
"$SCRIPT_DIR/build-lambda-zips.sh"

deploy_zip_function() {
  local name="$1" zip="$2" role_arn="$3" timeout="$4" memory="$5" env_json="$6"
  if aws lambda get-function --region "$AWS_REGION" --function-name "$name" >/dev/null 2>&1; then
    aws lambda update-function-code --region "$AWS_REGION" --function-name "$name" \
      --zip-file "fileb://$zip" >/dev/null
    aws lambda wait function-updated --region "$AWS_REGION" --function-name "$name"
    aws lambda update-function-configuration --region "$AWS_REGION" --function-name "$name" \
      --environment "$env_json" --timeout "$timeout" --memory-size "$memory" >/dev/null
  else
    aws lambda create-function --region "$AWS_REGION" --function-name "$name" \
      --runtime nodejs20.x --handler index.handler --role "$role_arn" \
      --zip-file "fileb://$zip" --timeout "$timeout" --memory-size "$memory" \
      --environment "$env_json" >/dev/null
  fi
  echo "deployed $name"
}

log "lambda-api"
deploy_zip_function poc-agent-api /tmp/poc-agent-lambda-api.zip "$API_ROLE_ARN" 10 256 \
  "{\"Variables\":{\"RUN_TABLE\":\"$RUN_TABLE\",\"RUN_QUEUE_URL\":\"$QUEUE_URL\",\"LOG_GROUP\":\"$LOG_GROUP\",\"MAX_CONCURRENT\":\"2\"}}"

log "lambda-dispatcher"
deploy_zip_function poc-agent-dispatcher /tmp/poc-agent-lambda-dispatcher.zip "$DISPATCHER_ROLE_ARN" 30 256 \
  "{\"Variables\":{\"CLUSTER_ARN\":\"$CLUSTER_ARN\",\"TASK_DEFINITION\":\"poc-agent-run\",\"SUBNET_IDS\":\"$SUBNET_IDS\",\"SECURITY_GROUP_IDS\":\"$SG_ID\",\"RUN_TABLE\":\"$RUN_TABLE\"}}"

log "lambda-publish (container image)"
if aws lambda get-function --region "$AWS_REGION" --function-name poc-agent-publish >/dev/null 2>&1; then
  aws lambda update-function-code --region "$AWS_REGION" --function-name poc-agent-publish \
    --image-uri "${REGISTRY}/poc-agent-publish:latest" >/dev/null
  aws lambda wait function-updated --region "$AWS_REGION" --function-name poc-agent-publish
else
  aws lambda create-function --region "$AWS_REGION" --function-name poc-agent-publish \
    --package-type Image --code "ImageUri=${REGISTRY}/poc-agent-publish:latest" \
    --role "$PUBLISH_ROLE_ARN" --timeout 120 --memory-size 512 \
    --environment "{\"Variables\":{\"RUN_TABLE\":\"$RUN_TABLE\",\"CACHE_BUCKET\":\"$CACHE_BUCKET\",\"GH_TOKEN_PARAM\":\"/poc/github-token-write\"}}" \
    >/dev/null
fi
echo "deployed poc-agent-publish"

DISPATCHER_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:poc-agent-dispatcher"
API_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:poc-agent-api"
PUBLISH_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:poc-agent-publish"

# --- 9. SQS -> dispatcher ------------------------------------------------------
log "SQS event source mapping"
EXISTING_MAPPING=$(aws lambda list-event-source-mappings --region "$AWS_REGION" \
  --function-name poc-agent-dispatcher --event-source-arn "$QUEUE_ARN" \
  --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || echo "None")
if [ "$EXISTING_MAPPING" = "None" ] || [ -z "$EXISTING_MAPPING" ]; then
  aws lambda create-event-source-mapping --region "$AWS_REGION" \
    --function-name poc-agent-dispatcher --event-source-arn "$QUEUE_ARN" \
    --batch-size 5 --function-response-types ReportBatchItemFailures >/dev/null
  echo "wired $QUEUE_NAME -> poc-agent-dispatcher"
else
  echo "reusing event source mapping $EXISTING_MAPPING"
fi

# --- 10. API Gateway -----------------------------------------------------------
log "API Gateway"
API_ID=$(aws apigatewayv2 get-apis --region "$AWS_REGION" \
  --query "Items[?Name=='poc-agent-api'].ApiId" --output text)
if [ -z "$API_ID" ]; then
  API_ID=$(aws apigatewayv2 create-api --region "$AWS_REGION" --name poc-agent-api \
    --protocol-type HTTP --target "$API_ARN" --query ApiId --output text)
  echo "created HTTP API $API_ID (quick-create — single \$default route/integration)"
  aws lambda add-permission --region "$AWS_REGION" --function-name poc-agent-api \
    --statement-id apigw-invoke --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" >/dev/null
else
  echo "reusing HTTP API $API_ID"
fi
API_BASE="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
echo "api: $API_BASE"

# --- 11. EventBridge: ECS task stop -> publish ---------------------------------
log "EventBridge rule (task stop -> publish)"
aws events put-rule --region "$AWS_REGION" --name poc-agent-task-stopped \
  --event-pattern '{"source":["aws.ecs"],"detail-type":["ECS Task State Change"],
    "detail":{"lastStatus":["STOPPED"],"group":["family:poc-agent-run"]}}' \
  --state ENABLED >/dev/null
aws events put-targets --region "$AWS_REGION" --rule poc-agent-task-stopped \
  --targets "Id=publish,Arn=${PUBLISH_ARN}" >/dev/null
aws lambda add-permission --region "$AWS_REGION" --function-name poc-agent-publish \
  --statement-id eventbridge-invoke --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${AWS_REGION}:${ACCOUNT_ID}:rule/poc-agent-task-stopped" \
  2>/dev/null || true
echo "wired ECS task stop -> poc-agent-publish"

# --- 12. console ---------------------------------------------------------------
log "console"
"$SCRIPT_DIR/deploy-console.sh" "$SITE_BUCKET" "$API_BASE"

cat <<EOF

=== done ===

Still needed before a run will actually work — these hold GitHub credentials,
so this script never creates them for you:

  aws ssm put-parameter --name /poc/github-token-read --type SecureString \\
    --value "github_pat_..." --region $AWS_REGION
    # Contents:read only — this is what the Fargate task gets. It can clone
    # and run 'gh repo list'/'gh api' for the typo-check; it cannot push.

  aws ssm put-parameter --name /poc/github-token-write --type SecureString \\
    --value "github_pat_..." --region $AWS_REGION
    # Contents:write + Pull requests:write — only poc-agent-publish's IAM
    # role (infra/fargate/iam/publish-role-policy.json) can read this one.

Then smoke-test it:
  curl -s -X POST ${API_BASE}/api/runs -H 'content-type: application/json' \\
    -d '{"repo":"demo-service","ticket":"POC-1","task":"Remove the Profile item from the sidebar navigation"}'

Console: see deploy-console.sh's output above for the URL.
EOF
