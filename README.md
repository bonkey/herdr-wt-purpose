# herdr-wt-purpose

[Herdr](https://herdr.dev) plugin: type **what the worktree is for** (or paste a ticket URL),
and a branch is named by Apple's on-device model, the worktree is created, and it opens as a
nested worktree workspace — all in the background while you keep working.

    prefix+shift+n → "Purpose or ticket URL: fix crash when opening settings on iPad"
                  → bonkey/landscape-settings-crash-fix   (toast when the workspace is ready)

## Install

    herdr plugin install bonkey/herdr-wt-purpose

Requires herdr ≥ 0.8, git, jq, curl (macOS has bash 3.2, which is enough).
Everything else is optional and detected at run time:

- **Xcode Command Line Tools + Apple Intelligence** — the default slug backend
  (`slug.swift`, run through the `swift` interpreter). Without them the slug is derived from
  the text itself.
- **[worktrunk](https://github.com/max-sixty/worktrunk)** (`wt`) — used when on PATH so your
  worktrunk hooks (`post-start`, copy-ignored, …) run; otherwise `herdr worktree create`.
- **`gh`** — titles and bodies of GitHub issues / PRs.
- **`LINEAR_API_KEY`** — Linear issue title and description (the URL alone still gives the
  key and the title slug).
- **`JIRA_USER` + `JIRA_API_TOKEN`** — Jira summary and description for `…/browse/KEY-123` URLs
  (the URL alone still gives the key).

## Keybinding

    [[keys.command]]
    key = "prefix+shift+n"
    type = "plugin_action"
    command = "bonkey.wt-purpose.create"
    description = "Worktree from purpose / ticket URL"

Both actions are also in the workspace right-click menu:

- **Worktree from purpose (default branch)** — `create`
- **Worktree from purpose (current branch)** — `create-current` (`wt switch --base @`)

## Behavior

1. A small popup asks for one line. Enter on an empty line cancels. A second line asks what
   to start in the new workspace, by number. Default menu: `[1] claude [2] codex [3] shell`
   (`claude --dangerously-skip-permissions --name <label>`, `codex --yolo`, plain shell); the
   `[run]` table in the config replaces it entirely, arguments included (Enter = first entry).
   A workspace that is not a git checkout gets a toast instead of the popup. Only a chosen
   command gets the removal offer below; the plain shell entry leaves you in the worktree.
2. The popup closes at once; the work continues in an unfocused split titled *creating
   worktree…* below the pane you were in (a tab of that name when none is known), so every
   step and the hook output stay visible while you keep working. The split closes itself when
   done; your own tab keeps its label.
3. If the line is a single URL it is resolved (Linear, GitHub, Jira, or any page's `<title>`);
   anything else is the purpose text.
4. The slug backend gets one prompt on stdin and answers one line; the reply is sanitized to
   `[a-z0-9-]`, at most 40 characters.
5. Branch = `<prefix><TICKET-ID>-<slug>` (prefix defaults to `<your user>/`; the ticket id is the
   Linear/Jira key or the GitHub issue number). A taken name gets `-2`, `-3`, …
6. `wt switch --create … --no-cd` (hooks run here) or `herdr worktree create`, then
   `herdr worktree open --focus`, the chosen command typed into the workspace's shell once it
   is ready, and a toast with the branch name.
7. When that command exits, a clean worktree is offered for removal (`remove worktree …, keep
   branch …? [Y/n]`): `wt remove --no-delete-branch` (or `git worktree remove`), then the
   workspace closes. Uncommitted or untracked files keep it without asking; the branch always
   survives, so `wt switch <branch>` brings the checkout back. Set `offer_remove = false` to
   skip the question. On failure the tab stays
   open with the error until a key is pressed; details are in `last.log` under the plugin's
   state directory.

## Configuration

`$(herdr plugin config-dir bonkey.wt-purpose)/config.toml`:

    # any command that reads the prompt on stdin and prints the slug (default: Apple on-device model)
    slug_command = "llm -m gemini-flash-latest"
    # slug_command = "ollama run llama3.2"
    # slug_command = "llmac"

    # branch prefix (default: "<user>/"); set "" for none
    branch_prefix = "feat/"

    # ask to remove a clean worktree once the started command exits (default: true)
    offer_remove = true

    # the popup's "Run in it" menu, in order; the first entry is the Enter default.
    # {{branch}}, {{label}} (branch without prefix) and {{path}} expand. Keep the keys above
    # this table: TOML puts every later line inside [run].
    [run]
    claude = "claude --dangerously-skip-permissions --name {{label}}"
    codex = "codex --yolo"
    shell = ""

## Development

    git clone https://github.com/bonkey/herdr-wt-purpose
    herdr plugin link "$PWD/herdr-wt-purpose"

Scripts are re-read on every run; relink after editing `herdr-plugin.toml`. Test the worker
without the UI from inside a repo:

    WTP_INPUT="fix the thing" WTP_BASE=default HERDR_PLUGIN_ROOT=/path/to/plugin bash /path/to/plugin/scaffold.sh

## License

MIT
