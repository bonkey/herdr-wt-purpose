#!/usr/bin/env bash
# cleanup.sh — runs in the worktree's own shell after the chosen command exits (scaffold.sh
# appends it to the command line). The branch outlives the worktree, so a clean checkout is
# pure disk cost: offer to remove it, keeping the branch (`wt switch <branch>` brings it back).
# Same bar as wt itself: uncommitted or untracked files keep the worktree without asking.
# Gitignored files (node_modules, .env, build output) are counted, not blocking — reclaiming
# them is usually the point. Removal goes through `wt remove` (hooks run) when wt is on PATH,
# else `git worktree remove`; then the herdr workspace that showed the checkout is closed.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
herdr=${HERDR_BIN_PATH:-herdr}

[ -t 0 ] || exit 0
wt_path=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
branch=$(git branch --show-current 2>/dev/null); [ -n "$branch" ] || exit 0
main_wt=$(git worktree list --porcelain 2>/dev/null | awk 'NR==1 && $1=="worktree" {print $2}')
[ -n "$main_wt" ] && [ "$main_wt" != "$wt_path" ] || exit 0   # never the main checkout

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  printf 'worktree %s has uncommitted changes — keeping it\n' "$wt_path"
  exit 0
fi
ignored=$(git status --porcelain --ignored 2>/dev/null | grep -c '^!!')
note=""; [ "$ignored" -gt 0 ] && note=" (drops $ignored gitignored path(s))"
printf 'remove worktree %s%s, keep branch %s? [Y/n] ' "$wt_path" "$note" "$branch"
IFS= read -r answer
case $answer in ""|[Yy]*) ;; *) exit 0 ;; esac

# git refuses to delete the directory it runs from, so step out to the main checkout first.
cd "$main_wt" || exit 1
if command -v wt >/dev/null; then
  wt remove "$branch" --no-delete-branch --foreground -y || exit 1
else
  git worktree remove "$wt_path" || exit 1
fi
# The workspace now shows a deleted checkout; closing it ends this shell too.
[ -n "${HERDR_WORKSPACE_ID:-}" ] && "$herdr" workspace close "$HERDR_WORKSPACE_ID" >/dev/null 2>&1
exit 0
