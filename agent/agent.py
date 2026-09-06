#!/usr/bin/env python3
"""
Coding agent on Amazon Bedrock.

Runs a Converse-API tool-use loop against Claude: read files, edit them, run
shell commands, iterate on failures. Inference stays inside your AWS account.

The agent is NOT trusted to report success. run-agent.sh re-runs every
validation command independently after this exits.

Env:
  BEDROCK_MODEL_ID  required. Discover with:
      aws bedrock list-inference-profiles --region $AWS_REGION
  AWS_REGION        required
  REPO_ROOT         repo working tree (default: cwd)
  RULES_FILE        operating rules appended to the system prompt
  MAX_ITERATIONS    model round trips (default 40)
  MAX_TOKENS_TOTAL  cumulative token ceiling (default 2_000_000)
  BASH_TIMEOUT      per-command seconds (default 900)
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "")
REGION = os.environ.get("AWS_REGION", "us-east-1")
REPO_ROOT = Path(os.environ.get("REPO_ROOT", os.getcwd())).resolve()
RULES_FILE = os.environ.get("RULES_FILE", "")
MAX_ITERATIONS = int(os.environ.get("MAX_ITERATIONS", "40"))
MAX_TOKENS_TOTAL = int(os.environ.get("MAX_TOKENS_TOTAL", "2000000"))
BASH_TIMEOUT = int(os.environ.get("BASH_TIMEOUT", "900"))

MAX_TOOL_OUTPUT = 6000
MAX_FILE_READ = 60000

# The harness owns git and the PR. The agent touching either would let it
# bypass the validation gate, which is the one thing this design must prevent.
DENIED = [
    "git push", "git commit", "git rebase", "git reset --hard",
    "git checkout -b", "git branch", "git tag", "gh ",
    "rm -rf /", "sudo ", "shutdown", "reboot", "mkfs",
    "curl | sh", "curl|sh", "wget | sh", "wget|sh",
    ":(){", "chmod 777 /",
]


def emit(msg):
    print(msg, flush=True)


def safe_path(rel):
    """Confine every file operation to the repo working tree."""
    p = (REPO_ROOT / rel).resolve()
    if p != REPO_ROOT and REPO_ROOT not in p.parents:
        raise ValueError(f"path escapes the repository: {rel}")
    return p


def clip(text, limit):
    if len(text) <= limit:
        return text
    half = limit // 2
    dropped = len(text) - limit
    return f"{text[:half]}\n\n... [{dropped} characters omitted] ...\n\n{text[-half:]}"


# --- tools -------------------------------------------------------------------

def t_read_file(path, **_):
    p = safe_path(path)
    if not p.is_file():
        return f"not a file: {path}"
    return clip(p.read_text(errors="replace"), MAX_FILE_READ)


def t_write_file(path, content, **_):
    p = safe_path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return f"wrote {len(content)} characters to {path}"


def t_edit_file(path, old_text, new_text, **_):
    p = safe_path(path)
    if not p.is_file():
        return f"not a file: {path}"
    body = p.read_text(errors="replace")
    hits = body.count(old_text)
    if hits == 0:
        return "old_text not found. Read the file again and match it exactly."
    if hits > 1:
        return f"old_text appears {hits} times; include more surrounding context to make it unique."
    p.write_text(body.replace(old_text, new_text, 1))
    return f"edited {path}"


def t_list_files(pattern="**/*", **_):
    out, count = [], 0
    for p in sorted(REPO_ROOT.glob(pattern)):
        parts = set(p.parts)
        if parts & {"node_modules", ".git", "dist", "build", ".next", "coverage"}:
            continue
        if p.is_file():
            out.append(str(p.relative_to(REPO_ROOT)))
            count += 1
            if count >= 400:
                out.append("... truncated at 400 files")
                break
    return "\n".join(out) or "no matches"


def t_run_bash(command, **_):
    lowered = command.lower()
    for bad in DENIED:
        if bad in lowered:
            return (f"BLOCKED: '{bad}' is not permitted. The harness handles git "
                    f"and the pull request. Focus on the code and the checks.")
    try:
        r = subprocess.run(
            command, shell=True, cwd=str(REPO_ROOT),
            capture_output=True, text=True, timeout=BASH_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return f"command timed out after {BASH_TIMEOUT}s"
    body = (r.stdout or "") + (r.stderr or "")
    return f"exit code {r.returncode}\n\n{clip(body, MAX_TOOL_OUTPUT)}"


TOOLS = {
    "read_file": t_read_file,
    "write_file": t_write_file,
    "edit_file": t_edit_file,
    "list_files": t_list_files,
    "run_bash": t_run_bash,
}

TOOL_CONFIG = {"tools": [
    {"toolSpec": {
        "name": "read_file",
        "description": "Read a file from the repository, relative to the repo root.",
        "inputSchema": {"json": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Path relative to repo root"}},
            "required": ["path"],
        }},
    }},
    {"toolSpec": {
        "name": "list_files",
        "description": "List repository files matching a glob. Excludes node_modules, .git and build output.",
        "inputSchema": {"json": {
            "type": "object",
            "properties": {"pattern": {"type": "string", "description": "Glob, e.g. 'src/**/*.tsx'"}},
            "required": [],
        }},
    }},
    {"toolSpec": {
        "name": "edit_file",
        "description": "Replace an exact unique string in a file. Preferred over write_file for existing files.",
        "inputSchema": {"json": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "old_text": {"type": "string", "description": "Exact text to replace; must appear exactly once"},
                "new_text": {"type": "string", "description": "Replacement text; empty string deletes"},
            },
            "required": ["path", "old_text", "new_text"],
        }},
    }},
    {"toolSpec": {
        "name": "write_file",
        "description": "Write a whole file, creating or overwriting it. Use edit_file for existing files.",
        "inputSchema": {"json": {
            "type": "object",
            "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
            "required": ["path", "content"],
        }},
    }},
    {"toolSpec": {
        "name": "run_bash",
        "description": "Run a shell command in the repo root. Use for lint, typecheck, tests, build and grep.",
        "inputSchema": {"json": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        }},
    }},
]}

BASE_SYSTEM = """You are a software engineer working unattended in an isolated container.

