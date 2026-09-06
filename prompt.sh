#!/usr/bin/env bash
# prompt.sh — the popup. Line 1: a purpose, or a single ticket URL. Line 2: which command to start
# in the new workspace, picked by number from the [run] table of the plugin config (defaults
# below: claude / codex / shell, arguments included). Then the work moves to scaffold.sh in a visible, unfocused
# split below the pane the action came from (a tab when no pane is known) and the popup closes.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
herdr=${HERDR_BIN_PATH:-herdr}
base=${WTP_BASE:-default}
config_file="${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/config.toml"

case $base in
  current) hint="from $(git branch --show-current 2>/dev/null || echo HEAD)" ;;
  *)       hint="from the default branch" ;;
esac
printf '\033[1mNew worktree\033[0m %s\n' "$hint"
printf 'Purpose or ticket URL (Linear / Jira / GitHub): '
IFS= read -e -r input || exit 0
[ -n "${input// /}" ] || exit 0

# [run] table → "name<TAB>command" lines in file order; the first entry is the Enter default.
run_entries() {
  [ -f "$config_file" ] || return 0
  awk '/^[[:space:]]*\[/ { in_run = ($0 ~ /^[[:space:]]*\[run\][[:space:]]*(#.*)?$/); next }
       in_run && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
         name = $0; sub(/^[[:space:]]*/, "", name); sub(/[[:space:]]*=.*/, "", name)
         val = $0; sub(/^[^=]*=[[:space:]]*/, "", val)
         if (val ~ /^"/) { sub(/^"/, "", val); sub(/"[[:space:]]*(#.*)?$/, "", val) }
         else { sub(/[[:space:]]*(#.*)?$/, "", val) }
         print name "\t" val }' "$config_file"
}
names=(); cmds=()
while IFS=$'\t' read -r n c; do [ -n "$n" ] && { names+=("$n"); cmds+=("$c"); }; done <<EOF_RUN
$(run_entries)
EOF_RUN
if [ ${#names[@]} -eq 0 ]; then
  names=(claude codex shell)
  cmds=("claude --dangerously-skip-permissions --name {{label}}" "codex --yolo" "")
fi
menu=""; i=1
for n in "${names[@]}"; do menu="$menu  [$i] $n"; i=$((i + 1)); done
printf 'Run in it:%s   (Enter = %s): ' "$menu" "${names[0]}"
IFS= read -r -n1 key; printf '\n'
idx=0
case $key in [1-9]) [ "$key" -le ${#names[@]} ] && idx=$((key - 1)) ;; esac
run=${cmds[$idx]}

if [ -z "${HERDR_WORKSPACE_ID:-}" ]; then
  printf '\033[31mno workspace to run the scaffold in\033[0m\n'; sleep 2; exit 1
fi
open_scaffold() {
  "$herdr" plugin pane open --plugin "${HERDR_PLUGIN_ID:-bonkey.wt-purpose}" --entrypoint scaffold "$@" \
    --cwd "$PWD" --no-focus --env "WTP_INPUT=$input" --env "WTP_BASE=$base" --env "WTP_RUN=$run" 2>&1
}
out=""
if [ -n "${WTP_TARGET_PANE:-}" ]; then
  out=$(open_scaffold --placement split --direction down --target-pane "$WTP_TARGET_PANE") && exit 0
fi
out=$(open_scaffold --placement tab --workspace "$HERDR_WORKSPACE_ID") && exit 0
printf '\033[31mcould not start the scaffold pane: %s\033[0m\n' "$out"; sleep 3; exit 1
