#!/bin/bash
# EC2 user-data for the coder agent POC. Amazon Linux 2023, x86_64.
# Paste into the "User data" box when launching the instance.
#
# Edit these four lines before launching:
POC_REPO_URL="https://github.com/drcastanoj/poc-agen.git"
AWS_DEFAULT_REGION="us-east-1"
BEDROCK_MODEL_ID="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
GITHUB_ORG="drcastanoj"

set -euxo pipefail
exec > >(tee /var/log/poc-bootstrap.log) 2>&1

dnf update -y
dnf install -y docker git jq python3 python3-pip

# Node 20 for the console server
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
dnf install -y nodejs

systemctl enable --now docker
usermod -aG docker ec2-user

# docker compose v2 as a CLI plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL \
  "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# buildx — the dnf-packaged docker on AL2023 ships one too old for
# `docker compose build` on some target Dockerfiles.
BUILDX_VER=$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest \
  | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
curl -fsSL \
  "https://github.com/docker/buildx/releases/download/${BUILDX_VER}/buildx-${BUILDX_VER}.linux-amd64" \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

git clone "$POC_REPO_URL" /opt/poc

# Persistent repo cache: bare mirrors, per-run worktrees, per-repo locks and the
# pnpm store. Survives runs, so a repo is cloned once and fetched thereafter.
# Size the instance volume for it — a mirror plus a worktree per concurrent run.
mkdir -p /opt/poc/cache/{repos,worktrees,locks,pnpm-store} /opt/poc/agent/logs
chown -R ec2-user:ec2-user /opt/poc

cd /opt/poc/server && npm install --omit=dev

# Secrets come from SSM at service start, never from this file and never
# from the instance's user data (user data is readable by anything on the box).
cat > /etc/systemd/system/poc-console.service <<UNIT
[Unit]
Description=Coder agent POC console
After=docker.service
Requires=docker.service

[Service]
User=ec2-user
WorkingDirectory=/opt/poc/server
Environment=PORT=8080
Environment=AGENT_DIR=/opt/poc/agent
Environment=POC_CACHE_DIR=/opt/poc/cache
Environment=MAX_CONCURRENT=2
Environment=AWS_REGION=${AWS_DEFAULT_REGION}
Environment=BEDROCK_MODEL_ID=${BEDROCK_MODEL_ID}
Environment=GITHUB_ORG=${GITHUB_ORG}
Environment=BASE_BRANCH=main
ExecStart=/bin/bash -c 'export GH_TOKEN=\$(aws ssm get-parameter --name /poc/github-token --with-decryption --query Parameter.Value --output text --region ${AWS_DEFAULT_REGION}); exec /usr/bin/node index.js'
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now poc-console

echo "bootstrap complete — console on port 8080"
