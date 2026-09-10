#!/usr/bin/env bash
# Builds and pushes the two container images the serverless design needs:
#   poc-agent           agent/Dockerfile, unchanged, run as the Fargate task
#   poc-agent-publish   lambda/publish/Dockerfile, a container-image Lambda
#                       (git + gh aren't in any managed Lambda runtime)
#
# Usage: ./build-images.sh <account-id> [region]

set -euo pipefail
ACCOUNT_ID="${1:?usage: build-images.sh <account-id> [region]}"
AWS_REGION="${2:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log() { printf '\n=== %s ===\n' "$*"; }

for name in poc-agent poc-agent-publish; do
  aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$name" >/dev/null 2>&1 \
    || aws ecr create-repository --region "$AWS_REGION" --repository-name "$name" >/dev/null
done

log "authenticating docker to ECR"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

log "building poc-agent (agent/Dockerfile)"
docker build -t "${REGISTRY}/poc-agent:latest" "$REPO_ROOT/agent"
docker push "${REGISTRY}/poc-agent:latest"

log "building poc-agent-publish (lambda/publish/Dockerfile)"
docker build -t "${REGISTRY}/poc-agent-publish:latest" "$REPO_ROOT/lambda/publish"
docker push "${REGISTRY}/poc-agent-publish:latest"

cat <<EOF

pushed:
  ${REGISTRY}/poc-agent:latest
  ${REGISTRY}/poc-agent-publish:latest

Pass the first to setup.sh as AGENT_IMAGE_URI and the second as
PUBLISH_IMAGE_URI (or let setup.sh derive both from ACCOUNT_ID/AWS_REGION,
since these are the names it expects).
EOF