You have tools to read, list, edit and write files, and to run shell commands.
Work directly on the repository; there is no human to ask mid-task.

Approach:
1. Explore before editing. Find the relevant files with list_files and grep via
   run_bash, then read them. Never edit a file you have not read.
2. Make the smallest change that accomplishes the task.
3. Run the validation commands yourself and iterate until they pass.
4. When finished, write a short plain-prose summary of what you changed.

The harness re-runs every validation command independently after you stop.
Claiming success without running the commands wastes the entire run.

If the task is ambiguous enough that you would need to ask a human, or if it
cannot be done without violating the rules below, stop and explain why instead
of guessing or working around it."""


def build_system():
    text = BASE_SYSTEM
    if RULES_FILE and Path(RULES_FILE).is_file():
        text += "\n\n" + Path(RULES_FILE).read_text()
    return [{"text": text}]


def run(task):
    if not MODEL_ID:
        emit("BEDROCK_MODEL_ID is not set. Discover an id with:")
        emit(f"  aws bedrock list-inference-profiles --region {REGION}")
        return 2

    client = boto3.client(
        "bedrock-runtime",
        region_name=REGION,
        config=Config(read_timeout=3600, retries={"max_attempts": 4, "mode": "adaptive"}),
    )

    messages = [{"role": "user", "content": [{"text": task}]}]
    system = build_system()
    tokens_in = tokens_out = 0
    started = time.time()
    summary = ""

    for i in range(1, MAX_ITERATIONS + 1):
        try:
            resp = client.converse(
                modelId=MODEL_ID,
                messages=messages,
                system=system,
                toolConfig=TOOL_CONFIG,
                inferenceConfig={"maxTokens": 8192, "temperature": 0},
            )
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "Unknown")
            emit(f"bedrock error [{code}]: {e}")
            if code == "AccessDeniedException":
                emit("The instance role cannot invoke this model. Check model access "
                     "and that BEDROCK_MODEL_ID matches an id you can invoke.")
            return 3

        usage = resp.get("usage", {})
        tokens_in += usage.get("inputTokens", 0)
        tokens_out += usage.get("outputTokens", 0)

        message = resp["output"]["message"]
        messages.append(message)

        for block in message.get("content", []):
            if "text" in block and block["text"].strip():
                summary = block["text"].strip()
                emit(f"[agent] {summary}")

        if resp.get("stopReason") != "tool_use":
            emit(f"[agent] finished after {i} round trips")
            break

        results = []
        for block in message.get("content", []):
            if "toolUse" not in block:
                continue
            use = block["toolUse"]
            name, args = use["name"], use.get("input", {})

            label = args.get("command") or args.get("path") or args.get("pattern") or ""
            emit(f"[tool] {name} {str(label)[:160]}")

            fn = TOOLS.get(name)
            if fn is None:
                out, status = f"unknown tool: {name}", "error"
            else:
                try:
                    out, status = fn(**args), "success"
                except Exception as exc:
                    out, status = f"{type(exc).__name__}: {exc}", "error"

            results.append({"toolResult": {
                "toolUseId": use["toolUseId"],
                "content": [{"text": str(out)}],
                "status": status,
            }})

        messages.append({"role": "user", "content": results})

        if tokens_in + tokens_out > MAX_TOKENS_TOTAL:
            emit(f"[agent] token ceiling reached ({tokens_in + tokens_out}); stopping")
            break
    else:
        emit(f"[agent] hit the {MAX_ITERATIONS} round-trip limit without finishing")

    elapsed = int(time.time() - started)
    emit(f"[agent] tokens in={tokens_in} out={tokens_out} elapsed={elapsed}s")

    out_path = os.environ.get("AGENT_SUMMARY_FILE")
    if out_path:
        Path(out_path).write_text(json.dumps({
            "summary": summary,
            "input_tokens": tokens_in,
            "output_tokens": tokens_out,
            "elapsed_seconds": elapsed,
            "model_id": MODEL_ID,
        }, indent=2))

    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        emit("usage: agent.py \"<task description>\"")
        sys.exit(2)
    sys.exit(run(sys.argv[1]))
