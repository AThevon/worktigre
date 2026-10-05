<p align="center">
  <img src="assets/ascii-logo.png" alt="worktigre" width="500" />
</p>

<h1 align="center">worktigre</h1>

<p align="center">
  <strong>Switch, create and clean up git worktrees from one fzf menu.</strong>
  <br />
  Works with GitHub and GitLab, and can hand an issue or a PR straight to Claude Code.
</p>

<p align="center">
  <a href="https://worktigre.athevon.dev">Website</a> •
  <a href="https://worktigre.athevon.dev/docs">Documentation</a> •
  <a href="#installation">Installation</a>
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/AThevon/worktigre?color=orange" alt="Version" />
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License" />
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-lightgrey" alt="Platform" />
</p>

---

## Why

Worktrees let you keep several branches checked out side by side, but the raw `git worktree` commands get old fast. `wt` puts them behind a keyboard-driven menu: pick a worktree and you `cd` into it, press a key to create one from a branch, an issue or a pull request, select a few and delete them. The list shows which ones are dirty, merged, never pushed or under review.

## Installation

### Homebrew (macOS)

```bash
brew tap AThevon/worktigre && brew install worktigre
```

### Install script (Linux, WSL, macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/AThevon/worktigre/main/install.sh | bash
```

The script installs the latest release in `~/.local/share/worktigre`, links `~/.local/bin/wt-core` to it, adds the shell init line to `~/.zshrc` or `~/.bashrc`, and installs `fzf`, `gum` and `jq` with your package manager when they are missing. apt and dnf don't ship `gum`; there the script prints the official Charm repository instructions instead.

### Nix

```bash
# Try it
nix run github:AThevon/worktigre

# Or add it to your flake inputs
# inputs.worktigre.url = "github:AThevon/worktigre";
```

### Shell integration

`wt-core` is the program, `wt` is a small shell function around it. The function is what lets `wt` change your current directory and start Claude in the right worktree. The install script sets it up for you. With Homebrew or Nix, add this line to `~/.zshrc` or `~/.bashrc`:

```bash
command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"
```

From a git clone, `./wt.sh --setup` links `wt-core` into your `PATH` and adds the same line.

### First launch

The first `wt` asks for your editor and your platform (GitHub, GitLab or auto). Run it again with `wt --wizard`; the other settings are kept.

### Update

| Install | Update with |
|---------|-------------|
| Homebrew | `brew upgrade worktigre` |
| Install script | `wt --update` |
| Nix | `nix flake update` (or `nix profile upgrade`) |
| Git clone | `git pull` |

`wt --update` only updates installs made by the script and tells you what to run otherwise.

## Usage

```bash
wt          # open the menu
wt auth     # jump to the worktree whose branch or folder matches "auth"
wt -        # back to the previous worktree
wt .        # main worktree
```

The main menu lists your worktrees, then the actions:

```
wt vX.Y.Z │ myapp
──────────────────────────────────────────
  ● main
  ★ feature/new-onboarding
  ○ feature/auth *
  ◎ fix-login-redirect
  ✓ feature/old-search

  + Create a worktree
  ⧉ Manage stashes
  ✕ Delete worktree(s)
  ⚙ Settings
  ↩ Quit
