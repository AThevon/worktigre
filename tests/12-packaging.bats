#!/usr/bin/env bats
# Packaging: launch through symlinks, generated shell functions, install.sh,
# install-linux.sh, zsh completion, Nix metadata.

load 'test_helper/common'

setup() {
  isolate_home
  unset WT_PLATFORM WT_INSTALL_REF WT_INSTALL_TARBALL WT_INSTALL_PREFIX _WT_PLATFORM _WT_DEFAULT_BRANCH
  REPO="$(make_git_repo "$BATS_TEST_TMPDIR/repo")"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# --- Launch through symlinks ----------------------------------------------------

@test "wt-core as an absolute symlink to wt.sh finds lib/" {
  ln -s "$WT_ROOT/wt.sh" "$BATS_TEST_TMPDIR/bin/wt-core"
  cd "$REPO"
  run "$BATS_TEST_TMPDIR/bin/wt-core" --get-pr-term
  assert_success
  assert_output "PR"
}

@test "wt-core as a relative symlink chain finds lib/" {
  mkdir -p "$BATS_TEST_TMPDIR/opt"
  ln -s "$WT_ROOT/wt.sh" "$BATS_TEST_TMPDIR/opt/wt.sh"
  (cd "$BATS_TEST_TMPDIR/bin" && ln -s ../opt/wt.sh wt-core)
  cd "$REPO"
  run "$BATS_TEST_TMPDIR/bin/wt-core" .
  assert_success
  assert_output "$(cd "$REPO" && pwd -P)"
}

@test "Homebrew layout: bin/wt-core link into the Cellar finds lib/worktigre" {
  local cellar="$BATS_TEST_TMPDIR/brew/Cellar/worktigre/9.9.9"
  mkdir -p "$cellar/bin" "$cellar/lib/worktigre" "$BATS_TEST_TMPDIR/brew/bin"
  cp "$WT_ROOT/wt.sh" "$cellar/bin/wt-core"
  cp "$WT_ROOT"/lib/*.sh "$cellar/lib/worktigre/"
  (cd "$BATS_TEST_TMPDIR/brew/bin" && ln -s ../Cellar/worktigre/9.9.9/bin/wt-core wt-core)
  cd "$REPO"
  run "$BATS_TEST_TMPDIR/brew/bin/wt-core" --get-pr-term
  assert_success
  assert_output "PR"
}

@test "wt.sh copied alone (no lib/) fails with a reinstall hint" {
  cp "$WT_ROOT/wt.sh" "$BATS_TEST_TMPDIR/bin/wt-core"
  cd "$REPO"
  run "$BATS_TEST_TMPDIR/bin/wt-core" --get-pr-term
  assert_failure
  assert_output --partial "install.sh"
  refute_output --partial "command not found"
}

# --- Generated shell functions --------------------------------------------------

@test "--shell-init output is valid bash and defines wt" {
  run bash "$WT_ROOT/wt.sh" --shell-init
  assert_success
  bash -n <<<"$output"
  run bash -c 'eval "$(bash "$1" --shell-init)" && type -t wt' _ "$WT_ROOT/wt.sh"
  assert_success
  assert_output --partial "function"
}

@test "--shell-init output is valid zsh and defines wt" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run bash "$WT_ROOT/wt.sh" --shell-init
  assert_success
  zsh -n <<<"$output"
  run zsh -f -c 'eval "$(bash "$1" --shell-init)" && whence -w wt' _ "$WT_ROOT/wt.sh"
  assert_success
  assert_output "wt: function"
}

@test "--dev output is valid bash and zsh" {
  cd "$WT_ROOT"
  run bash "$WT_ROOT/wt.sh" --dev
  assert_success
  bash -n <<<"$output"
  if command -v zsh >/dev/null 2>&1; then
    zsh -n <<<"$output"
  fi
}

# --- install.sh -----------------------------------------------------------------

# Builds a GitHub-like source tarball (one top-level directory) from the
# working tree, optionally with a replacement wt.sh
make_tarball() {
  local out="$1" wt_sh="${2:-$WT_ROOT/wt.sh}"
  local src="$BATS_TEST_TMPDIR/tarball-src"
  rm -rf "$src"
  mkdir -p "$src/worktigre-test/assets"
  cp "$wt_sh" "$src/worktigre-test/wt.sh"
  cp -R "$WT_ROOT/lib" "$WT_ROOT/completions" "$src/worktigre-test/"
  cp "$WT_ROOT"/assets/logo*.ansi "$src/worktigre-test/assets/"
  cp "$WT_ROOT/LICENSE" "$src/worktigre-test/"
  tar -czf "$out" -C "$src" worktigre-test
}

# Runs install.sh from the working tree with a local tarball. fzf, gum and jq
# are stubbed so no package manager is ever called.
run_install() {
  stub_command fzf
  stub_command gum
  stub_command jq
  run env WT_INSTALL_TARBALL="${TARBALL:-$BATS_TEST_TMPDIR/wt.tar.gz}" bash "$WT_ROOT/install.sh"
}

install_setup() {
  TARBALL="$BATS_TEST_TMPDIR/wt.tar.gz"
  make_tarball "$TARBALL"
  PREFIX="$HOME/.local/share/worktigre"
  LINK="$HOME/.local/bin/wt-core"
}

@test "install.sh: installs the release layout and links wt-core" {
  install_setup
  SHELL=/bin/zsh run_install
  assert_success
  assert_output --partial "Installation complete!"

  [[ -f "$PREFIX/wt.sh" && -x "$PREFIX/wt.sh" ]]
  [[ -f "$PREFIX/lib/core.sh" && -f "$PREFIX/lib/menus.sh" ]]
  [[ -f "$PREFIX/assets/logo.ansi" ]]
  [[ -f "$PREFIX/completions/wt.zsh" ]]
  [[ -L "$LINK" ]]
  assert_equal "$(readlink "$LINK")" "$PREFIX/wt.sh"

  run "$LINK" --version
  assert_success
  assert_output --partial "wt $(grep -m1 '^VERSION=' "$WT_ROOT/wt.sh" | cut -d'"' -f2)"

  cd "$REPO"
  run "$LINK" .
  assert_success
  assert_output "$(cd "$REPO" && pwd -P)"
}

@test "install.sh: zsh gets PATH and init lines in .zshrc, written once" {
  install_setup
  SHELL=/bin/zsh run_install
  assert_success
  SHELL=/bin/zsh run_install
  assert_success
  assert_output --partial "already configured"

  run grep -c 'command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"' "$HOME/.zshrc"
  assert_output "1"
  run grep -c 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zshrc"
  assert_output "1"
  [[ ! -e "$HOME/.bashrc" && ! -e "$HOME/.profile" ]]
  # No staging or backup directory left behind
  run ls -A "$HOME/.local/share"
  assert_output "worktigre"
}

@test "install.sh: bash gets .bashrc, no PATH line when ~/.local/bin is in PATH" {
  install_setup
  mkdir -p "$HOME/.local/bin"
  PATH="$HOME/.local/bin:$PATH" SHELL=/bin/bash run_install
  assert_success
  run grep -c 'wt-core --shell-init' "$HOME/.bashrc"
  assert_output "1"
  run grep -c '.local/bin' "$HOME/.bashrc"
  assert_output "0"
  [[ ! -e "$HOME/.zshrc" ]]
}

@test "install.sh: other shells get instructions and no rc file" {
  install_setup
  SHELL=/usr/bin/fish run_install
  assert_success
  assert_output --partial "not supported"
  assert_output --partial 'command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"'
  [[ ! -e "$HOME/.profile" && ! -e "$HOME/.bashrc" && ! -e "$HOME/.zshrc" ]]
  [[ -L "$LINK" ]]
}

@test "install.sh: the generated rc line works when sourced by zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  install_setup
  SHELL=/bin/zsh run_install
  assert_success
  cd "$REPO"
  mkdir -p "$REPO/sub"
  cd "$REPO/sub"
  run zsh -f -c 'source "$HOME/.zshrc"; whence -w wt; wt . >/dev/null; pwd -P'
  assert_success
  assert_line "wt: function"
  assert_line "$(cd "$REPO" && pwd -P)"
}

@test "install.sh: replaces an old single-file wt-core" {
  install_setup
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/bash\necho old\n' > "$LINK"
  chmod +x "$LINK"
  SHELL=/bin/zsh run_install
  assert_success
  [[ -L "$LINK" ]]
  assert_equal "$(readlink "$LINK")" "$PREFIX/wt.sh"
}

@test "install.sh: reinstall swaps the whole directory (stale files removed)" {
  install_setup
  SHELL=/bin/zsh run_install
  assert_success
  touch "$PREFIX/lib/stale.sh"
  SHELL=/bin/zsh run_install
  assert_success
  [[ ! -e "$PREFIX/lib/stale.sh" ]]
  [[ -f "$PREFIX/lib/core.sh" ]]
}

@test "install.sh: refuses a prefix that is not a worktigre install" {
  install_setup
  mkdir -p "$BATS_TEST_TMPDIR/precious"
  echo keep > "$BATS_TEST_TMPDIR/precious/notes.txt"
  WT_INSTALL_PREFIX="$BATS_TEST_TMPDIR/precious" SHELL=/bin/zsh run_install
  assert_failure
  assert_output --partial "not a worktigre install"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/precious/notes.txt")" "keep"
  [[ ! -e "$LINK" ]]
}

@test "install.sh: a broken tarball leaves the current install untouched" {
  install_setup
  SHELL=/bin/zsh run_install
  assert_success
  local before
  before="$(cat "$PREFIX/wt.sh")"

  mkdir -p "$BATS_TEST_TMPDIR/bad/worktigre-bad"
  echo 'VERSION="0.0.0"' > "$BATS_TEST_TMPDIR/bad/worktigre-bad/wt.sh"
  tar -czf "$BATS_TEST_TMPDIR/bad.tar.gz" -C "$BATS_TEST_TMPDIR/bad" worktigre-bad
  TARBALL="$BATS_TEST_TMPDIR/bad.tar.gz" SHELL=/bin/zsh run_install
  assert_failure
  assert_equal "$(cat "$PREFIX/wt.sh")" "$before"
  assert_equal "$(readlink "$LINK")" "$PREFIX/wt.sh"
}

@test "install.sh: a release without symlink support gets an exec wrapper" {
  install_setup
  # Mimics 2.2.0 and older: lib/ is looked up next to BASH_SOURCE, unresolved
  cat > "$BATS_TEST_TMPDIR/legacy-wt.sh" <<'EOF'
#!/bin/bash
VERSION="0.0.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/core.sh" || exit 1
[[ "$1" == "--get-pr-term" ]] && echo PR
EOF
  make_tarball "$TARBALL" "$BATS_TEST_TMPDIR/legacy-wt.sh"
  SHELL=/bin/zsh run_install
  assert_success
  [[ -f "$LINK" && ! -L "$LINK" ]]
  cd "$REPO"
  run "$LINK" --get-pr-term
  assert_success
  assert_output "PR"
}

@test "install.sh: rewrites the old bash-only ~/.profile line so /bin/sh survives" {
  install_setup
  printf '%s\n' 'export BEFORE=1' 'command -v wt-core &>/dev/null && eval "$(wt-core --shell-init)"' 'echo profile-end' > "$HOME/.profile"
  SHELL=/usr/bin/fish run_install
  assert_success
  run grep -c '&>' "$HOME/.profile"
  assert_output "0"
  # dash (Debian/Ubuntu /bin/sh) when available, it rejects `&>`
  local posix_sh=sh
  command -v dash >/dev/null 2>&1 && posix_sh=dash
  run "$posix_sh" -c '. "$HOME/.profile"'
  assert_success
  assert_output "profile-end"
}

@test "install.sh: gum missing on apt prints the Charm repository, not brew" {
  PATH="/usr/bin:/bin" command -v tar >/dev/null 2>&1 || skip "no base tools in /usr/bin:/bin"
  if PATH="/usr/bin:/bin" command -v gum >/dev/null 2>&1; then
    skip "gum is installed in /usr/bin"
  fi
  install_setup
  stub_command uname 'echo Linux'
  stub_command sudo '"$@"'
  stub_command apt-get 'exit 0'
  stub_command apt-cache '[ "$2" != gum ]'
  stub_command fzf
  stub_command jq
  run env PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin" SHELL=/bin/zsh \
    WT_INSTALL_TARBALL="$TARBALL" bash "$WT_ROOT/install.sh"
  assert_failure
  assert_output --partial "repo.charm.sh/apt"
  refute_output --partial "brew install gum"
  assert_output --partial "required tools are missing: gum"
  # worktigre itself is still installed
  [[ -e "$LINK" && -f "$PREFIX/wt.sh" ]]
}

# --- install-linux.sh -----------------------------------------------------------

@test "install-linux.sh piped into bash never runs a local install.sh" {
  mkdir -p "$BATS_TEST_TMPDIR/otherproj"
  printf '#!/bin/bash\necho LOCAL-INSTALLER\n' > "$BATS_TEST_TMPDIR/otherproj/install.sh"
  chmod +x "$BATS_TEST_TMPDIR/otherproj/install.sh"
  stub_command curl 'echo "echo REMOTE-INSTALLER"'
  cd "$BATS_TEST_TMPDIR/otherproj"
  run bash < "$WT_ROOT/install-linux.sh"
  assert_success
  assert_output --partial "REMOTE-INSTALLER"
  refute_output --partial "LOCAL-INSTALLER"
}

# --- zsh completion -------------------------------------------------------------

@test "completion: completions/wt.zsh is a #compdef file for wt and wt-core" {
  run head -n 1 "$WT_ROOT/completions/wt.zsh"
  assert_output "#compdef wt wt-core"
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  zsh -n "$WT_ROOT/completions/wt.zsh"
}

@test "completion: compinit registers _wt from fpath, sourcing registers it too" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  mkdir -p "$BATS_TEST_TMPDIR/fpath"
  cp "$WT_ROOT/completions/wt.zsh" "$BATS_TEST_TMPDIR/fpath/_wt"
  run zsh -f -c 'fpath=("$1" $fpath); autoload -Uz compinit; compinit -u -D; print -r -- "${_comps[wt]} ${_comps[wt-core]}"' _ "$BATS_TEST_TMPDIR/fpath"
  assert_success
  assert_output "_wt _wt"
  run zsh -f -c 'autoload -Uz compinit; compinit -u -D; source "$1"; print -r -- "${_comps[wt]} ${_comps[wt-core]}"' _ "$WT_ROOT/completions/wt.zsh"
  assert_success
  assert_output "_wt _wt"
}

# Real completion in an interactive zsh driven through zsh/zpty: the matches
# compadd really adds are written to a file
write_capture_script() {
  cat > "$BATS_TEST_TMPDIR/capture.zsh" <<'EOF'
zmodload zsh/zpty || exit 3
fpdir=$1 dir=$2 out=$3 cmdline=$4
local buf
: >| $out
zpty z zsh -f -i
zpty -w z "PS1='> '"
zpty -w z "fpath=(${(q)fpdir} \$fpath); autoload -Uz compinit; compinit -u -D; cd ${(q)dir}"
zpty -w z "compadd() { if [[ \${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then builtin compadd \"\$@\"; return; fi; local -a __h; builtin compadd -A __h \"\$@\"; (( \$#__h )) && print -rl -- \"\${__h[@]}\" >> ${(q)out}; builtin compadd \"\$@\"; }"
zpty -w z "_cap_done() { print -r -- __DONE__ >> ${(q)out} }; comppostfuncs=(_cap_done); echo SETUP\"\"DONE"
# Non-blocking reads only, so a stuck shell fails the test instead of hanging
local acc=''
integer i
for i in {1..200}; do
  while zpty -rt z buf; do acc+=$buf; done
  [[ $acc == *SETUPDONE* ]] && break
  sleep 0.05
done
[[ $acc == *SETUPDONE* ]] || { zpty -d z; exit 4; }
zpty -w -n z "${cmdline}"$'\t'
for i in {1..200}; do
  # keep draining the terminal: zsh blocks once the pty buffer is full
  while zpty -rt z buf; do :; done
  grep -q __DONE__ $out 2>/dev/null && break
  sleep 0.05
done
zpty -d z
grep -q __DONE__ $out || exit 5
grep -v __DONE__ $out | sort -u >| $out.sorted && mv $out.sorted $out
EOF
}

complete_line() {
  zsh -f "$BATS_TEST_TMPDIR/capture.zsh" "$BATS_TEST_TMPDIR/fpath" "$2" "$BATS_TEST_TMPDIR/matches" "$1" || return
  cat "$BATS_TEST_TMPDIR/matches"
}

completion_setup() {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  zsh -f -c 'zmodload zsh/zpty' 2>/dev/null || skip "zsh/zpty not available"
  mkdir -p "$BATS_TEST_TMPDIR/fpath"
  cp "$WT_ROOT/completions/wt.zsh" "$BATS_TEST_TMPDIR/fpath/_wt"
  write_capture_script
  git -C "$REPO" worktree add -q -b feature/auth "$BATS_TEST_TMPDIR/repo-feature-auth"
  # wt-core must never be started by the completion
  stub_command wt-core 'touch "$WT_CORE_RAN"'
  export WT_CORE_RAN="$BATS_TEST_TMPDIR/wt-core-ran"
}

@test "completion: 'wt --' offers the public flags" {
  completion_setup
  run complete_line 'wt --' "$REPO"
  assert_success
  assert_line "--version"
  assert_line "--help"
  assert_line "--update"
  assert_line "--dev"
  assert_line "--release"
  [[ ! -e "$WT_CORE_RAN" ]]
}

@test "completion: 'wt ' in a repo offers -, . and the worktrees by branch and directory" {
  completion_setup
  run complete_line 'wt ' "$REPO"
  assert_success
  assert_line "-"
  assert_line "."
  assert_line "main"
  assert_line "feature/auth"
  assert_line "repo-feature-auth"
  refute_line "--version"
  [[ ! -e "$WT_CORE_RAN" ]]
}

@test "completion: 'wt fe' completes the branch" {
  completion_setup
  run complete_line 'wt fe' "$REPO"
  assert_success
  assert_output "feature/auth"
}

@test "completion: outside a git repo, no worktree is offered" {
  completion_setup
  mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
  run complete_line 'wt ' "$BATS_TEST_TMPDIR/not-a-repo"
  assert_success
  refute_line "."
  refute_line "main"
  refute_line "feature/auth"
}

# --- Nix ------------------------------------------------------------------------

@test "nix: default.nix reads the version from wt.sh and declares GPL-3.0-or-later" {
  run grep -E '^[[:space:]]*version = "' "$WT_ROOT/default.nix"
  assert_failure
  run grep -F 'licenses.gpl3Plus' "$WT_ROOT/default.nix"
  assert_success
  # builtins.match is anchored: exactly one full line VERSION="x.y.z"
  run grep -cE '^VERSION="[^"]+"$' "$WT_ROOT/wt.sh"
  assert_output "1"
}
