FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq gnupg python3 python3-pip \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
       https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# Pin pnpm to match the target repo's packageManager field.
ARG PNPM_VERSION=10.28.2
RUN corepack enable && corepack prepare "pnpm@${PNPM_VERSION}" --activate

COPY requirements.txt /opt/akai/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /opt/akai/requirements.txt

# Shared pnpm store — mount a volume here so installs are warm across runs.
RUN mkdir -p /pnpm-store /work
ENV PNPM_HOME=/pnpm-store

WORKDIR /work
COPY run-agent.sh agent.py AGENT_RULES.md /opt/akai/
RUN chmod +x /opt/akai/run-agent.sh /opt/akai/agent.py

ENTRYPOINT ["/opt/akai/run-agent.sh"]
