#!/usr/bin/env bash
# Clear nanobot session-related state: CLI history, legacy sessions, workspace
# session JSONL, and consolidated memory files. Paths align with nanobot.config.paths
# and nanobot.session / nanobot.agent.memory.
#
# Workspace defaults to ~/.nanobot/workspace (schema AgentDefaults.workspace).
# Override if your config uses a different path:
#   NANOBOT_WORKSPACE=/path/to/workspace ./script_cleanse_session_memory.sh

set -euo pipefail

NB="${HOME}/.nanobot"
HIST_FILE="${NB}/history/cli_history"
LEGACY_SESSIONS="${NB}/sessions"

# Match config.agents.defaults.workspace when unset (see nanobot.config.schema).
WORKSPACE="${NANOBOT_WORKSPACE:-${HOME}/.nanobot/workspace}"
if [[ "${WORKSPACE}" == "~"* ]]; then
  WORKSPACE="${WORKSPACE/#\~/${HOME}}"
fi
if command -v realpath >/dev/null 2>&1; then
  WORKSPACE="$(realpath -m "${WORKSPACE}")"
fi

WS_SESSIONS="${WORKSPACE}/sessions"
WS_MEMORY="${WORKSPACE}/memory"

mkdir -p "${NB}/history"

# Truncate CLI readline / prompt_toolkit history (FileHistory).
: > "${HIST_FILE}"

# Remove legacy global session JSONL files (migration source under ~/.nanobot/sessions).
if [[ -d "${LEGACY_SESSIONS}" ]]; then
  shopt -s nullglob
  for f in "${LEGACY_SESSIONS}"/*.jsonl; do
    rm -f -- "${f}"
  done
  shopt -u nullglob
fi

# Active session store: workspace/sessions/<safe_key>.jsonl
if [[ -d "${WS_SESSIONS}" ]]; then
  shopt -s nullglob
  for f in "${WS_SESSIONS}"/*.jsonl; do
    rm -f -- "${f}"
  done
  shopt -u nullglob
fi

# Long-term consolidated memory (MemoryStore)
rm -f -- "${WS_MEMORY}/MEMORY.md" "${WS_MEMORY}/HISTORY.md" 2>/dev/null || true

echo "Cleared: ${HIST_FILE}"
echo "Cleared legacy sessions under: ${LEGACY_SESSIONS} (if present)"
echo "Cleared workspace sessions: ${WS_SESSIONS}/*.jsonl"
echo "Removed memory files under: ${WS_MEMORY} (MEMORY.md, HISTORY.md if present)"
echo "Workspace used: ${WORKSPACE}"
