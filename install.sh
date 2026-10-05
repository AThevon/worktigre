#!/bin/bash

# =============================================================================
# worktigre - Universal Installer
# =============================================================================
# Usage: curl -fsSL https://raw.githubusercontent.com/AThevon/worktigre/main/install.sh | bash
#
# Installs a release into ~/.local/share/worktigre (wt.sh, lib/, assets/,
# completions/) and links ~/.local/bin/wt-core to its wt.sh.
#
# Environment overrides:
#   WT_INSTALL_REF      tag or branch to install (default: latest release)
#   WT_INSTALL_TARBALL  URL or local path of a source tarball (wins over the ref)
#   WT_INSTALL_PREFIX   install directory (default: ~/.local/share/worktigre)
#
# Every message goes to stderr: `wt --update` runs this script from inside the
# shell function, whose stdout is reserved for the path to cd into.
# =============================================================================

REPO="AThevon/worktigre"
BIN_DIR="${HOME}/.local/bin"
INIT_LINE='command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"'
# Line written to ~/.profile by older installers: bash-only, breaks /bin/sh
OLD_PROFILE_LINE='command -v wt-core &>/dev/null && eval "$(wt-core --shell-init)"'
POSIX_PROFILE_LINE='[ -n "$BASH_VERSION$ZSH_VERSION" ] && command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"'

# Colors
if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  DIM=$'\033[2m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN='' RED='' YELLOW='' CYAN='' DIM='' BOLD='' RESET=''
fi

