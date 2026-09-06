#!/usr/bin/env bash
# scaffold.sh — background worker. Runs in the unfocused split (or tab) opened by prompt.sh,
# with the workspace's repo as cwd, so every step and the wt hook output stay visible. Turns WTP_INPUT into a branch name, creates the worktree (wt with
# its hooks when installed, herdr natively otherwise), opens it as a herdr worktree workspace,
# then toasts. The pane closes with the script; on failure it stays open until a key is pressed.
#
# Env in:  WTP_INPUT  purpose text, or exactly one URL (Linear / Jira / GitHub / any page)
#          WTP_BASE   default | current   (base branch for the new one)
#          WTP_RUN    command line to start in the new workspace ("" = just the shell);
#                     {{branch}} {{label}} {{path}} expand
# Config ($HERDR_PLUGIN_CONFIG_DIR/config.toml, both optional):
#          slug_command  = "swift $HERDR_PLUGIN_ROOT/slug.swift"  # prompt on stdin, slug on stdout
#          branch_prefix = "<user>/"                               # set "" for no prefix
#          [run]                                                    # the popup's menu, in order
#          claude = "claude --dangerously-skip-permissions --name {{label}}"
#          shell = ""
# Optional credentials for ticket bodies: LINEAR_API_KEY, JIRA_USER + JIRA_API_TOKEN, gh auth.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
herdr=${HERDR_BIN_PATH:-herdr}
plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
config_file="${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/config.toml"
log_dir=${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}
mkdir -p "$log_dir" 2>/dev/null; log="$log_dir/last.log"; : > "$log"

