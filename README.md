<p align="center">
  <img src="assets/ascii-logo.png" alt="worktigre" width="500" />
</p>

<h1 align="center">worktigre</h1>

<p align="center">
  <strong>Git worktrees, on steroids.</strong>
  <br />
  A fast, interactive git worktree manager with GitHub and Claude integration.
</p>

<p align="center">
  <a href="https://worktigre.athevon.dev">Website</a> •
  <a href="https://worktigre.athevon.dev/docs">Documentation</a> •
  <a href="#installation">Installation</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-2.1.0-orange" alt="Version" />
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License" />
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-lightgrey" alt="Platform" />
</p>

---

## Why worktigre?

Git worktrees are powerful but managing them manually is tedious. `wt` provides:

- **One command** to navigate, create, and delete worktrees
- **Quick switch** — `wt feat` to fuzzy-match and jump to a worktree
- **PR workflow** — create a worktree directly from a GitHub PR
- **Issue workflow** — create a worktree from a GitHub issue with auto-named branch
- **Claude integration** — auto-resolve issues, fix CI failures, review PRs
- **Dirty indicator** — see which worktrees have uncommitted changes
- **Persistent settings** — configure editor, platform, prefixes and more via `⚙ Settings`

## Installation

### macOS (Homebrew)

```bash
brew tap AThevon/worktigre && brew install worktigre
```

### Linux / WSL / macOS (universal script)

```bash
curl -fsSL https://raw.githubusercontent.com/AThevon/worktigre/main/install.sh | bash
```

This will install `wt` to `~/.local/bin`, configure your shell, and install required dependencies.

### Nix

```bash
# Try it
nix run github:AThevon/worktigre

# Or add to your flake inputs
# inputs.worktigre.url = "github:AThevon/worktigre";
```

### Update

```bash
wt --update
```

### Setup

On first launch, `wt` automatically runs a preferences wizard to choose your editor and platform. To re-run it at any time:

```bash
wt --wizard
```

## Usage

### Interactive Mode

```bash
wt          # Open interactive menu
wt feat     # Quick switch (fuzzy match)
wt -        # Previous worktree
wt .        # Main worktree
```

### Main Menu

```
wt v2.0.1 │ myapp
──────────────────────────────────────────────────────
  ● main
  ★ feature/new
  ○ feature/auth *
  ◎ fix/bug
  ✓ old-feature

  + Create a worktree
  ⧉ Manage stashes
  ✕ Delete worktree(s)
  ⚙ Settings
  ↩ Quit
──────────────────────────────────────────────────────
^E editor │ ^N new │ ^P PRs │ ^G issues │ ^D delete
```

### Worktree Status Indicators

