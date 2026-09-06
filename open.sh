#!/usr/bin/env bash
# open.sh <default|current> — action entrypoint: open the prompt popup in the workspace's
# directory. Actions run with the plugin root as cwd, so the repo comes from the context JSON.
# A popup gets no HERDR_WORKSPACE_ID of its own, so the caller's is forwarded with --env.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
herdr=${HERDR_BIN_PATH:-herdr}
base=${1:-default}

cwd=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -r '.workspace_cwd // .focused_pane_cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=${HERDR_ACTIVE_PANE_CWD:-$PWD}
# Fail early, before any popup, when the workspace is not a git checkout.
if ! git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  "$herdr" notification show "Not a git repository" --body "$cwd" --sound request >/dev/null 2>&1
  printf 'wt-purpose: %s is not inside a git work tree\n' "$cwd" >&2
  exit 1
fi

# The pane the action came from: the scaffold's progress split opens below it.
target=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -r '.focused_pane_id // empty' 2>/dev/null)
[ -n "$target" ] || target=${HERDR_PANE_ID:-${HERDR_ACTIVE_PANE_ID:-}}

set -- plugin pane open --plugin "${HERDR_PLUGIN_ID:-bonkey.wt-purpose}" --entrypoint prompt \
  --placement popup --width 70% --height 6 --cwd "$cwd" --focus --env "WTP_BASE=$base"
[ -n "${HERDR_WORKSPACE_ID:-}" ] && set -- "$@" --env "HERDR_WORKSPACE_ID=$HERDR_WORKSPACE_ID"
[ -n "$target" ] && set -- "$@" --env "WTP_TARGET_PANE=$target"
exec "$herdr" "$@"