input=$(printf '%s' "${WTP_INPUT:-}" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
base_mode=${WTP_BASE:-default}
run=${WTP_RUN:-}

say()  { printf '\033[2m%s\033[0m\n' "$*"; }
fail() {
  printf '\033[31m%s\033[0m\n' "$1"
  "$herdr" notification show "Worktree failed" --body "$1" --sound request >/dev/null 2>&1
  printf '\n(log: %s) press any key to close ' "$log"; read -r -n1
  exit 1
}

# config_value KEY → the key's value from config.toml (quoted or bare), empty when absent.
config_value() {
  [ -f "$config_file" ] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(\"([^\"]*)\"|([^[:space:]#\"]+))[[:space:]]*(#.*)?$/\\2\\3/p" "$config_file" | tail -n1
}

# sanitize TEXT → lowercase ASCII slug, hyphen-separated, at most 40 chars.
sanitize() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//'
}

# resolve_url URL — fills ticket_id / ticket_title / ticket_body for the ticket systems we know;
# any other page contributes its <title>. Missing tools or credentials degrade to id-only.
ticket_id=""; ticket_title=""; ticket_body=""
resolve_url() {
  local url host path json
  url=$(printf '%s' "$1" | sed -E "s/[.,;:)\"']+$//")
  host=${url#*://}; host=${host%%/*}
  case $url in
    *://linear.app/*/issue/*)
      path=${url#*/issue/}; path=${path%%\?*}
      ticket_id=$(printf '%s' "${path%%/*}" | tr '[:lower:]' '[:upper:]')
      [ "${path#*/}" != "$path" ] && ticket_title=$(printf '%s' "${path#*/}" | tr '-' ' ')
      if [ -n "${LINEAR_API_KEY:-}" ]; then
        json=$(curl -fsS --max-time 10 https://api.linear.app/graphql \
          -H "Authorization: $LINEAR_API_KEY" -H 'Content-Type: application/json' \
          --data "$(jq -cn --arg id "$ticket_id" \
            '{query:"query($id:String!){issue(id:$id){title description}}",variables:{id:$id}}')" 2>>"$log") || json=""
        if [ -n "$json" ]; then
          ticket_title=$(jq -r '.data.issue.title // empty' <<<"$json")
          ticket_body=$(jq -r '.data.issue.description // empty' <<<"$json")
        fi
      fi ;;
    *://github.com/*/*/issues/*|*://github.com/*/*/pull/*)
      ticket_id=$(printf '%s' "$url" | sed -E 's#.*/(issues|pull)/([0-9]+).*#\2#')
      if command -v gh >/dev/null; then
        case $url in
          */pull/*) json=$(gh pr view "$url" --json title,body 2>>"$log") || json="" ;;
          *)        json=$(gh issue view "$url" --json title,body 2>>"$log") || json="" ;;
        esac
        if [ -n "$json" ]; then
          ticket_title=$(jq -r '.title // empty' <<<"$json")
          ticket_body=$(jq -r '.body // empty' <<<"$json")
        fi
      fi ;;
    */browse/[A-Za-z]*-[0-9]*)
      ticket_id=$(printf '%s' "$url" | sed -E 's#.*/browse/([A-Za-z][A-Za-z0-9]*-[0-9]+).*#\1#' | tr '[:lower:]' '[:upper:]')
      if [ -n "${JIRA_USER:-}" ] && [ -n "${JIRA_API_TOKEN:-}" ]; then
        json=$(curl -fsS --max-time 10 -u "$JIRA_USER:$JIRA_API_TOKEN" \
          "https://$host/rest/api/3/issue/$ticket_id?fields=summary,description" 2>>"$log") || json=""
        if [ -n "$json" ]; then
          ticket_title=$(jq -r '.fields.summary // empty' <<<"$json")
          ticket_body=$(jq -r '[.fields.description | .. | .text? // empty] | join(" ")' <<<"$json")
        fi
      fi ;;
    *)
      ticket_title=$(curl -fsSL --max-time 10 "$url" 2>>"$log" | grep -oE '<title[^>]*>[^<]+' | head -1 | sed 's/^[^>]*>//') ;;
  esac
  ticket_title=$(printf '%s' "$ticket_title" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
}

# make_slug — asks the slug backend (prompt on stdin, one line back); falls back to a
# deterministic slug of the title or the input when the backend is unavailable or empty.
make_slug() {
  local prompt cmd out
  prompt='Generate a git branch slug for the work described below. Reply with exactly one line: a lowercase slug of 2 to 5 words joined by single hyphens, ASCII letters and digits only, at most 40 characters. No bullet or dash prefix, no quotes, no ticket ids, no explanation. If a ticket title is cryptic (abbreviations, component tags, codenames), use the context to restate the actual work in plain words instead of copying the fragments.'
  if [ -n "$ticket_title" ]; then
    prompt="$prompt

Ticket title: $ticket_title"
  else
    prompt="$prompt

Purpose: $input"
  fi
  [ -n "$ticket_body" ] && prompt="$prompt
Context: $(printf '%s' "$ticket_body" | tr -s '[:space:]' ' ' | cut -c1-500)"
  cmd=$(config_value slug_command)
  [ -n "$cmd" ] || cmd="swift \"$plugin_root/slug.swift\""
  printf '%s\n--- slug_command: %s\n' "$prompt" "$cmd" >>"$log"
  out=$(printf '%s\n' "$prompt" | eval "$cmd" 2>>"$log")
  printf -- '--- raw reply:\n%s\n' "$out" >>"$log"
  out=$(printf '%s\n' "$out" | sed -E 's/^[[:space:]`>*-]+//; s/[[:space:]`]+$//' | grep -v '^$' | tail -n1)
  out=$(sanitize "$out")
  [ -n "$out" ] || out=$(sanitize "${ticket_title:-$input}")
  printf '%s\n' "$out"
}

# open_workspace — register the checkout under the repo's root workspace (worktrunk plugin's
# picker.sh logic): resolve the repo root, pre-label a missing root workspace with the repo name,
# skip --label when the checkout is the root itself.
open_workspace() {
  local source_json repo_root root_ws repo_label out
  source_json=$("$herdr" worktree list --cwd "$PWD" --json 2>>"$log")
  repo_root=$(jq -r '.result.source.repo_root // empty' <<<"$source_json")
  [ -n "$repo_root" ] || fail "herdr could not resolve the repository root from $PWD"
  root_ws=$(jq -r '.result.source.source_workspace_id // empty' <<<"$source_json")
  if [ -z "$root_ws" ]; then
    repo_label=$(jq -r '.result.source.repo_name // empty' <<<"$source_json"); repo_label=${repo_label%.git}
    [ -n "$repo_label" ] && "$herdr" workspace create --cwd "$repo_root" --label "$repo_label" --no-focus >/dev/null 2>>"$log"
  fi
  set -- worktree open --cwd "$repo_root" --path "$wtpath" --focus
  [ "$(cd "$wtpath" 2>/dev/null && pwd -P)" = "$(cd "$repo_root" 2>/dev/null && pwd -P)" ] || set -- "$@" --label "$label"
  out=$("$herdr" "$@" 2>&1) || fail "herdr worktree open failed: $out"
  jq -e '.error' <<<"$out" >/dev/null 2>&1 && fail "herdr worktree open: $(jq -r '.error.message' <<<"$out")"
  target_pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")
  target_ws=$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")
  return 0
}

# run_in_workspace — type the chosen command into the new workspace's shell pane. Waits for the
# shell to be alone in the foreground first (rc files spawn helpers), at most ~10 s.
run_in_workspace() {
  local cmd pane i pi
  [ -n "$run" ] || return 0
  cmd=$run
  cmd=${cmd//\{\{branch\}\}/$branch}; cmd=${cmd//\{\{label\}\}/$label}; cmd=${cmd//\{\{path\}\}/$wtpath}
  pane=$target_pane
  [ -n "$pane" ] || [ -z "$target_ws" ] || pane=$("$herdr" pane list --workspace "$target_ws" 2>>"$log" | jq -r '.result.panes[0].pane_id // empty')
  [ -n "$pane" ] || { say "no pane found to run: $cmd"; return 0; }
  say "starting in $pane: $cmd"
  for i in $(seq 1 50); do
    pi=$("$herdr" pane process-info --pane "$pane" 2>/dev/null) || break
    jq -e '.result.process_info as $p | ($p.shell_pid != null) and ($p.foreground_process_group_id == $p.shell_pid)
           and (($p.foreground_processes // []) | all(.pid == $p.shell_pid))' <<<"$pi" >/dev/null 2>&1 && break
    sleep 0.2
  done
  "$herdr" pane run "$pane" "$cmd" >/dev/null 2>>"$log" || say "could not start: $cmd"
  ran=" → $cmd"
}

# --- main -------------------------------------------------------------------------------------
[ -n "${HERDR_PANE_ID:-}" ] && "$herdr" pane rename "$HERDR_PANE_ID" "creating worktree…" >/dev/null 2>&1
[ -n "${HERDR_TAB_ID:-}" ] && "$herdr" tab rename "$HERDR_TAB_ID" "creating worktree…" >/dev/null 2>&1
[ -n "$input" ] || fail "empty input"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$PWD is not inside a git work tree"

case $input in
  http://*|https://*)
    case $input in *[[:space:]]*) fail "one URL only, or plain text" ;; esac
    say "resolving $input"
    resolve_url "$input"
    [ -n "$ticket_id" ] && say "ticket: ${ticket_id}${ticket_title:+ — $ticket_title}" ;;
esac

say "asking the model for a name…"
slug=$(make_slug)
[ -n "$slug" ] || fail "could not derive a slug from: $input"

if grep -qE '^[[:space:]]*branch_prefix[[:space:]]*=' "$config_file" 2>/dev/null; then
  prefix=$(config_value branch_prefix)
else
  prefix="$(id -un)/"
fi
branch="${prefix}${ticket_id:+${ticket_id}-}${slug}"
taken() { git show-ref --verify --quiet "refs/heads/$1" || git show-ref --verify --quiet "refs/remotes/origin/$1"; }
if taken "$branch"; then
  n=2; while taken "$branch-$n"; do n=$((n + 1)); done; branch="$branch-$n"
fi
label=${branch#"$prefix"}
printf '\033[1m%s\033[0m\n' "$branch"

target_pane=""; target_ws=""; wtpath=""; ran=""
base_ref=""; [ "$base_mode" = current ] && base_ref="@"
if command -v wt >/dev/null; then
  say "wt switch --create $branch${base_ref:+ --base $base_ref}"
  set -- switch --create "$branch" --no-cd --format=json
  [ -n "$base_ref" ] && set -- "$@" --base "$base_ref"
  result=$(wt -C "$PWD" "$@") || fail "wt switch failed for $branch (see above)"
  wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty' 2>/dev/null)
  [ -n "$wtpath" ] || wtpath=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '$1=="worktree"{p=$2} $1=="branch"&&$2==b{print p; exit}')
  [ -n "$wtpath" ] || fail "wt returned no worktree path for $branch"
  open_workspace
else
  # No worktrunk: herdr creates the checkout under [worktrees].directory and opens it in one call.
  if [ -n "$base_ref" ]; then
    base_ref=$(git rev-parse --abbrev-ref HEAD)
  else
    base_ref=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); base_ref=${base_ref#origin/}
  fi
  say "herdr worktree create --branch $branch${base_ref:+ --base $base_ref}"
  set -- worktree create --cwd "$PWD" --branch "$branch" --label "$label" --focus
  [ -n "$base_ref" ] && set -- "$@" --base "$base_ref"
  out=$("$herdr" "$@" 2>&1) || fail "herdr worktree create failed: $out"
  jq -e '.error' <<<"$out" >/dev/null 2>&1 && fail "herdr worktree create: $(jq -r '.error.message' <<<"$out")"
  target_ws=$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")
  wtpath=$(jq -r '.result.worktree.path // .result.worktree.checkout_path // empty' <<<"$out")
fi

run_in_workspace
"$herdr" notification show "Worktree ready" --body "${branch}${ran}" --sound done >/dev/null 2>&1
say "done"
