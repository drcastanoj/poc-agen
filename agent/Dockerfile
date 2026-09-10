FROM node:20-bookworm-slim

# unzip: the AWS CLI installer needs it. zstd: the s3 dependency cache backend
# tars node_modules with it (agent/lib/cache.sh) — much faster than gzip at
# the sizes a node_modules directory actually is.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates jq gnupg python3 python3-pip util-linux zstd \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
       https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# Only needed for CACHE_BACKEND=s3 / LOCK_BACKEND=dynamodb (docs/lambda-migration.md).
# On EC2 with the fs/flock defaults nothing here is ever invoked.
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
  && unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install \
  && rm -rf /tmp/awscliv2.zip /tmp/aws

# Pin pnpm to match the target repo's packageManager field.
ARG PNPM_VERSION=10.28.2
RUN corepack enable && corepack prepare "pnpm@${PNPM_VERSION}" --activate

COPY requirements.txt /opt/akai/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /opt/akai/requirements.txt

# /cache is the shared, persistent host directory: bare mirrors, per-run
# worktrees, per-repo locks and the pnpm store all live under it.
RUN mkdir -p /cache /work
ENV PNPM_HOME=/pnpm-home

WORKDIR /work
COPY run-agent.sh agent.py AGENT_RULES.md /opt/akai/
COPY lib/ /opt/akai/lib/
RUN chmod +x /opt/akai/run-agent.sh /opt/akai/agent.py

ENTRYPOINT ["/opt/akai/run-agent.sh"]