| Icon | Color | Meaning |
|------|-------|---------|
| `●` | dim | Main branch (main/master) |
| `★` | yellow | New local branch (never pushed) |
| `○` | orange | In progress (pushed, not merged) |
| `◎` | magenta | Review worktree |
| `✓` | green | Merged (squash merge supported) |
| `*` | — | Dirty (uncommitted changes) |

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Enter` | Select / Navigate |
| `Ctrl+N` | Create new worktree |
| `Ctrl+E` | Open in editor |
| `Ctrl+P` | List PRs |
| `Ctrl+G` | List issues |
| `Ctrl+D` | Delete worktree(s) |
| `Ctrl+O` | Open in browser |
| `Tab` | Multi-select |
| `Esc` | Back / Cancel |

## Features

### Create Worktrees

- **New branch** — enter name and select base branch
- **From existing branch** — browse local/remote branches
- **From current** — quick copy with timestamp
- **From an issue** — creates `feature/{issue-num}-{title}` branch
- **Review a PR** — creates worktree with `reviewing-` prefix

### Claude Integration

Launch Claude from any issue or PR with three modes:

| Mode | Description |
|------|-------------|
| **Forced** | Full auto — Claude executes everything |
| **Ask** | Claude confirms before impactful actions |
| **Plan** | Claude creates a plan first |

**Auto-resolve issues:** Claude reads the issue, implements the solution, and creates a PR.

**Fix CI failures:** Claude fetches logs, fixes the code, and pushes.

**Review PRs:** Claude performs a comprehensive code review.

### Settings

Access `⚙ Settings` from the main menu to configure preferences. Settings are saved to `~/.config/wt/config`.

| Key | Default | Description |
|-----|---------|-------------|
| `WT_EDITOR` | auto-detected | Preferred editor (Ctrl+E) |
| `WT_PLATFORM` | auto | Git platform: `auto` / `github` / `gitlab` |
| `WT_WORKTREE_DIR` | *(parent of repo)* | Custom worktree root directory |
| `WT_AUTO_CD` | `true` | Auto-navigate to selected worktree |
| `WT_FEATURE_PREFIX` | `feature/` | Prefix for branches created from issues |
| `WT_AUTO_FETCH` | `true` | Fetch before listing PRs/issues |
| `WT_CLAUDE_MODE` | *(ask each time)* | Default Claude mode: `forced` / `ask` / `plan` |
| `WT_LIST_LIMIT` | `20` | Max items in PR/issue lists |

You can also edit the file directly or reset to defaults via `Ctrl+R` in the Settings menu.

### Stash Management

The stash menu provides a complete workflow with rich information:

- **Enhanced list** — age, file count, original branch
- **Preview panel** — stash info, impacted files, conflict detection
- **Partial stash** — select specific files with `Space`
- **Multi-select drop** — delete multiple stashes at once
- **Create worktree from stash** — `Ctrl+W`
- **Create branch from stash** — `Ctrl+B`
- **Resolve conflicts with Claude** — `Ctrl+R`
- **Export to .patch** — `Ctrl+X`
- **Rename stash** — `Ctrl+E`

| Key | Action |
|-----|--------|
| `Ctrl+A` | Apply stash |
| `Ctrl+P` | Pop stash |
| `Ctrl+D` | Drop stash(es) |
| `Ctrl+W` | Create worktree from stash |
| `Ctrl+B` | Create branch from stash |
| `Ctrl+N` | New stash |
| `Ctrl+E` | Rename stash |
| `Ctrl+R` | Resolve conflicts (Claude) |
| `Ctrl+S` | Partial stash (select files) |
| `Ctrl+X` | Export to .patch |
| `?` | Show all shortcuts |

### PR Status Indicators

| CI | Review | Meaning |
|----|--------|---------|
| `[ok]` | `✓` | Passed / Approved |
| `[fail]` | `✗` | Failed / Changes requested |
| `[..]` | `◀` | Running / Needs **your** review |
| `[draft]` | | Draft PR |

## Dependencies

| Dependency | Required | Purpose |
|------------|----------|---------|
| [fzf](https://github.com/junegunn/fzf) | Yes | Interactive selection |
| [gum](https://github.com/charmbracelet/gum) | Yes | Styled UI (spinners, prompts, inputs) |
| [jq](https://stedolan.github.io/jq/) | Yes | JSON parsing |
| [gh](https://cli.github.com/) | No | GitHub integration |
| [glab](https://gitlab.com/gitlab-org/cli) | No | GitLab integration |
| [claude](https://claude.ai/code) | No | AI features |

## Uninstall

**Nix:**
Remove from your flake inputs and run `home-manager switch` or `nix profile remove`.

**Homebrew:**
```bash
brew uninstall worktigre && brew untap AThevon/worktigre
```

**Manual install (Linux/WSL/macOS):**
```bash
rm ~/.local/bin/wt-core
# Remove these lines from ~/.zshrc or ~/.bashrc:
# export PATH="$HOME/.local/bin:$PATH"
# command -v wt-core &>/dev/null && eval "$(wt-core --shell-init)"
```

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
