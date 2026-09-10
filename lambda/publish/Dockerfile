# Container-image Lambda: the managed Python runtime has no git or gh, and
# this is the one function in the whole design that needs them — everything
# else either never touches git (lambda/api, lambda/dispatcher) or runs on
# Fargate, where a normal Dockerfile already works (agent/Dockerfile).
FROM public.ecr.aws/lambda/python:3.12

RUN dnf install -y git tar gzip \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/pki/rpm-gpg/githubcli-archive-keyring.gpg \
  && echo -e "[gh-cli]\nname=GitHub CLI\nbaseurl=https://cli.github.com/packages/rpm\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/githubcli-archive-keyring.gpg" \
       > /etc/yum.repos.d/gh-cli.repo \
  && dnf install -y gh \
  && dnf clean all

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
