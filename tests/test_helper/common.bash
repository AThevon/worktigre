# Usage in .bats files: load 'test_helper/common'
load "${BATS_TEST_DIRNAME}/test_helper/bats-support/load"
load "${BATS_TEST_DIRNAME}/test_helper/bats-assert/load"

# Absolute path of the repository root (wt.sh, lib/, completions/...)
# shellcheck disable=SC2034
WT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

# Source individual modules with all functions available, entry point skipped.
# NOTE: Must be called from a git repository context (the project root).
load_wt() {
  # Reset cached platform and default branch to avoid state leakage between tests
  _WT_PLATFORM=""
  _WT_DEFAULT_BRANCH=""
  VERSION="test"
  local wt_root="${BATS_TEST_DIRNAME}/.."
  # shellcheck disable=SC1091
  source "$wt_root/lib/core.sh"
  # shellcheck disable=SC1091
  source "$wt_root/lib/ui.sh"
  # shellcheck disable=SC1091
  source "$wt_root/lib/git.sh"
  # shellcheck disable=SC1091
  source "$wt_root/lib/cli.sh"
  # shellcheck disable=SC1091
  source "$wt_root/lib/prompts.sh"
  # shellcheck disable=SC1091
  source "$wt_root/lib/menus.sh"
  # shellcheck disable=SC1091
  source "$wt_root/lib/stash.sh"
}

# Set WT_CONFIG_FILE to a fresh temp file for test isolation
setup_config() {
  export WT_CONFIG_FILE
  WT_CONFIG_FILE="$(mktemp)"
}

# Clean up temp config file
teardown_config() {
  rm -f "${WT_CONFIG_FILE:-}"
}

# Create a minimal fake git repo with a given remote URL, print its path
make_fake_repo() {
  local remote_url="$1"
  local tmpdir
  tmpdir="$(mktemp -d)"
  git init "$tmpdir" -q
  git -C "$tmpdir" remote add origin "$remote_url"
  echo "$tmpdir"
}

# Point HOME, the git global config and the wt config at a fresh directory
# under $BATS_TEST_TMPDIR, so a test never reads or writes the real ones
isolate_home() {
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"
  export WT_CONFIG_FILE="$HOME/.config/wt/config"
  unset XDG_CONFIG_HOME ZDOTDIR
}

# Create a git repo with one commit on `main` at the given path, print it
make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m init
  echo "$dir"
}

# stub_command <name> [script body]: put a fake <name> first in PATH.
# The default body exits 0 without output.
stub_command() {
  local name="$1" body="${2:-exit 0}"
  local dir="${BATS_TEST_TMPDIR}/stubs"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/$name"
  chmod +x "$dir/$name"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) export PATH="$dir:$PATH" ;;
  esac
}