──────────────────────────────────────────
^E editor │ ^N new │ ^P PRs │ ^G issues │ ^D delete
```

`Delete worktree(s)` only shows up when there is at least one worktree besides the main one. The preview on the right shows the branch status, uncommitted changes, ahead/behind counts, recent commits and the matching PR or MR.

### Worktree icons

| Icon | Color | Meaning |
|------|-------|---------|
| `●` | dim | Default branch (main/master) |
| `◌` | dim | Detached HEAD |
| `★` | yellow | Never pushed |
| `○` | orange | Pushed, not merged |
| `◎` | magenta | Review worktree (created from a PR/MR) |
| `✓` | green | Merged into the default branch, squash merges included |
| `*` | | Uncommitted changes |

## Keyboard shortcuts

Every menu works with the arrow keys, `Enter` to select and `Esc` (or `Ctrl+C`) to go back.

**Main menu**

| Key | Action |
|-----|--------|
| `Ctrl+E` | Open the worktree in your editor |
| `Ctrl+N` | Create a worktree |
| `Ctrl+P` | List PRs / MRs |
| `Ctrl+G` | List issues |
| `Ctrl+D` | Delete worktree(s) |

**Create a worktree**

| Key | Action |
|-----|--------|
| `Ctrl+N` | New branch |
| `Ctrl+B` | From an existing branch (local or remote) |
| `Ctrl+T` | From the current branch |
| `Ctrl+G` | From an issue |
| `Ctrl+P` | Review a PR / MR |

**PR and issue lists**: `Ctrl+O` opens the item in the browser.

**PR actions**: `Ctrl+R` review, `Ctrl+L` launch Claude, `Ctrl+W` worktree only, `Ctrl+F` fix CI (only when the CI failed).

**Issue actions**: `Ctrl+A` auto-resolve, `Ctrl+L` launch Claude, `Ctrl+W` worktree only.

**Claude mode**: `Ctrl+F` forced, `Ctrl+A` ask, `Ctrl+P` plan.

**Delete**: `Space` to select, `Ctrl+A` to select all, `Enter` to confirm.

**Settings**: `Enter` to edit a value, `Ctrl+R` to reset everything.

## Creating worktrees

New worktrees go next to the main repository (or in `WT_WORKTREE_DIR`) and are named `{repo}-{branch}`, with `/` turned into `-`.

| From | Branch | Folder |
|------|--------|--------|
| New branch | the name you type, from the base you pick (`-2`, `-3` if taken) | `myapp-feature-login` |
| Existing branch | the branch itself; a remote branch gets a local tracking branch | `myapp-feature-login` |
| Current branch | `temp/{branch}-{timestamp}` from `HEAD` (committed state only) | `myapp-temp-main-20261002-101500` |
| Issue | `{WT_FEATURE_PREFIX}{number}-{title-slug}`, from the up-to-date default branch | `myapp-feature-42-fix-login` |
| PR / MR | the PR branch, or `pr/{number}-{branch}` (`mr/...` on GitLab) for forks | `myapp-reviewing-fix-login` |

If the branch is already open in a worktree, `wt` takes you there instead of failing. Opening the same PR again fast-forwards its worktree when it is clean.

New branches never track the default branch, so a plain `git push` can't land on `main`.

### .env files

When a worktree is created, `wt` copies the `.env*` files found at the root of the main worktree into it. It skips files tracked by git, `*.example`, `*.sample` and `*.template` files, and never overwrites a file that already exists. PRs from forks don't get them.

## Claude Code integration

From a PR or an issue, `wt` creates the worktree, moves you into it and starts `claude` with a prompt for the task. Claude always runs inside the new worktree, even with `WT_AUTO_CD=false`.

| Mode | Flag | Behavior |
|------|------|----------|
| Forced | `--dangerously-skip-permissions` | Runs commands without asking |
| Ask | none | Asks before impactful actions |
| Plan | `--permission-mode=plan` | Writes a plan before changing anything |

`WT_CLAUDE_MODE` skips the mode picker.

Two actions always run in forced mode, without asking for confirmation:

- **Auto-resolve** (issue): reads the issue, implements it, runs the tests, pushes the branch and opens a PR/MR.
- **Fix CI** (PR, only offered when the CI failed): reads the failed logs, fixes the code and pushes.

**Review** asks Claude for a review of the diff: what looks good, concerns with file and line, blocking issues and a recommendation.

## Stash management

`⧉ Manage stashes` lists the stashes with their age, file count, original branch and message. The preview shows the files and warns about likely conflicts. Press `Enter` on a stash for the action menu, or use the same keys directly from the list:

| Key | Action |
|-----|--------|
| `Ctrl+A` | Apply (keep the stash) |
| `Ctrl+P` | Pop (apply and drop) |
| `Ctrl+D` | Drop (works on several stashes selected with `Space`) |
| `Ctrl+L` | Apply and resolve conflicts with Claude |
| `Ctrl+W` | Create a worktree from the stash |
| `Ctrl+B` | Create a branch from the stash |
| `Ctrl+X` | Export as a `.patch` file (in `~/Downloads`, or `$TMPDIR`) |
| `Ctrl+S` | Show the full diff |
| `Ctrl+R` | Rename |
| `Ctrl+N` | New stash (all changes, untracked included) |
| `Ctrl+E` | Partial stash (pick files) |
| `?` | Show all shortcuts |

## Settings

`⚙ Settings` edits `~/.config/wt/config`. Set `WT_CONFIG_FILE` to use another file. A `WT_*` variable set in your environment wins over the file, for example `WT_PLATFORM=gitlab wt`.

| Key | Default | Description |
|-----|---------|-------------|
| `WT_EDITOR` | auto (cursor, code, `$EDITOR`, vim) | Editor opened by `Ctrl+E`. Terminal editors take over the screen, GUI editors open in the background |
| `WT_PLATFORM` | `auto` | `auto`, `github` or `gitlab`. Auto looks at the host of the `origin` remote |
| `WT_WORKTREE_DIR` | parent of the repo | Where new worktrees go (absolute path or `~/...`) |
| `WT_AUTO_CD` | `true` | `cd` into the selected worktree |
| `WT_FEATURE_PREFIX` | `feature/` | Branch prefix for issue worktrees |
| `WT_AUTO_FETCH` | `true` | Fetch before listing branches and before creating an issue worktree |
| `WT_CLAUDE_MODE` | ask each time | `forced`, `ask` or `plan` |
| `WT_LIST_LIMIT` | `20` | Number of PRs and issues to list |

`wt` uses its own orange fzf theme unless you set `FZF_DEFAULT_OPTS` or `FZF_DEFAULT_OPTS_FILE`.

## Requirements

| Tool | Required | Notes |
|------|----------|-------|
| git | yes | |
| bash | yes | 3.2 or later, the macOS system bash works. The `wt` function works in zsh and bash |
| [fzf](https://github.com/junegunn/fzf) | yes | Any recent version. Footers need 0.63+, older versions show them in the header |
| [gum](https://github.com/charmbracelet/gum) | yes | Prompts, confirmations and spinners |
| [jq](https://jqlang.org) | yes | PR and issue lists |
| [gh](https://cli.github.com/) | for GitHub | PRs, issues, CI status |
| [glab](https://gitlab.com/gitlab-org/cli) | for GitLab | MRs, issues, pipelines |
| [Claude Code](https://claude.com/product/claude-code) | no | Claude actions |

## Uninstall

**Homebrew**

```bash
brew uninstall worktigre && brew untap AThevon/worktigre
```

**Install script**

```bash
rm -rf ~/.local/share/worktigre ~/.local/bin/wt-core
```

**Nix**: remove it from your flake inputs or run `nix profile remove worktigre`.

In every case, also remove the `wt-core --shell-init` line from your shell rc file. `wt` leaves `~/.config/wt/config` and `~/.wt_prev` behind; delete them if you don't plan to come back.

## License

GPL-3.0

---

<p align="center">
  Built by <a href="https://athevon.dev"><strong>Adrien Thevon</strong></a>, software engineer in Toulouse.
  <br />
  <sub>
    Also mine:
    <a href="https://github.com/AThevon/TokenEater">TokenEater</a>, a native macOS monitor for Claude usage limits
    &nbsp;·&nbsp;
    <a href="https://github.com/AThevon/genjutsu">genjutsu</a>, creative coding skills for Claude
  </sub>
</p>
