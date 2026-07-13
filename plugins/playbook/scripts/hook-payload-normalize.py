#!/usr/bin/env python3
"""Normalize provider hook-payload dialects to the Claude Code schema.

The playbook bash hooks parse Claude Code's snake_case payloads
(tool_name/tool_input/prompt/...). Grok Build delivers camelCase payloads
with partially different tool vocabulary and tool_input keys — captured
live from grok 0.2.99 headless sessions (task 014):

  top-level:  toolName / toolInput / hookEventName / sessionId (camelCase)
  tool names: Edit arrives as "StrReplace", Bash as "Shell"
              (Write and Read already use their Claude names)
  input keys: file_path arrives as "path", content as "contents"
              (old_string / new_string / command already match Claude)
  prompt:     the user prompt is wrapped in <user_query>...</user_query>

This script reads ONE JSON payload on stdin and writes the normalized
payload to stdout. It is invoked once per hook run, right after
`INPUT=$(cat)`, so every downstream parse site in the hook reads the
normalized form — one normalizer instead of N per-site fallbacks
(task 014 plan-panel F-D).

Safety contract:
  - Claude payloads pass through unchanged: existing snake_case keys
    ALWAYS win over camelCase aliases, and vocabulary mapping only fires
    on names Claude never emits (StrReplace/Shell).
  - Any error (non-JSON stdin, unexpected shape) → the raw input is
    echoed back verbatim, so the hooks' own per-site `|| echo ""`
    fallbacks apply exactly as before this shim existed.

Cursor-compat note: Cursor's camelCase dialect shares the top-level key
shape, so this normalizer is deliberately not grok-branded.
"""
import json
import re
import sys

# Claude never emits these tool names; grok 0.2.99 does (captured live).
_TOOL_NAMES = {"StrReplace": "Edit", "Shell": "Bash"}

# grok-native tool_input keys → Claude keys. Applied additively (grok key
# kept, Claude key added) and only when the Claude key is absent.
_INPUT_KEYS = {"path": "file_path", "contents": "content"}

_TOP_KEYS = {
    "hookEventName": "hook_event_name",
    "sessionId": "session_id",
    "toolName": "tool_name",
    "toolInput": "tool_input",
    "workspaceRoot": "workspace_root",
    "transcriptPath": "transcript_path",
}

# grok wraps the UserPromptSubmit prompt; unwrap only when the wrapper spans
# the whole value (a Claude prompt merely MENTIONING the tag is untouched).
_USER_QUERY_RE = re.compile(
    r"^\s*<user_query>\s*(.*?)\s*</user_query>\s*$", re.DOTALL
)


def normalize(payload):
    if not isinstance(payload, dict):
        return payload
    out = dict(payload)
    for camel, snake in _TOP_KEYS.items():
        if camel in out and snake not in out:
            out[snake] = out[camel]
    tool_name = out.get("tool_name")
    if isinstance(tool_name, str) and tool_name in _TOOL_NAMES:
        out["tool_name"] = _TOOL_NAMES[tool_name]
    tool_input = out.get("tool_input")
    if isinstance(tool_input, dict):
        tool_input = dict(tool_input)
        for theirs, ours in _INPUT_KEYS.items():
            if theirs in tool_input and ours not in tool_input:
                tool_input[ours] = tool_input[theirs]
        out["tool_input"] = tool_input
    prompt = out.get("prompt")
    if isinstance(prompt, str):
        m = _USER_QUERY_RE.match(prompt)
        if m:
            out["prompt"] = m.group(1)
    return out


def main():
    raw = sys.stdin.read()
    try:
        sys.stdout.write(json.dumps(normalize(json.loads(raw))))
    except Exception:
        sys.stdout.write(raw)


if __name__ == "__main__":
    main()