say()   { printf '%s\n' "$*" >&2; }
info()  { say "${GREEN}[ok]${RESET} $*"; }
warn()  { say "${RED}[!!]${RESET} $*"; }
note()  { say "${YELLOW}[..]${RESET} $*"; }
dim()   { say "${DIM}$*${RESET}"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# ~ instead of $HOME in displayed paths
tilde() {
  case "$1" in
    "$HOME"/*) printf '%s\n' "~${1#"$HOME"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

TMP_DIR=""
STAGING_DIR=""
OLD_DIR=""
PREFIX_DIR=""
SOURCE_DESC=""
RC_FILE=""

cleanup() {
  # Interrupted between the two renames of swap_in: put the old install back
  if [[ -n "$OLD_DIR" && -d "$OLD_DIR/prev" && ! -e "$PREFIX_DIR" ]]; then
    mv "$OLD_DIR/prev" "$PREFIX_DIR"
  fi
  [[ -n "$OLD_DIR" && -d "$OLD_DIR" ]] && rm -rf "$OLD_DIR"
  [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]] && rm -rf "$STAGING_DIR"
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

die() {
  warn "$*"
  cleanup
  exit 1
}

# --- Dependencies -------------------------------------------------------------

PKG_MANAGER=""
APT_UPDATED=0
MISSING_DEPS=""

detect_pkg_manager() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    have brew && PKG_MANAGER=brew
  elif have apt-get; then
    PKG_MANAGER=apt
  elif have dnf; then
    PKG_MANAGER=dnf
  elif have pacman; then
    PKG_MANAGER=pacman
  elif have brew; then
    PKG_MANAGER=brew
  fi
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    return 1
  fi
}

# Package managers never get stdin: with `curl | bash` it is this script.
pkg_install() {
  local manager="$1" pkg="$2"
  case "$manager" in
    apt)
      if [[ "$APT_UPDATED" == "0" ]]; then
        as_root apt-get update -qq </dev/null >&2 || true
        APT_UPDATED=1
      fi
      # Not packaged in this release (gum before Ubuntu 25.04 / Debian 13)
      apt-cache show "$pkg" >/dev/null 2>&1 || return 1
      as_root apt-get install -y -qq "$pkg" </dev/null >&2
      ;;
    dnf)    as_root dnf install -y "$pkg" </dev/null >&2 ;;
    pacman) as_root pacman -S --needed --noconfirm "$pkg" </dev/null >&2 ;;
    brew)   brew install "$pkg" </dev/null >&2 ;;
    *)      return 1 ;;
  esac
}

install_dep() {
  local dep="$1"
  [[ -n "$PKG_MANAGER" ]] || return 1
  pkg_install "$PKG_MANAGER" "$dep" && have "$dep" && return 0
  # Linuxbrew next to the system package manager
  if [[ "$PKG_MANAGER" != "brew" ]] && have brew; then
    pkg_install brew "$dep" && have "$dep" && return 0
  fi
  return 1
}

dep_help() {
  local dep="$1"
  case "$dep" in
    gum)
      case "$PKG_MANAGER" in
        apt)
          say "     gum is not in your apt sources, add the official Charm repository:"
          say "       sudo mkdir -p /etc/apt/keyrings"
          say "       curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg"
          say "       echo \"deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *\" | sudo tee /etc/apt/sources.list.d/charm.list"
          say "       sudo apt update && sudo apt install gum"
          ;;
        dnf)
          say "     Add the official Charm repository, then install gum:"
          say "       printf '[charm]\\nname=Charm\\nbaseurl=https://repo.charm.sh/yum/\\nenabled=1\\ngpgcheck=1\\ngpgkey=https://repo.charm.sh/yum/gpg.key\\n' | sudo tee /etc/yum.repos.d/charm.repo"
          say "       sudo rpm --import https://repo.charm.sh/yum/gpg.key"
          say "       sudo dnf install gum"
          ;;
        brew)   say "     brew install gum" ;;
        pacman) say "     sudo pacman -S gum" ;;
        *)      say "     See https://github.com/charmbracelet/gum#installation" ;;
      esac
      ;;
    fzf)
      case "$PKG_MANAGER" in
        apt)    say "     sudo apt install fzf" ;;
        dnf)    say "     sudo dnf install fzf" ;;
        pacman) say "     sudo pacman -S fzf" ;;
        brew)   say "     brew install fzf" ;;
        *)      say "     See https://github.com/junegunn/fzf#installation" ;;
      esac
      ;;
    jq)
      case "$PKG_MANAGER" in
        apt)    say "     sudo apt install jq" ;;
        dnf)    say "     sudo dnf install jq" ;;
        pacman) say "     sudo pacman -S jq" ;;
        brew)   say "     brew install jq" ;;
        *)      say "     See https://jqlang.org/download/" ;;
      esac
      ;;
  esac
}

check_dependencies() {
  local dep
  say "Dependencies:"
  detect_pkg_manager

  for dep in fzf gum jq; do
    if have "$dep"; then
      info "$dep"
      continue
    fi
    note "$dep (required) - installing..."
    if install_dep "$dep"; then
      info "$dep installed"
    else
      warn "Could not install $dep automatically"
      dep_help "$dep"
      MISSING_DEPS="${MISSING_DEPS:+$MISSING_DEPS }$dep"
    fi
  done

  for dep in gh glab claude; do
    if have "$dep"; then
      info "$dep"
    else
      dim "  [--] $dep (optional)"
    fi
  done
  say ""
}

# --- Download -----------------------------------------------------------------

fetch() {
  if have curl; then
    curl -fsSL --retry 2 "$1" -o "$2"
  elif have wget; then
    wget -qO "$2" "$1"
  else
    return 127
  fi
}

fetch_stdout() {
  if have curl; then
    curl -fsSL -H 'Accept: application/vnd.github+json' "$1"
  elif have wget; then
    wget -qO- --header='Accept: application/vnd.github+json' "$1"
  else
    return 127
  fi
}

latest_release_tag() {
  local json
  json=$(fetch_stdout "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || return 1
  printf '%s\n' "$json" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n 1 \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

# Fills $TMP_DIR/src.tar.gz and sets SOURCE_DESC
get_tarball() {
  local tarball="${WT_INSTALL_TARBALL:-}" ref="${WT_INSTALL_REF:-}" url

  if [[ -n "$tarball" ]]; then
    case "$tarball" in
      file://*) tarball="${tarball#file://}" ;;
    esac
    if [[ -f "$tarball" ]]; then
      SOURCE_DESC="local tarball $tarball"
      cp "$tarball" "$TMP_DIR/src.tar.gz"
      return
    fi
    case "$tarball" in
      http://*|https://*) ;;
      *) warn "WT_INSTALL_TARBALL: no such file: $tarball"; return 1 ;;
    esac
    SOURCE_DESC="tarball $tarball"
    fetch "$tarball" "$TMP_DIR/src.tar.gz" || { warn "Download failed: $tarball"; return 1; }
    return 0
  fi

  if ! have curl && ! have wget; then
    warn "Neither curl nor wget found - cannot download"
    return 1
  fi

  if [[ -z "$ref" ]]; then
    ref=$(latest_release_tag)
    if [[ -n "$ref" ]]; then
      SOURCE_DESC="release $ref"
    else
      ref="main"
      SOURCE_DESC="branch main"
      note "Could not resolve the latest release (GitHub API), installing from main"
    fi
  else
    SOURCE_DESC="ref $ref"
  fi

  case "$ref" in
    *[!A-Za-z0-9._/-]*) warn "Invalid ref: $ref"; return 1 ;;
  esac

  url="https://github.com/$REPO/archive/$ref.tar.gz"
  fetch "$url" "$TMP_DIR/src.tar.gz" || { warn "Download failed: $url"; return 1; }
}

# Prints the extracted source root (the directory holding wt.sh and lib/)
find_source_root() {
  local dir="$1" candidate
  if [[ -f "$dir/wt.sh" && -f "$dir/lib/core.sh" ]]; then
    echo "$dir"
    return 0
  fi
  for candidate in "$dir"/*/; do
    candidate="${candidate%/}"
    if [[ -f "$candidate/wt.sh" && -f "$candidate/lib/core.sh" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# --- Install ------------------------------------------------------------------

is_wt_install() {
  [[ -f "$1/.worktigre-install" ]] || [[ -f "$1/wt.sh" && -f "$1/lib/core.sh" ]]
}

dir_is_empty() {
  [[ -z "$(ls -A "$1" 2>/dev/null)" ]]
}

stage_files() {
  local src="$1" dest="$2" version="$3"
  mkdir -p "$dest/lib" "$dest/assets" "$dest/completions" || return 1
  cp "$src/wt.sh" "$dest/wt.sh" || return 1
  chmod 755 "$dest" "$dest/wt.sh" || return 1
  cp "$src"/lib/*.sh "$dest/lib/" || return 1
  if ls "$src"/assets/logo*.ansi >/dev/null 2>&1; then
    cp "$src"/assets/logo*.ansi "$dest/assets/" || return 1
  fi
  if [[ -f "$src/completions/wt.zsh" ]]; then
    cp "$src/completions/wt.zsh" "$dest/completions/" || return 1
  fi
  if [[ -f "$src/LICENSE" ]]; then
    cp "$src/LICENSE" "$dest/" || return 1
  fi
  printf 'version=%s\nsource=%s\n' "$version" "$SOURCE_DESC" > "$dest/.worktigre-install"
}

# Runs `<cmd> --get-pr-term` in a scratch git repo: unlike --version, this
# loads lib/. Returns 2 when git is missing (check skipped).
smoke_test() {
  local repo="$TMP_DIR/smoke-repo" out
  have git || return 2
  if [[ ! -d "$repo" ]]; then
    git init -q "$repo" >/dev/null 2>&1 || return 2
  fi
  out=$(cd "$repo" && "$@" --get-pr-term 2>/dev/null </dev/null) || return 1
  [[ -n "$out" ]]
}

# Puts the staged directory in place of the prefix (two renames, the old
# install is restored if the second one fails)
swap_in() {
  local staged="$1" prefix="$2"
  PREFIX_DIR="$prefix"
  if [[ -d "$prefix" ]]; then
    OLD_DIR=$(mktemp -d "$(dirname "$prefix")/.worktigre-old.XXXXXX") || return 1
    mv "$prefix" "$OLD_DIR/prev" || return 1
  fi
  if ! mv "$staged" "$prefix"; then
    [[ -n "$OLD_DIR" ]] && mv "$OLD_DIR/prev" "$prefix"
    return 1
  fi
  STAGING_DIR=""
  if [[ -n "$OLD_DIR" ]]; then
    rm -rf "$OLD_DIR"
    OLD_DIR=""
  fi
  return 0
}

# Points $BIN_DIR/wt-core at the install (renamed over the old link or file)
link_command() {
  local prefix="$1" mode="$2" link="$BIN_DIR/wt-core" tmp_link
  mkdir -p "$BIN_DIR" || return 1
  if [[ -d "$link" ]]; then
    warn "$link is a directory, remove it and run the installer again"
    return 1
  fi
  if [[ -f "$link" && ! -L "$link" ]]; then
    dim "  Replacing the previous single-file $(tilde "$link")"
  fi
  tmp_link="$BIN_DIR/.wt-core.$$"
  rm -f "$tmp_link"
  if [[ "$mode" == "wrapper" ]]; then
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$prefix/wt.sh" > "$tmp_link" || return 1
    chmod 755 "$tmp_link" || return 1
  else
    ln -s "$prefix/wt.sh" "$tmp_link" || return 1
  fi
  mv -f "$tmp_link" "$link"
}

install_worktigre() {
  local prefix="${WT_INSTALL_PREFIX:-$HOME/.local/share/worktigre}"
  local parent src version first rc link_mode="symlink"

  while [[ "$prefix" == */ && "$prefix" != "/" ]]; do prefix="${prefix%/}"; done
  case "$prefix" in
    /*) ;;
    *) prefix="$PWD/$prefix" ;;
  esac
  case "$prefix" in
    /|"$HOME"|"$BIN_DIR") die "Refusing to install into $prefix, set WT_INSTALL_PREFIX to a dedicated directory" ;;
  esac
  if [[ -L "$prefix" ]]; then
    die "$prefix is a symlink, remove it or set WT_INSTALL_PREFIX to another directory"
  fi
  if [[ -e "$prefix" ]]; then
    [[ -d "$prefix" ]] || die "$prefix exists and is not a directory"
    if ! dir_is_empty "$prefix" && ! is_wt_install "$prefix"; then
      die "$prefix is not a worktigre install, refusing to replace it (set WT_INSTALL_PREFIX to another directory)"
    fi
  fi

  say "Installing worktigre..."

  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/worktigre-install.XXXXXX") || die "Could not create a temp directory"
  get_tarball || die "Could not get the worktigre sources"
  mkdir -p "$TMP_DIR/extract"
  tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR/extract" || die "Could not extract the tarball ($SOURCE_DESC)"
  src=$(find_source_root "$TMP_DIR/extract") || die "The tarball doesn't contain wt.sh and lib/ ($SOURCE_DESC)"
  version=$(grep -m1 '^VERSION=' "$src/wt.sh" | cut -d'"' -f2)
  [[ -n "$version" ]] || die "No VERSION found in wt.sh ($SOURCE_DESC)"

  parent=$(dirname "$prefix")
  mkdir -p "$parent" || die "Could not create $parent"
  STAGING_DIR=$(mktemp -d "$parent/.worktigre-new.XXXXXX") || die "Could not create a staging directory in $parent"
  stage_files "$src" "$STAGING_DIR" "$version" || die "Could not copy the files to $STAGING_DIR"

  # Releases without symlink support (2.2.0 and older) look for lib/ next to
  # the link itself: give them a small exec wrapper instead.
  ln -s "$STAGING_DIR/wt.sh" "$TMP_DIR/wt-core"
  smoke_test "$TMP_DIR/wt-core"
  rc=$?
  if [[ $rc -eq 1 ]]; then
    if smoke_test "$STAGING_DIR/wt.sh"; then
      link_mode="wrapper"
    else
      die "worktigre v$version ($SOURCE_DESC) doesn't start, nothing was changed"
    fi
  elif [[ $rc -eq 2 ]]; then
    note "git not found, skipped the post-install check"
  fi

  swap_in "$STAGING_DIR" "$prefix" || die "Could not move the new files to $prefix"
  link_command "$prefix" "$link_mode" || die "Could not create $BIN_DIR/wt-core"

  info "worktigre v${version} installed to ${CYAN}$(tilde "$prefix")${RESET} ${DIM}(${SOURCE_DESC})${RESET}"
  info "Command: ${CYAN}$(tilde "$BIN_DIR/wt-core")${RESET} -> $(tilde "$prefix/wt.sh")"

  first=$(command -v wt-core 2>/dev/null)
  if [[ -n "$first" && "$first" != "$BIN_DIR/wt-core" ]]; then
    note "Another wt-core comes first in your PATH: $first"
  fi
  say ""
}

# --- Shell setup --------------------------------------------------------------

append_lines() {
  local file="$1" line
  shift
  {
    echo ""
    for line in "$@"; do echo "$line"; done
  } >> "$file"
}

# Older installers wrote a bash-only line to ~/.profile, which makes /bin/sh
# (dash) abort while reading the file. Rewrite it in place (keeps symlinks).
repair_profile() {
  local profile="$HOME/.profile" tmp
  [[ -f "$profile" ]] || return 0
  grep -qxF "$OLD_PROFILE_LINE" "$profile" 2>/dev/null || return 0
  tmp="$TMP_DIR/profile"
  awk -v old="$OLD_PROFILE_LINE" -v new="$POSIX_PROFILE_LINE" \
    '$0 == old { print new; next } { print }' "$profile" > "$tmp" || return 0
  cat "$tmp" > "$profile" && info "Fixed the wt line in ${CYAN}~/.profile${RESET} (it broke /bin/sh)"
}

setup_shell() {
  local shell_name rc_file="" path_needed=0
  shell_name=$(basename "${SHELL:-}")
  case "$shell_name" in
    zsh)  rc_file="${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) rc_file="$HOME/.bashrc" ;;
  esac

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) path_needed=1 ;;
  esac

  repair_profile

  if [[ -z "$rc_file" ]]; then
    warn "Shell '${shell_name:-unknown}' is not supported by the wt shell function (zsh and bash only)."
    say "     Nothing was written to your shell config. To use wt from zsh or bash, add to ~/.zshrc or ~/.bashrc:"
    say ""
    if [[ $path_needed -eq 1 ]]; then
      say "       export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
    say "       $INIT_LINE"
    say ""
    return 0
  fi

  if [[ $path_needed -eq 1 ]]; then
    if grep -qF ".local/bin" "$rc_file" 2>/dev/null; then
      note "$(tilde "$BIN_DIR") is not in this PATH, but $(tilde "$rc_file") already mentions it"
    else
      append_lines "$rc_file" "# worktigre - PATH" 'export PATH="$HOME/.local/bin:$PATH"'
      info "Added ${CYAN}$(tilde "$BIN_DIR")${RESET} to PATH in ${CYAN}$(tilde "$rc_file")${RESET}"
    fi
  fi

  if grep -qF "wt-core --shell-init" "$rc_file" 2>/dev/null; then
    info "Shell init already configured in ${CYAN}$(tilde "$rc_file")${RESET}"
  else
    append_lines "$rc_file" "# worktigre - Git Worktree Manager" "$INIT_LINE"
    info "Added shell init to ${CYAN}$(tilde "$rc_file")${RESET}"
  fi

  if [[ "$shell_name" == "bash" && "$(uname -s)" == "Darwin" && -f "$HOME/.bash_profile" ]] \
    && ! grep -qF ".bashrc" "$HOME/.bash_profile" 2>/dev/null; then
    note "macOS login shells read ~/.bash_profile: make sure it sources ~/.bashrc"
  fi
  RC_FILE="$rc_file"
}

# --- Main ---------------------------------------------------------------------

# Everything runs from main, so a truncated download never runs half a script
main() {
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM

  say ""
  say "${BOLD}worktigre${RESET} - Git Worktree Manager"
  say "─────────────────────────"
  say ""

  check_dependencies
  install_worktigre
  setup_shell

  say "─────────────────────────"
  if [[ -n "$MISSING_DEPS" ]]; then
    warn "worktigre is installed, but these required tools are missing: ${BOLD}${MISSING_DEPS}${RESET}"
    say "     Install them (see above), then run: ${CYAN}wt${RESET}"
    say ""
    exit 1
  fi

  say "${GREEN}${BOLD}Installation complete!${RESET}"
  say ""
  if [[ -n "$RC_FILE" ]]; then
    say "To activate now:"
    say ""
    say "  ${CYAN}source $(tilde "$RC_FILE")${RESET}"
    say ""
  fi
  say "To update later:"
  say ""
  say "  ${CYAN}wt --update${RESET}"
  say ""
}

main "$@"
