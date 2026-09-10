#!/usr/bin/env bash
# Publishes server/public/ as a static site, pointing it at the API Gateway
# origin set up by setup.sh. S3 static website hosting (HTTP, not HTTPS) is
# enough for a POC — see docs/lambda-migration.md, which treats CloudFront as
# an enhancement, not a prerequisite.
#
# Usage: ./deploy-console.sh <site-bucket> <api-base-url>
# Example:
#   ./deploy-console.sh poc-agent-console-123456789012 \
#     https://abc123.execute-api.us-east-1.amazonaws.com

set -euo pipefail
SITE_BUCKET="${1:?usage: deploy-console.sh <site-bucket> <api-base-url>}"
API_BASE="${2:?usage: deploy-console.sh <site-bucket> <api-base-url>}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_DIR="$(cd "$SCRIPT_DIR/../../server/public" && pwd)"

log() { printf '\n=== %s ===\n' "$*"; }

if ! aws s3api head-bucket --bucket "$SITE_BUCKET" 2>/dev/null; then
  log "creating $SITE_BUCKET"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$SITE_BUCKET" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$SITE_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  aws s3api put-public-access-block --bucket "$SITE_BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false
  aws s3api put-bucket-policy --bucket "$SITE_BUCKET" --policy "$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"PublicRead","Effect":"Allow","Principal":"*",
"Action":"s3:GetObject","Resource":"arn:aws:s3:::${SITE_BUCKET}/*"}]}
EOF
)"
  aws s3 website "s3://${SITE_BUCKET}" --index-document index.html
fi

log "writing config.js"
echo "window.API_BASE = \"${API_BASE}\";" > /tmp/config.js

log "uploading console"
aws s3 cp /tmp/config.js "s3://${SITE_BUCKET}/config.js"
aws s3 cp "$PUBLIC_DIR/index.html" "s3://${SITE_BUCKET}/index.html"

cat <<EOF

console: http://${SITE_BUCKET}.s3-website-${AWS_REGION}.amazonaws.com
       (or http://${SITE_BUCKET}.s3-website.${AWS_REGION}.amazonaws.com in
        some regions — check the endpoint format aws s3 website printed)
API:     ${API_BASE}

Rerun this script whenever server/public/index.html changes; config.js only
needs rewriting if the API URL changes.
EOF
