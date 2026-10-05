#!/bin/bash

# =============================================================================
# worktigre - Git Worktree Manager avec fzf
# =============================================================================
# Le script retourne UNIQUEMENT le path vers lequel naviguer sur stdout
# Tous les messages vont sur stderr pour ne pas polluer le résultat
# =============================================================================

VERSION="2.3.0"

# Resolve the real location of this script, following symlinks
# (~/.local/bin/wt-core, Homebrew's bin/ link, a --setup symlink...)
_wt_resolve_path() {
  local p="$1" dir link
  while [[ -L "$p" ]]; do
    dir="$(cd -P "$(dirname "$p")" && pwd)"
    link="$(readlink "$p")"
    if [[ "$link" == /* ]]; then p="$link"; else p="$dir/$link"; fi
  done
  echo "$(cd -P "$(dirname "$p")" && pwd)/$(basename "$p")"
}
SCRIPT_PATH="$(_wt_resolve_path "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# =============================================================================
# Shell function (--shell-init / --dev)
# =============================================================================

# Print the `wt` shell function (bash and zsh). $1 is the command it wraps:
# wt-core in release mode, the absolute path of a local wt.sh in dev mode.
# Both modes come from this single template, only the _WT_CORE line differs.
_wt_print_shell_init() {
  echo "# worktigre - Git Worktree Manager"
  printf '_WT_CORE=%q\n' "$1"
  cat <<'EOF'
unalias wt 2>/dev/null
function wt() {
  # --dev / --release: swap the wrapped command (dev = wt.sh of this worktree)
  if [[ "$1" == "--dev" ]]; then
    local _wt_local _wt_init
    _wt_local="$(command git rev-parse --show-toplevel 2>/dev/null)/wt.sh"
    if [[ ! -f "$_wt_local" ]]; then
      echo "wt: no wt.sh found in the current worktree" >&2
      return 1
    fi
    _wt_init="$("$_wt_local" --dev)" || return 1
    eval "$_wt_init"
    return 0
  fi
  if [[ "$1" == "--release" ]]; then
    if ! command -v wt-core >/dev/null 2>&1; then
      echo "wt: wt-core is not in PATH" >&2
      return 1
    fi
    eval "$(command wt-core --shell-init)"
    echo "Switched to release mode: wt-core"
    return 0
  fi

  # Commands that never navigate: no output capture
  case "$1" in
    --help|-h|--version|-v|--setup|--update|--wizard)
      "${_WT_CORE:-wt-core}" "$@"
      return
      ;;
  esac

  local _wt_out _wt_rc
  _wt_out="$("${_WT_CORE:-wt-core}" "$@")"
  _wt_rc=$?

  # Output: the target path and an optional CLAUDE:type:num[:mode] marker
  local _wt_target="" _wt_claude="" _wt_line
  while IFS= read -r _wt_line; do
    if [[ "$_wt_line" == CLAUDE:* ]]; then
      _wt_claude="$_wt_line"
    elif [[ -n "$_wt_line" && -d "$_wt_line" ]]; then
      _wt_target="$_wt_line"
    fi
  done <<< "$_wt_out"

  [[ -z "$_wt_target" ]] && return "$_wt_rc"

  local _wt_tag=""
  [[ "${_WT_CORE:-wt-core}" != "wt-core" ]] && _wt_tag=" [dev]"

  # Auto-CD: environment first, then the config file (same rule as wt-core)
  local _wt_auto_cd="${WT_AUTO_CD:-}"
  if [[ -z "$_wt_auto_cd" ]]; then
    local _wt_cfg="${WT_CONFIG_FILE:-$HOME/.config/wt/config}"
    if [[ -f "$_wt_cfg" ]]; then
      _wt_auto_cd="$(command sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}WT_AUTO_CD=//p' "$_wt_cfg" \
        | command tail -n 1 | command cut -d'#' -f1 | command tr -d "\"' \t")"
    fi
  fi

  if [[ "$_wt_auto_cd" != "false" ]]; then
    # Remember where we come from (for wt -), only from inside a worktree
    local _wt_from
    _wt_from="$(command git rev-parse --show-toplevel 2>/dev/null)"
    cd "$_wt_target" || return 1
    if [[ -n "$_wt_from" && "$_wt_from" != "$_wt_target" ]]; then
      echo "$_wt_from" >| "$HOME/.wt_prev"
    fi
    echo "Navigated to: $_wt_target$_wt_tag"
  else
    echo "Worktree: $_wt_target$_wt_tag"
  fi

  [[ -z "$_wt_claude" ]] && return 0

  # Claude always runs inside the target worktree (in a subshell when
  # auto-cd is off, so the current directory stays the same)
  local _wt_marker _wt_type _wt_num _wt_mode
  IFS=: read -r _wt_marker _wt_type _wt_num _wt_mode <<< "$_wt_claude"

  local _wt_term _wt_ref
  _wt_term="$(cd "$_wt_target" >/dev/null 2>&1 && "${_WT_CORE:-wt-core}" --get-pr-term 2>/dev/null)"
  [[ "$_wt_term" == "MR" ]] || _wt_term="PR"
  _wt_ref="#$_wt_num"
  [[ "$_wt_term" == "MR" ]] && _wt_ref="!$_wt_num"

  local _wt_flag=""
  case "$_wt_type" in
    issue-auto)
      # Auto-resolve: always forced, no mode
      _wt_flag="--dangerously-skip-permissions"
      echo ""
      echo ">> AUTO-RESOLVE: Issue #$_wt_num"
      echo "   Claude will plan, implement, and create a $_wt_term automatically."
      echo ""
      ;;
    ci-fix)
      _wt_flag="--dangerously-skip-permissions"
      echo ""
      echo ">> AUTO-FIX CI: $_wt_term $_wt_ref"
      echo "   Claude will fetch CI logs, fix the issues, and push."
      echo ""
      ;;
    *)
      case "$_wt_mode" in
        forced)
          _wt_flag="--dangerously-skip-permissions"
          echo ""
          echo ">> Starting Claude in FORCED mode..."
          ;;
        ask)
          echo ""
          echo "?> Starting Claude in ASK mode..."
          ;;
        plan)
          _wt_flag="--permission-mode=plan"
          echo ""
          echo "## Starting Claude in PLAN mode..."
          ;;
      esac
      echo ""
      ;;
  esac

  if ! command -v claude >/dev/null 2>&1; then
    echo "wt: claude is not installed, no Claude session started" >&2
    return 1
  fi

  # Prompt generated from the worktree (supports GitHub & GitLab)
  local _wt_prompt
  _wt_prompt="$(cd "$_wt_target" >/dev/null 2>&1 && "${_WT_CORE:-wt-core}" --generate-prompt "$_wt_type" "$_wt_num")"
  if [[ -z "$_wt_prompt" ]]; then
    echo "wt: could not generate the Claude prompt" >&2
    return 1
  fi

  (
    cd "$_wt_target" >/dev/null 2>&1 || exit 1
    if [[ -n "$_wt_flag" ]]; then
      claude "$_wt_flag" "$_wt_prompt"
    else
      claude "$_wt_prompt"
    fi
  )
}
EOF

  # zsh completion of this install (install.sh, git clone, Nix). Homebrew and
  # Nix also put it in fpath as _wt: sourcing it again is harmless.
  local comp="$SCRIPT_DIR/completions/wt.zsh"
  if [[ -f "$comp" ]]; then
    printf '_wt_comp=%q\n' "$comp"
    cat <<'EOF'
if [ -n "${ZSH_VERSION:-}" ] && whence -w compdef >/dev/null 2>&1 && [ -f "$_wt_comp" ]; then
  source "$_wt_comp"
fi
unset _wt_comp
EOF
  fi
}

# Compare dotted versions: is $1 strictly newer than $2? (2.10.0 > 2.9.1)
_wt_version_gt() {
  local a="$1" b="$2" x y
  while [[ -n "$a" || -n "$b" ]]; do
    x="${a%%.*}"; y="${b%%.*}"
    if [[ "$a" == *.* ]]; then a="${a#*.}"; else a=""; fi
    if [[ "$b" == *.* ]]; then b="${b#*.}"; else b=""; fi
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 1
}

# =============================================================================
# Options de ligne de commande
# =============================================================================

if [[ "$1" == "--version" || "$1" == "-v" ]]; then
  echo "wt $VERSION"
  exit 0
fi

if [[ "$1" == "--shell-init" ]]; then
  _wt_print_shell_init wt-core
  exit 0
fi

# Dev mode: same shell function, wrapping this local wt.sh instead of wt-core
if [[ "$1" == "--dev" ]]; then
  _wt_print_shell_init "$SCRIPT_PATH"
  echo "Switched to dev mode: $SCRIPT_PATH" >&2
  exit 0
fi

# Self-update for installs made with install.sh (Nix, Homebrew and git clones
# have their own update path)
if [[ "$1" == "--update" ]]; then
  _REPO="AThevon/worktigre"

  # Colors
  if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    _GREEN=$'\033[32m' _RED=$'\033[31m' _CYAN=$'\033[36m' _BOLD=$'\033[1m' _RESET=$'\033[0m'
  else
    _GREEN='' _RED='' _CYAN='' _BOLD='' _RESET=''
  fi
  _msg() { echo -e "$@" >&2; }

  case "$SCRIPT_PATH" in
    /nix/store/*)
      _msg ""
      _msg "${_RED}[!!]${_RESET} worktigre is installed with Nix."
      _msg "     Update your flake input (nix flake update, then rebuild),"
      _msg "     or run: ${_CYAN}nix profile upgrade worktigre${_RESET}"
      _msg ""
      exit 1
      ;;
    */Cellar/*)
      _msg ""
      _msg "${_RED}[!!]${_RESET} worktigre is installed with Homebrew."
      _msg "     Update with: ${_CYAN}brew upgrade worktigre${_RESET}"
      _msg ""
      exit 1
      ;;
  esac
  if [[ -e "$SCRIPT_DIR/.git" ]]; then
    _msg ""
    _msg "${_RED}[!!]${_RESET} worktigre runs from a git checkout: $SCRIPT_DIR"
    _msg "     Update with: ${_CYAN}git -C \"$SCRIPT_DIR\" pull${_RESET}"
    _msg ""
    exit 1
  fi

  _fetch() {  # _fetch <url> <file>
    if command -v curl &>/dev/null; then
      curl -fsSL "$1" -o "$2" 2>/dev/null
    elif command -v wget &>/dev/null; then
      wget -qO "$2" "$1" 2>/dev/null
    else
      _msg "${_RED}[!!]${_RESET} Neither curl nor wget found"
      return 1
    fi
  }

  _msg ""
  _msg "Checking for updates..."

  _tmp_dir=$(mktemp -d) || exit 1
  trap 'rm -rf "$_tmp_dir"' EXIT

  _tag=""
  if _fetch "https://api.github.com/repos/$_REPO/releases/latest" "$_tmp_dir/latest.json"; then
    _tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_tmp_dir/latest.json" | head -n 1)
  fi
  if [[ -z "$_tag" ]]; then
    _msg "${_RED}[!!]${_RESET} Could not find the latest release on GitHub (network or API limit)"
    exit 1
  fi
  _latest="${_tag#v}"

  if ! _wt_version_gt "$_latest" "$VERSION"; then
    _msg "${_GREEN}[ok]${_RESET} Already up to date (v${VERSION}, latest release: v${_latest})"
    _msg ""
    exit 0
  fi

  # Install prefix: where this wt.sh and its lib/ live. An old single-file
  # wt-core (no lib/ next to it) is replaced by a full install in the default prefix.
  _prefix="$SCRIPT_DIR"
  if [[ ! -f "$_prefix/lib/core.sh" ]]; then
    _prefix="$HOME/.local/share/worktigre"
  fi

  _msg "  ${_CYAN}v${VERSION}${_RESET} → ${_GREEN}v${_latest}${_RESET}"
  _msg ""

  if ! _fetch "https://raw.githubusercontent.com/$_REPO/$_tag/install.sh" "$_tmp_dir/install.sh" ||
     [[ "$(head -c 2 "$_tmp_dir/install.sh" 2>/dev/null)" != "#!" ]]; then
    _msg "${_RED}[!!]${_RESET} Could not download the installer for $_tag"
    exit 1
  fi

  if ! WT_INSTALL_REF="$_tag" WT_INSTALL_PREFIX="$_prefix" bash "$_tmp_dir/install.sh"; then
    _msg ""
    _msg "${_RED}[!!]${_RESET} Update failed: the installer exited with an error"
    exit 1
  fi

  _installed=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$_prefix/wt.sh" 2>/dev/null | head -n 1)
  if [[ "$_installed" != "$_latest" ]]; then
    _msg ""
    _msg "${_RED}[!!]${_RESET} Update incomplete: $_prefix/wt.sh is at version ${_installed:-unknown}, expected $_latest"
    exit 1
  fi

  _msg ""
  _msg "${_GREEN}${_BOLD}Updated to v${_latest}!${_RESET}"
  # wt-core is a symlink (or a small exec wrapper) to <prefix>/wt.sh
  _active=$(command -v wt-core 2>/dev/null)
  if [[ -n "$_active" ]]; then
    _active=$(_wt_resolve_path "$_active")
    if [[ "$_active" != "$_prefix/wt.sh" ]] && ! grep -qF "$_prefix/wt.sh" "$_active" 2>/dev/null; then
      _msg "${_RED}[!!]${_RESET} The wt-core found first in your PATH is another copy: $_active"
    fi
  fi
  _msg "Open a new terminal (or source your shell rc file) to load the new shell function."
  _msg ""
  exit 0
fi

if [[ "$1" == "--setup" ]]; then
  # Colors for setup (defined early since msg() isn't available yet)
  if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    _GREEN=$'\033[32m'
    _RED=$'\033[31m'
    _RESET=$'\033[0m'
  else
    _GREEN='' _RED='' _RESET=''
  fi
  _msg() { echo -e "$@" >&2; }

  _msg ""
  _msg "wt setup"
  _msg "--------"
  _msg ""

  # Detect shell (the wt function is written for bash and zsh)
  shell_name=$(basename "${SHELL:-}")
  case "$shell_name" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash) rc_file="$HOME/.bashrc" ;;
    *)    rc_file="" ;;
  esac
  if [[ -n "$rc_file" ]]; then
    _msg "[ok] Shell: $shell_name"
    _msg "[ok] Config: $rc_file"
  else
    _msg "[!!] Shell: ${shell_name:-unknown} (the wt function supports bash and zsh only)"
  fi
  _msg ""

  # Check dependencies
  _msg "Dependencies:"
  deps_ok=true
  for dep in fzf gum jq; do
    if command -v "$dep" &>/dev/null; then
      _msg "  ${_GREEN}●${_RESET} $dep  installed"
    else
      _msg "  ${_RED}●${_RESET} $dep  ${_RED}missing${_RESET} (install it with your package manager, e.g. brew install $dep)"
      deps_ok=false
    fi
  done
  for dep in gh glab claude; do
    if command -v "$dep" &>/dev/null; then
      _msg "  ${_GREEN}●${_RESET} $dep  installed"
    else
      _msg "  ○ $dep  optional"
    fi
  done
  _msg ""

  if [[ "$deps_ok" == false ]]; then
    _msg "[!!] Install required dependencies first"
    exit 1
  fi

  # wt-core command: a symlink to this script (lib/ is found through it).
  # Never for a packaged copy: a Nix store path can be garbage-collected (and
  # skips the wrapper's PATH), Homebrew links wt-core itself.
  if command -v wt-core &>/dev/null; then
    _msg "[ok] wt-core already in PATH: $(command -v wt-core)"
  elif [[ "$SCRIPT_PATH" == /nix/store/* || "$SCRIPT_PATH" == */Cellar/* ]]; then
    _msg "${_RED}[!!]${_RESET} wt-core is not in your PATH, and this copy is managed by a package manager:"
    if [[ "$SCRIPT_PATH" == /nix/store/* ]]; then
      _msg "     install it with: nix profile install github:AThevon/worktigre"
    else
      _msg "     add Homebrew to your PATH: eval \"\$(brew shellenv)\""
    fi
    _msg ""
    exit 1
  else
    _msg "Setting up wt-core command..."

    # Determine install location
    if [[ -d "/usr/local/bin" && -w "/usr/local/bin" ]]; then
      install_dir="/usr/local/bin"
    else
      install_dir="$HOME/.local/bin"
    fi

    if ! mkdir -p "$install_dir" || ! ln -sf "$SCRIPT_PATH" "$install_dir/wt-core"; then
      _msg "${_RED}[!!]${_RESET} Could not create $install_dir/wt-core"
      exit 1
    fi
    _msg "[ok] Created: $install_dir/wt-core -> $SCRIPT_PATH"

    # Check if install_dir is in PATH
    if [[ ":$PATH:" != *":$install_dir:"* ]]; then
      _msg ""
      _msg "[!!] $install_dir is not in your PATH"
      _msg "     Add this to ${rc_file:-your shell startup file}:"
      _msg ""
      _msg "     export PATH=\"$install_dir:\$PATH\""
      _msg ""
    fi
  fi

  # Shell init line (POSIX: also safe in a file read by another shell)
  init_line='command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"'
  if [[ -z "$rc_file" ]]; then
    _msg ""
    _msg "Nothing was written to a shell startup file."
    _msg "From bash or zsh, add this line to ~/.bashrc or ~/.zshrc:"
    _msg ""
    _msg "  $init_line"
    _msg ""
    exit 0
  elif grep -q "wt-core --shell-init" "$rc_file" 2>/dev/null; then
    _msg "[ok] Already configured in $rc_file"
  else
    _msg ""
    _msg "Adding worktigre to $rc_file..."
    if ! { echo ""; echo "# worktigre - Git Worktree Manager"; echo "$init_line"; } >> "$rc_file"; then
      _msg "${_RED}[!!]${_RESET} Could not write to $rc_file"
      exit 1
    fi
    _msg "[ok] Added to $rc_file"
  fi

  _msg ""
  _msg "--------"
  _msg "${_GREEN}Setup complete!${_RESET}"
  _msg ""
  _msg "To activate now, run:"
  _msg ""
  _msg "  source $rc_file"
  _msg ""
  _msg "Or restart your terminal."
  _msg ""
  exit 0
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  cat >&2 <<EOF
wt - Git Worktree Manager with fzf

Usage: wt [option | name | - | .]

Arguments:
  name             Quick switch: fuzzy match on branch or folder name
  -                Switch to previous worktree (like cd -)
  .                Switch to main worktree

Options:
  --help, -h       Show this help message
  --version, -v    Show version number
  --setup          Link wt-core into your PATH and add the shell init line
                   to ~/.zshrc or ~/.bashrc (from a git clone: ./wt.sh --setup)
  --wizard         Ask again for the editor and the platform
                   (other settings are kept)
  --update         Update an install made with install.sh
                   (Homebrew: brew upgrade worktigre, Nix: update your flake,
                   git clone: git pull)
  --dev            Use wt.sh from the current worktree (wt function only)
  --release        Back to wt-core from PATH (wt function only)

Keyboard shortcuts (main menu):
  Ctrl+E           Open in editor
  Ctrl+N           New worktree
  Ctrl+P           List PRs/MRs
  Ctrl+G           List issues
  Ctrl+D           Delete worktree(s)
  Esc              Quit

Features:
  - Create worktrees from branch, PR/MR, or issue
  - GitHub (gh) and GitLab (glab) support with auto-detection
  - Multi-select delete with Space
  - Dirty indicator (*) for uncommitted changes
  - Claude Code integration (forced/ask/plan modes)

Platform detection:
  From the host of the origin remote ("gitlab" in the host -> GitLab,
  else GitHub). Override with WT_PLATFORM=github|gitlab.

Configuration:
  ${WT_CONFIG_FILE:-~/.config/wt/config} (WT_CONFIG_FILE to use another file),
  edited from wt > Settings. A WT_* variable set in the environment
  (e.g. WT_PLATFORM=gitlab wt) overrides the file.

Quick start:
  ./wt.sh --setup  One-time installation from a git clone
  wt               Interactive menu
  wt <name>        Quick switch to worktree
  wt -             Switch to previous worktree (like cd -)
  wt .             Switch to main worktree

Dependencies: fzf, gum, jq (required), gh/glab, claude (optional)
EOF
  exit 0
fi


# =============================================================================
# Source lib/ modules
# =============================================================================

LIB_DIR="$SCRIPT_DIR/lib"
# Homebrew / Nix: lib/ lives in <prefix>/lib/worktigre, next to bin/
if [[ ! -d "$LIB_DIR" ]]; then
  LIB_DIR="$(dirname "$SCRIPT_DIR")/lib/worktigre"
fi
if [[ ! -f "$LIB_DIR/core.sh" ]]; then
  echo "worktigre: incomplete install, lib/ not found next to $SCRIPT_PATH" >&2
  echo "Reinstall with: curl -fsSL https://raw.githubusercontent.com/AThevon/worktigre/main/install.sh | bash" >&2
  exit 1
fi

source "$LIB_DIR/core.sh"
source "$LIB_DIR/ui.sh"
source "$LIB_DIR/git.sh"
source "$LIB_DIR/cli.sh"
source "$LIB_DIR/prompts.sh"
source "$LIB_DIR/menus.sh"
source "$LIB_DIR/stash.sh"

# =============================================================================
# Repository detection
# =============================================================================

# Project name from a repo path: "proj.git" -> proj, "proj/.bare" -> proj
_wt_repo_name() {
  local dir="${1%/}" name
  name=$(basename "$dir")
  name="${name%.git}"
  if [[ -z "$name" || "$name" == .* ]]; then
    name=$(basename "$(dirname "$dir")")
  fi
  echo "$name"
}

# MAIN_REPO = the main working tree. Usually the first entry of
# `git worktree list`; in a "bare repo + worktrees" layout the first entry is
# the bare repo (not a working tree), so take the worktree on the bare repo's
# HEAD branch, else main/master, else the first one.
# REPO_NAME names the project in the header and in new worktree folders; with
# a bare layout it comes from the bare repo ("proj.git", "proj/.bare").
_wt_detect_repo() {
  local line p="" b="" bare=0 first="" first_bare=0
  local paths=() branches=()
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        if [[ -n "$p" && $bare -eq 0 ]]; then paths+=("$p"); branches+=("$b"); fi
        p="${line#worktree }"
        b=""
        bare=0
        [[ -z "$first" ]] && first="$p"
        ;;
      "branch "*)
        b="${line#branch refs/heads/}"
        ;;
      bare)
        bare=1
        [[ "$p" == "$first" ]] && first_bare=1
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  if [[ -n "$p" && $bare -eq 0 ]]; then paths+=("$p"); branches+=("$b"); fi

  MAIN_REPO=""
  if [[ $first_bare -eq 1 && ${#paths[@]} -gt 0 ]]; then
    local wanted i
    for wanted in "$(git -C "$first" symbolic-ref --short HEAD 2>/dev/null)" main master; do
      [[ -z "$wanted" ]] && continue
      for i in "${!paths[@]}"; do
        if [[ "${branches[$i]}" == "$wanted" ]]; then
          MAIN_REPO="${paths[$i]}"
          break 2
        fi
      done
    done
  fi
  [[ -z "$MAIN_REPO" && ${#paths[@]} -gt 0 ]] && MAIN_REPO="${paths[0]}"
  [[ -z "$MAIN_REPO" ]] && MAIN_REPO="$first"
  [[ -z "$MAIN_REPO" ]] && MAIN_REPO=$(git rev-parse --show-toplevel 2>/dev/null)

  if [[ $first_bare -eq 1 ]]; then
    REPO_NAME=$(_wt_repo_name "$first")
  else
    REPO_NAME=$(_wt_repo_name "$MAIN_REPO")
  fi
}

# Lightweight list for `wt <name>`: "<branch> <folder>\t<path>", read straight
# from git worktree list (no status or merge checks), existing folders only
_wt_quick_switch_list() {
  local label wt_path
  git worktree list --porcelain 2>/dev/null | awk '
    function flush() {
      if (p != "" && !bare) print (b != "" ? b " " : "") n "\t" p
      p = ""; b = ""; bare = 0
    }
    /^worktree / { flush(); p = substr($0, 10); n = p; sub(/.*\//, "", n); next }
    /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b); next }
    /^bare$/     { bare = 1; next }
    END          { flush() }
  ' | while IFS=$'\t' read -r label wt_path; do
    [[ -d "$wt_path" ]] && printf '%s\t%s\n' "$label" "$wt_path"
  done
}

_wt_check_deps() {
  local missing=() dep
  for dep in "$@"; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  msg_error "Missing required dependencies: ${missing[*]}"
  msg "Install them with your package manager, e.g. brew install ${missing[*]}"
  return 1
}

# =============================================================================
# Menu principal
# =============================================================================

main_menu() {
  # Display logo on first launch
  print_logo

  local self_q
  printf -v self_q '%q' "$SCRIPT_PATH"

  while true; do
    # One worktree scan per round; the secondary worktrees (all but
    # MAIN_REPO) are counted from the same list, for the Delete entry
    local worktrees_formatted secondary_count=0 secondary_q="" wt_line wt_path q
    worktrees_formatted=$(format_all_worktrees)
    while IFS= read -r wt_line; do
      [[ "$wt_line" == *$'\t'* ]] || continue
      wt_path="${wt_line#*$'\t'}"
      [[ "$wt_path" == "$MAIN_REPO" ]] && continue
      secondary_count=$((secondary_count + 1))
      [[ "$wt_path" == "$HOME"/* ]] && wt_path="~${wt_path#"$HOME"}"
      printf -v q '%q' "  - $wt_path"
      secondary_q+=" $q"
    done <<< "$worktrees_formatted"

    # Actions: "<label>\t@<id>" (field 2 tells them apart from worktree paths)
    local actions=""
    actions+=$'\n'""  # Ligne vide comme séparateur
    actions+=$'\n'"${C_GREEN}+${C_RESET} Create a worktree"$'\t'"@create"
    actions+=$'\n'"${C_ORANGE}⧉${C_RESET} Manage stashes"$'\t'"@stash"
    if [[ "$secondary_count" -ge 1 ]]; then
      actions+=$'\n'"${C_RED}✕${C_RESET} Delete worktree(s)"$'\t'"@delete"
    fi
    actions+=$'\n'"${C_DIM}⚙${C_RESET} Settings"$'\t'"@settings"
    actions+=$'\n'"${C_DIM}↩${C_RESET} Quit"$'\t'"@quit"

    local menu="${worktrees_formatted}${actions}"

    # Header avec nom du repo
    local pr_term
    pr_term=$(get_pr_term)
    local header="${C_ORANGE}wt${C_RESET} ${C_DIM}v${VERSION}${C_RESET} ${C_DIM}│${C_RESET} ${C_BOLD}${REPO_NAME}${C_RESET}"
    local footer="^E editor │ ^N new │ ^P ${pr_term}s │ ^G issues │ ^D delete"

    # Static bits of the action previews, quoted for the bash preview shell
    local config_short="$WT_CONFIG_FILE" config_q
    [[ "$config_short" == "$HOME"/* ]] && config_short="~${config_short#"$HOME"}"
    printf -v config_q '%q' "Config: $config_short"

    local preview
    IFS= read -r -d '' preview <<EOF || true
case {2} in
  @create)
    echo '> Create a new worktree'
    echo ''
    echo 'Options:'
    echo '  - New branch'
    echo '  - From existing branch'
    echo '  - From current (quick copy)'
    echo '  - From an issue'
    echo '  - Review a $pr_term'
    echo ''
    echo 'Tip: ^N opens this menu directly'
    ;;
  @stash)
    echo '> Manage git stashes'
    echo ''
    stash_count=\$(git stash list 2>/dev/null | wc -l | tr -d ' ')
    echo "Current stashes: \$stash_count"
    echo ''
    if [[ \$stash_count -gt 0 ]]; then
      git stash list 2>/dev/null | head -5
    else
      echo 'No stashes found'
    fi
    ;;
  @delete)
    echo '> Delete worktree(s)'
    echo ''
    echo 'Select one or multiple worktrees to delete.'
    echo 'Use Space to toggle selection.'
    echo ''
    echo 'Secondary worktrees ($secondary_count):'
    printf '%s\n'$secondary_q
    ;;
  @settings)
    echo '> Manage wt preferences'
    echo ''
    echo 'Configure:'
    echo '  IDE, Platform, Worktree dir'
    echo '  Auto-CD, Feature prefix'
    echo '  Auto-fetch, Claude mode'
    echo '  PR/Issue limit'
    echo ''
    echo $config_q
    ;;
  @quit)
    echo '> Exit wt'
    ;;
  '')
    ;;
  *)
    bash $self_q --worktree-preview {2}
    ;;
esac
EOF

    local result rc
    result=$(printf '%s\n' "$menu" | \
      wt_fzf --height=70% \
          --layout=reverse \
          --border \
          --ansi \
          --delimiter=$'\t' \
          --with-nth=1 \
          --header="$header" \
          --footer="$footer" \
          --expect=ctrl-e,ctrl-n,ctrl-p,ctrl-g,ctrl-d \
          --preview="$preview" \
          --preview-window=right:50%)
    rc=$?

    # Esc / Ctrl+C quit; 1 = no match (stay); anything else is an fzf error
    if [[ $rc -eq 130 ]]; then
      return 0
    elif [[ $rc -ne 0 && $rc -ne 1 ]]; then
      msg_error "fzf failed (exit code $rc)"
      return 1
    fi

    # Parse key and selection from fzf --expect output
    local key selected target=""
    key=$(printf '%s\n' "$result" | head -1)
    selected=$(printf '%s\n' "$result" | tail -n +2)
    [[ "$selected" == *$'\t'* ]] && target="${selected#*$'\t'}"

    local output
    # Handle keyboard shortcuts
    case "$key" in
      ctrl-e)
        if [[ "$target" == /* && -d "$target" ]]; then
          msg "Opening in $(get_editor): $target"
          open_in_editor "$target"
        fi
        continue
        ;;
      ctrl-n)
        output=$(menu_create_worktree)
        if [[ -n "$output" ]]; then
          echo "$output"
          return 0
        fi
        continue
        ;;
      ctrl-p)
        output=$(menu_review_pr)
        if [[ -n "$output" ]]; then
          echo "$output"
          return 0
        fi
        continue
        ;;
      ctrl-g)
        output=$(menu_from_issue)
        if [[ -n "$output" ]]; then
          echo "$output"
          return 0
        fi
        continue
        ;;
      ctrl-d)
        output=$(action_delete_worktrees)
        if [[ -n "$output" && -d "$output" ]]; then
          echo "$output"
          return 0
        fi
        continue
        ;;
    esac

    case "$target" in
      "")
        # Separator line, or Enter with no match: stay in the menu
        continue
        ;;
      @create)
        output=$(menu_create_worktree)
        if [[ -n "$output" ]]; then
          echo "$output"
          return 0
        fi
        ;;
      @stash)
        # menu_stash prints the path of a worktree to open, if any
        output=$(menu_stash)
        output=$(printf '%s\n' "$output" | tail -n 1)
        if [[ -n "$output" && -d "$output" ]]; then
          echo "$output"
          return 0
        fi
        ;;
      @settings)
        # Same shell (settings update variables in place); stdout kept clean
        menu_settings >&2
        ;;
      @delete)
        output=$(action_delete_worktrees)
        if [[ -n "$output" && -d "$output" ]]; then
          echo "$output"
          return 0
        fi
        ;;
      @quit)
        return 0
        ;;
      *)
        # Existing worktree (field 2 = absolute path)
        if [[ -d "$target" ]]; then
          echo "$target"
          return 0
        fi
        ;;
    esac
  done
}

# =============================================================================
# Point d'entrée
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

MAIN_REPO=""
REPO_NAME=""
_wt_in_repo=false
if git rev-parse --git-dir >/dev/null 2>&1; then
  _wt_in_repo=true
  _wt_detect_repo
fi

load_config

# Re-run the editor/platform questions, works outside a repo too
if [[ "$1" == "--wizard" ]]; then
  _wt_check_deps fzf || exit 1
  _wt_fzf_detect
  run_preferences_wizard --standalone
  exit $?
fi

# Switch to previous worktree (like cd -), works outside a repo too
if [[ "$1" == "-" ]]; then
  if [[ -f "$HOME/.wt_prev" ]]; then
    prev=$(head -n 1 "$HOME/.wt_prev")
    if [[ -n "$prev" && -d "$prev" ]]; then
      echo "$prev"
      exit 0
    fi
    msg "Previous worktree no longer exists: $prev"
    exit 1
  fi
  msg "No previous worktree yet (it is recorded when you switch with wt from inside a worktree)"
  exit 1
fi

_wt_internal=false
case "$1" in
  --pr-preview|--issue-preview|--pr-status-preview|--worktree-preview|--generate-prompt|--get-pr-term)
    _wt_internal=true
    ;;
  -?*)
    msg_error "Unknown option: $1 (see wt --help)"
    exit 1
    ;;
esac

if [[ "$_wt_in_repo" != "true" ]]; then
  msg_error "Not in a git repository"
  exit 1
fi

if [[ "$_wt_internal" != "true" ]]; then
  # Switch to main worktree
  if [[ "$1" == "." ]]; then
    if [[ -n "$MAIN_REPO" && -d "$MAIN_REPO" ]]; then
      echo "$MAIN_REPO"
      exit 0
    fi
    msg_error "Could not find the main worktree"
    exit 1
  fi

  # Quick switch: wt <name> fuzzy matches on branch and folder names
  if [[ -n "$1" ]]; then
    _wt_check_deps fzf || exit 1
    match=$(_wt_quick_switch_list | (
      unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE
      command fzf --filter="$1" --delimiter=$'\t' --nth=1
    ) | head -n 1)
    if [[ -n "$match" ]]; then
      echo "${match#*$'\t'}"
      exit 0
    fi
    msg "No worktree matching '$1'"
    exit 1
  fi
fi

# Caches shared with nested wt-core processes (fzf previews). They are tied to
# MAIN_REPO, so values inherited from a wt started in another repo are dropped.
if [[ "${_WT_CACHE_REPO:-}" != "$MAIN_REPO" ]]; then
  _WT_DEFAULT_BRANCH=""
  _WT_PLATFORM=""
fi
_WT_CACHE_REPO="$MAIN_REPO"
_WT_DEFAULT_BRANCH=$(get_default_branch)
_WT_PLATFORM=$(detect_platform)
export _WT_CACHE_REPO _WT_DEFAULT_BRANCH _WT_PLATFORM

case "$1" in
  --pr-preview)
    pr_preview "$2"
    exit 0
    ;;
  --issue-preview)
    issue_preview "$2"
    exit 0
    ;;
  --pr-status-preview)
    cli_pr_status "$2"
    exit 0
    ;;
  --worktree-preview)
    worktree_preview "$2"
    exit 0
    ;;
  --generate-prompt)
    generate_prompt "$2" "$3"
    exit $?
    ;;
  --get-pr-term)
    get_pr_term
    exit 0
    ;;
esac

_wt_check_deps fzf gum jq || exit 1
_wt_fzf_detect

# First-time setup wizard
if [[ -t 2 ]]; then
  if ! command -v wt-core &>/dev/null; then
    run_install_wizard || true
  elif [[ ! -f "$WT_CONFIG_FILE" ]]; then
    run_preferences_wizard
  fi
fi

# Run main menu and capture result
result=$(main_menu)
rc=$?

if [[ -n "$result" ]]; then
  echo "$result"
fi
exit $rc

fi
