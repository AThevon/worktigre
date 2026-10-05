#!/usr/bin/env bats
# Stash menu (lib/stash.sh): keymap, list parsing, actions (apply, pop, drop,
# rename, partial, worktree, export, show, Claude) and the stdout contract.
# Every test works on a throwaway repo. fzf, gum and claude are stubs: the
# ui_input / ui_confirm / wt_fzf functions answer from queue files.

load 'test_helper/common'

bats_require_minimum_version 1.5.0

setup() {
  unset WT_WORKTREE_DIR WT_CLAUDE_MODE WT_CONFIG_FILE _WT_FZF_FOOTER _WT_STASH_TTY
  load_wt
  # Keep the real wrapper for the fzf compatibility test
  eval "real_wt_fzf() $(declare -f wt_fzf | tail -n +2)"

  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.email t@example.com
  git config --global user.name t
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  export WT_CONFIG_FILE="$TMP/wtconfig"
  export TMPDIR="$TMP/tmpdir"
  mkdir -p "$TMPDIR"

  Q="$TMP/queue"
  mkdir -p "$Q"
  : > "$Q/inputs"
  : > "$Q/confirms"
  echo 0 > "$Q/fzf.n"
  echo 0 > "$Q/inputs.n"
  echo 0 > "$Q/confirms.n"

  STUBS="$TMP/stubs"
  mkdir -p "$STUBS"
  # Never reach a real gum (it would wait for a terminal)
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gum"
  chmod +x "$STUBS/gum"
  export PATH="$STUBS:$PATH"

  REPO="$TMP/myapp"
  git init -q "$REPO"
  printf '1\n2\n3\n' > "$REPO/f"
  echo g > "$REPO/g"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm init
  cd "$REPO" || return 1
  # shellcheck disable=SC2034 # read by lib/git.sh and lib/stash.sh
  MAIN_REPO="$REPO" REPO_NAME="myapp"
  install_stubs
}

# --- stubs -------------------------------------------------------------------

# Installed after load_wt, which (re)defines the real ui_input / wt_fzf
install_stubs() {
  _q_next() {
    local n
    n=$(( $(cat "$Q/$1.n") + 1 ))
    echo "$n" > "$Q/$1.n"
    echo "$n"
  }

  # ui_input answers the next line of $Q/inputs ("ESC" = cancelled)
  ui_input() {
    local line
    line=$(sed -n "$(_q_next inputs)p" "$Q/inputs")
    echo "ui_input[$1]" >> "$Q/log"
    [[ "$line" == "ESC" ]] && return 1
    printf '%s\n' "$line"
  }

  # ui_confirm answers the next line of $Q/confirms ("y" = yes)
  ui_confirm() {
    local line
    line=$(sed -n "$(_q_next confirms)p" "$Q/confirms")
    echo "ui_confirm[$1]" >> "$Q/log"
    [[ "$line" == "y" ]]
  }

  # wt_fzf call N logs its args (one per line, plus a replayable copy), stdin
  # and _WT_STASH_* env, then prints $Q/fzf.N.out or exits 130 (Esc)
  wt_fzf() {
    local n a
    n=$(_q_next fzf)
    printf '%s\n' "$@" > "$Q/fzf.$n.args"
    for a in "$@"; do printf '%q ' "$a"; done > "$Q/fzf.$n.argv"
    cat > "$Q/fzf.$n.in"
    env | grep '^_WT_STASH' > "$Q/fzf.$n.env"
    if [[ -f "$Q/fzf.$n.out" ]]; then
      cat "$Q/fzf.$n.out"
    else
      return 130
    fi
  }
}

fzf_answer() { printf '%s\n' "$2" > "$Q/fzf.$1.out"; }

# Formatted list line of the stash whose message matches $1
stash_line() { _format_stash_list | grep -F -- "$1" | head -1; }

# --- keymap / help -------------------------------------------------------------

@test "keymap: the list expects every shortcut, the sub-menu every stash action" {
  run _stash_keys all
  assert_output "ctrl-a,ctrl-p,ctrl-l,ctrl-w,ctrl-d,ctrl-b,ctrl-x,ctrl-s,ctrl-r,ctrl-n,ctrl-e"
  run _stash_keys stash
  assert_output "ctrl-a,ctrl-p,ctrl-l,ctrl-w,ctrl-d,ctrl-b,ctrl-x,ctrl-s,ctrl-r"
  run _stash_keys global
  assert_output "ctrl-n,ctrl-e"
}

@test "keymap: every key maps to an action that _stash_run handles" {
  local key action body
  body=$(declare -f _stash_run)
  for key in $(_stash_keys all | tr ',' ' '); do
    action=$(_stash_key_action "$key")
    [[ -n "$action" ]]
    [[ "$body" == *"$action)"* ]]
  done
  run _stash_key_action ctrl-r
  assert_output "rename"
  run _stash_key_action ctrl-l
  assert_output "claude"
  run _stash_key_action ctrl-w
  assert_output "worktree"
}

@test "help: lists every shortcut of the keymap and how to hide it" {
  run _stash_help
  assert_success
  local key hint
  while IFS='|' read -r key hint _; do
    assert_output --partial "Ctrl+${hint#^}"
  done <<< "$_STASH_KEYMAP"
  assert_output --partial "Ctrl+L    Apply + resolve conflicts with Claude"
  assert_output --partial "Ctrl+R    Rename stash"
  assert_output --partial "Move the cursor to hide this help"
  refute_output --partial "Press any key"
}

@test "help: the '?' binding never embeds the help text (no parenthesis inside the action)" {
  echo x > f
  git stash push -q -m one
  run menu_stash
  assert_failure
  local bind
  bind=$(grep '^?:preview(' "$Q/fzf.1.args")
  [[ -n "$bind" ]]
  # Only the closing parenthesis of preview(...)
  local inner="${bind#\?:preview(}"
  inner="${inner%)}"
  [[ "$inner" != *")"* && "$inner" != *"("* ]]
  grep -q "^_WT_STASH_HELP=" "$Q/fzf.1.env"
}

# --- list parsing ----------------------------------------------------------------

@test "split_subject: WIP and On subjects, first ': ' only" {
  _stash_split_subject "WIP on main: abc123 init"
  [[ "$_STASH_BRANCH" == "main" && "$_STASH_MSG" == "abc123 init" ]]
  _stash_split_subject "On feat/x: work on login: fix"
  [[ "$_STASH_BRANCH" == "feat/x" && "$_STASH_MSG" == "work on login: fix" ]]
  _stash_split_subject "On main: simple msg"
  [[ "$_STASH_BRANCH" == "main" && "$_STASH_MSG" == "simple msg" ]]
  _stash_split_subject "renamed by hand"
  [[ -z "$_STASH_BRANCH" && "$_STASH_MSG" == "renamed by hand" ]]
}

@test "age: computed from the timestamp" {
  _stash_age 1000 1300
  [[ "$_STASH_AGE" == "5m" ]]
  _stash_age 0 $((3 * 86400))
  [[ "$_STASH_AGE" == "3d" ]]
  _stash_age 2000 1000
  [[ "$_STASH_AGE" == "0m" ]]
  _stash_age "" 1000
  [[ "$_STASH_AGE" == "?" ]]
}

@test "list: branch, message, untracked files counted, sha in the hidden field" {
  echo x > f
  git stash push -q -m "work on login: fix"
  echo only > only-new.txt
  git stash push -q -u -m "untracked only"
  run _format_stash_list
  assert_success
  assert_line --index 0 --regexp '^stash@\{0\} +│ +[0-9]+m │ +1f │ main +│ untracked only'$'\t''[0-9a-f]{40}$'
  assert_line --index 1 --regexp '^stash@\{1\} +│ +[0-9]+m │ +1f │ main +│ work on login: fix'$'\t'
  local sha
  sha=$(git rev-parse 'stash@{0}')
  [[ "${lines[0]##*$'\t'}" == "$sha" ]]
}

@test "preview: untracked files and possible conflicts are shown" {
  printf '1\n2-stash\n3\n' > f
  echo n > "new file.txt"
  git stash push -q -u -m wip
  printf '1\n2-head\n3\n' > f
  git commit -qam moved
  run _stash_preview "$(git rev-parse 'stash@{0}')"
  assert_success
  assert_output --partial "Branch  : main"
  assert_output --partial "Message : wip"
  assert_output --partial "2 files (1 untracked)"
  assert_output --partial "POSSIBLE CONFLICTS"
  assert_output --partial "new file.txt (untracked)"
}

# --- conflict detection ---------------------------------------------------------

@test "conflicts: HEAD moved -> conflict, local change -> blocked, untracked collision -> blocked" {
  printf '1\n2-stash\n3\n' > f
  echo u > u.txt
  git stash push -q -u -m s1
  local sha
  sha=$(git rev-parse 'stash@{0}')

  run _stash_conflicts "$sha"
  assert_output ""

  printf '1\n2-head\n3\n' > f
  git commit -qam moved
  run _stash_conflicts "$sha"
  assert_output "conflict"$'\t'"f"

  printf '1\n2-head\n3-local\n' > f
  run _stash_conflicts "$sha"
  assert_output "blocked"$'\t'"f"

  git checkout -q f
  echo other > u.txt
  run _stash_conflicts "$sha"
  assert_output "blocked"$'\t'"u.txt"$'\n'"conflict"$'\t'"f"
}

@test "sub-menu: the Claude option only shows up when conflicts are likely" {
  printf '1\n2-stash\n3\n' > f
  git stash push -q -m s1
  local sha
  sha=$(git rev-parse 'stash@{0}')

  _stash_action_menu "$sha" || true
  run grep -c "Apply + resolve conflicts with Claude" "$Q/fzf.1.in"
  assert_output "0"

  printf '1\n2-head\n3\n' > f
  git commit -qam moved
  _stash_action_menu "$sha" || true
  run grep -c "Apply + resolve conflicts with Claude" "$Q/fzf.2.in"
  assert_output "1"
  grep -q "Possible conflicts" "$Q/fzf.2.args"

  printf '1\n2-head\n3-local\n' > f
  _stash_action_menu "$sha" || true
  run grep -c "Apply + resolve conflicts with Claude" "$Q/fzf.3.in"
  assert_output "0"
  grep -q "Apply blocked by local changes" "$Q/fzf.3.args"
  # Same keys as the list
  grep -qx -- "--expect=$(_stash_keys stash)" "$Q/fzf.3.args"
}

@test "sub-menu: a shortcut or a selected line returns the action id" {
  echo x > f
  git stash push -q -m s1
  local sha
  sha=$(git rev-parse 'stash@{0}')
  fzf_answer 1 "ctrl-r"
  run _stash_action_menu "$sha"
  assert_output "rename"
  fzf_answer 2 ""$'\n'"worktree"$'\t'"Create worktree from stash"
  run _stash_action_menu "$sha"
  assert_output "worktree"
}

# --- apply / pop -----------------------------------------------------------------

@test "apply: refused up front when local changes would be overwritten" {
  printf '1\n2-stash\n3\n' > f
  echo u > u.txt
  git stash push -q -u -m s1
  printf '1\n2\n3-local\n' > f
  run --separate-stderr _stash_run apply "$(git rev-parse 'stash@{0}')"
  assert_failure
  assert_output ""
  [[ "$stderr" == *"Cannot apply stash@{0}, local changes would be overwritten: f"* ]]
  [[ "$stderr" != *"applied"* ]]
  # Nothing touched: the untracked file of the stash was not restored
  [[ ! -e u.txt ]]
  run git status --short
  assert_output " M f"
}

@test "apply: success keeps stdout empty and reports on stderr" {
  echo x > f
  git stash push -q -m s1
  run --separate-stderr _stash_run apply "$(git rev-parse 'stash@{0}')"
  assert_success
  assert_output ""
  [[ "$stderr" == *"Stash stash@{0} applied"* ]]
  [[ "$(git stash list | wc -l | tr -d ' ')" == "1" ]]
}

@test "pop: conflicts are reported, the stash is kept, stdout stays empty" {
  printf '1\n2-stash\n3\n' > f
  git stash push -q -m s1
  printf '1\n2-head\n3\n' > f
  git commit -qam moved
  run --separate-stderr _stash_run pop "$(git rev-parse 'stash@{0}')"
  assert_equal "$status" 2
  assert_output ""
  [[ "$stderr" == *"CONFLICT"* ]]
  [[ "$stderr" == *"applied with conflicts in: f"* ]]
  [[ "$(git stash list | wc -l | tr -d ' ')" == "1" ]]
}

# --- drop ------------------------------------------------------------------------

@test "drop: multi-selection in any order drops exactly the selected stashes" {
  local x
  for x in A B C D; do echo "$x" > f; git stash push -q -m "stash-$x"; done
  # fzf returns the marked items in marking order: B then D
  fzf_answer 1 "ctrl-d"$'\n'"$(stash_line stash-B)"$'\n'"$(stash_line stash-D)"
  echo y > "$Q/confirms"
  run --separate-stderr menu_stash
  assert_output ""
  [[ "$stderr" == *"2 stash(es) dropped"* ]]
  grep -q "ui_confirm\[Delete 2 stashes?\]" "$Q/log"
  run git stash list --format=%gs
  assert_output "On main: stash-C"$'\n'"On main: stash-A"
}

@test "drop: only successful drops are counted" {
  echo x > f
  git stash push -q -m one
  local sha
  sha=$(git rev-parse 'stash@{0}')
  echo y > "$Q/confirms"
  run --separate-stderr _stash_drop "$sha" 0000000000000000000000000000000000000000
  assert_failure
  [[ "$stderr" == *"1 stash(es) dropped"* ]]
  [[ "$stderr" == *"1 stash(es) could not be dropped"* ]]
}

@test "drop: declining the confirmation keeps the stash" {
  echo x > f
  git stash push -q -m one
  echo n > "$Q/confirms"
  run _stash_run drop "$(git rev-parse 'stash@{0}')"
  assert_success
  [[ "$(git stash list | wc -l | tr -d ' ')" == "1" ]]
}

# --- rename ----------------------------------------------------------------------

@test "rename: keeps the content (untracked included), the WIP and the branch" {
  echo f2 > f
  echo n > newfile.txt
  git stash push -q -u -m orig
  echo f3 > f
  git stash push -q
  echo wip > g
  local sha
  sha=$(git rev-parse 'stash@{1}')
  echo "renamed" > "$Q/inputs"
  run --separate-stderr _stash_run rename "$sha"
  assert_success
  [[ "$stderr" == *"Stash renamed"* ]]
  run git stash list --format=%gs
  assert_line --index 0 "On main: renamed"
  [[ "${#lines[@]}" -eq 2 ]]
  [[ "$(git rev-parse 'stash@{0}')" == "$sha" ]]
  run git stash show --include-untracked --name-only 'stash@{0}'
  assert_output "f"$'\n'"newfile.txt"
  run git status --short
  assert_output " M g"
  [[ "$(git branch --show-current)" == "main" ]]
}

@test "rename: works on stash@{0} too" {
  echo x > f
  git stash push -q -m first
  echo y > f
  git stash push -q -m top
  local sha
  sha=$(git rev-parse 'stash@{0}')
  echo "top renamed" > "$Q/inputs"
  run _stash_run rename "$sha"
  assert_success
  run git stash list --format=%gs
  assert_output "On main: top renamed"$'\n'"On main: first"
  [[ "$(git rev-parse 'stash@{0}')" == "$sha" ]]
}

@test "rename: Esc on the message cancels" {
  echo x > f
  git stash push -q -m keep
  echo ESC > "$Q/inputs"
  run _stash_run rename "$(git rev-parse 'stash@{0}')"
  assert_success
  run git stash list --format=%gs
  assert_output "On main: keep"
}

# --- create ----------------------------------------------------------------------

@test "create: clean tree does not claim a stash was created" {
  echo "" > "$Q/inputs"
  run --separate-stderr _stash_run new
  [[ "$stderr" != *"Stash created"* ]]
  [[ "$stderr" == *"No local changes to save"* ]]
  [[ -z "$(git stash list)" ]]
}

@test "create: Esc on the message cancels, a message is used when given" {
  echo x > f
  echo ESC > "$Q/inputs"
  run _stash_run new
  [[ -z "$(git stash list)" ]]
  [[ -n "$(git status --short)" ]]

  echo 0 > "$Q/inputs.n"
  echo "my msg" > "$Q/inputs"
  echo u > untracked.txt
  run --separate-stderr _stash_run new
  [[ "$stderr" == *"Stash created"* ]]
  run git stash list --format=%gs
  assert_output "On main: my msg"
  [[ -z "$(git status --short)" ]]
}

@test "partial: paths with spaces and quotes, untracked files, run from a sub-directory" {
  mkdir -p src
  echo a > "src/my file.txt"
  git add .
  git commit -qm src
  echo mod > "src/my file.txt"
  echo x > "it's.txt"
  echo y > "src/new doc.md"
  echo z > keep-untracked.txt
  echo w > g
  cd src
  fzf_answer 1 "src/my file.txt"$'\n'"it's.txt"$'\n'"src/new doc.md"
  echo "partial" > "$Q/inputs"
  run --separate-stderr _stash_partial
  assert_success
  assert_output ""
  [[ "$stderr" == *"Partial stash created (3 file(s))"* ]]
  # Candidates are relative to the repository root
  run cat "$Q/fzf.1.in"
  assert_output "g"$'\n'"it's.txt"$'\n'"keep-untracked.txt"$'\n'"src/my file.txt"$'\n'"src/new doc.md"
  run git stash show --include-untracked --name-only 'stash@{0}'
  assert_output "it's.txt"$'\n'"src/my file.txt"$'\n'"src/new doc.md"
  run git -C "$REPO" status --short
  assert_output " M g"$'\n'"?? keep-untracked.txt"
}

@test "partial: preview shows staged-only and untracked files" {
  echo staged > g
  git add g
  echo u > untr.txt
  mkdir -p sub
  cd sub
  _stash_partial || true
  local preview
  preview=$(sed -n '/^--preview=/,/^--preview-window/p' "$Q/fzf.1.args" | sed '1s/^--preview=//;$d')
  run env _WT_STASH_TOP="$REPO" bash -c "${preview//\{\}/g}"
  assert_output --partial "staged"
  run env _WT_STASH_TOP="$REPO" bash -c "${preview//\{\}/untr.txt}"
  assert_output --partial "untr.txt"
}

@test "partial: Esc on the message creates nothing" {
  echo x > f
  fzf_answer 1 "f"
  echo ESC > "$Q/inputs"
  run _stash_partial
  assert_failure
  [[ -z "$(git stash list)" ]]
}

# --- worktree --------------------------------------------------------------------

@test "worktree: named like other creations, at the stash base, .env copied, path alone on stdout" {
  printf '.env\n' > .gitignore
  echo SECRET=1 > .env
  git add .gitignore
  git commit -qm gitignore
  local base
  base=$(git rev-parse HEAD)
  git worktree add -q -b feat-x "$TMP/myapp-feat-x"
  cd "$TMP/myapp-feat-x"
  printf '1\n2-stash\n3\n' > f
  echo n > newf.txt
  git stash push -q -u -m wip
  printf '1\n2-head\n3\n' > f
  git commit -qam "moved on"
  export WT_WORKTREE_DIR="$TMP/wtdir"
  mkdir -p "$WT_WORKTREE_DIR"
  echo "feature/stash-wip" > "$Q/inputs"
  echo y > "$Q/confirms"

  run --separate-stderr _stash_run worktree "$(git rev-parse 'stash@{0}')"
  assert_success
  assert_output "$TMP/wtdir/myapp-feature-stash-wip"
  [[ -f "$output/.env" ]]
  [[ -f "$output/newf.txt" ]]
  [[ "$(git -C "$output" rev-parse HEAD)" == "$base" ]]
  [[ "$(git -C "$output" branch --show-current)" == "feature/stash-wip" ]]
  run git -C "$output" status --short
  assert_output " M f"$'\n'"?? newf.txt"
  [[ -z "$(git stash list)" ]]
}

@test "worktree: menu_stash ^W prints the path only and leaves the menu" {
  echo x > f
  git stash push -q -m wip
  fzf_answer 1 "ctrl-w"$'\n'"$(stash_line wip)"
  echo "wip-one" > "$Q/inputs"
  echo n > "$Q/confirms"
  run --separate-stderr menu_stash
  assert_success
  assert_output "$TMP/myapp-wip-one"
  [[ -d "$TMP/myapp-wip-one" ]]
  [[ "$(git stash list | wc -l | tr -d ' ')" == "1" ]]
}

@test "worktree: Esc on the name cancels" {
  echo x > f
  git stash push -q -m wip
  echo ESC > "$Q/inputs"
  run _stash_run worktree "$(git rev-parse 'stash@{0}')"
  assert_success
  assert_output ""
  [[ "$(git worktree list | wc -l | tr -d ' ')" == "1" ]]
}

# --- export / show ---------------------------------------------------------------

@test "export: outside the working tree, absolute path, untracked and binary files included" {
  printf 'a\0b' > img.bin
  git add img.bin
  git commit -qm bin
  git config diff.noprefix true
  echo f2 > f
  printf 'a\0c' > img.bin
  echo new > newfile.txt
  git stash push -q -u -m exp
  mkdir -p "$HOME/Downloads"
  run --separate-stderr _stash_run export "$(git rev-parse 'stash@{0}')"
  assert_success
  assert_output ""
  local file
  file=$(ls "$HOME"/Downloads/myapp-stash-*.patch)
  [[ "$stderr" == *"Exported stash@{0} to $file"* ]]
  grep -q "GIT binary patch" "$file"
  grep -q "^diff --git a/newfile.txt b/newfile.txt" "$file"
  [[ -z "$(git status --short)" ]]
  # The patch restores everything on a clone at the stash base
  git clone -q "$REPO" "$TMP/clone"
  git -C "$TMP/clone" apply "$file"
  [[ -f "$TMP/clone/newfile.txt" ]]
  cmp -s "$TMP/clone/img.bin" <(printf 'a\0c')
}

@test "export: falls back to TMPDIR and reports a failure" {
  echo x > f
  git stash push -q -m exp
  run --separate-stderr _stash_run export "$(git rev-parse 'stash@{0}')"
  assert_success
  [[ "$stderr" == *"Exported stash@{0} to $TMPDIR/myapp-stash-"* ]]

  [[ "$(id -u)" -ne 0 ]] || skip "root can write anywhere"
  export TMPDIR="$TMP/readonly"
  mkdir -p "$TMPDIR"
  chmod 555 "$TMPDIR"
  run --separate-stderr _stash_run export "$(git rev-parse 'stash@{0}')"
  chmod 755 "$TMPDIR"
  assert_failure
  [[ "$stderr" == *"Export failed"* ]]
  [[ "$stderr" != *"Exported"* ]]
}

@test "show: the full diff goes to the terminal through less, stdout stays empty" {
  printf '#!/usr/bin/env bash\necho "less $*"\ncat\n' > "$STUBS/less"
  chmod +x "$STUBS/less"
  echo f2 > f
  echo new > newfile.txt
  git stash push -q -u -m s1
  export _WT_STASH_TTY="$TMP/tty"
  run _stash_run show "$(git rev-parse 'stash@{0}')"
  assert_success
  assert_output ""
  grep -q "^less -R" "$TMP/tty"
  grep -q "newfile.txt" "$TMP/tty"
  grep -q "f2" "$TMP/tty"
}

# --- Claude ----------------------------------------------------------------------

@test "claude: launched on the terminal from the repo root with the mode flags" {
  cat > "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "cwd=$PWD"; printf 'arg=%s\n' "$@"; } >> "$CLAUDE_LOG"
echo "CLAUDE OUTPUT"
EOF
  chmod +x "$STUBS/claude"
  export CLAUDE_LOG="$TMP/claude.log"
  printf '1\n2-stash\n3\n' > f
  git stash push -q -m s1
  printf '1\n2-head\n3\n' > f
  git commit -qam moved
  mkdir -p deep
  cd deep
  : > "$TMP/tty"
  export _WT_STASH_TTY="$TMP/tty" WT_CLAUDE_MODE=plan
  run --separate-stderr _stash_run claude "$(git rev-parse 'stash@{0}')"
  assert_output ""
  grep -qx "cwd=$REPO" "$CLAUDE_LOG"
  grep -qx "arg=--permission-mode=plan" "$CLAUDE_LOG"
  grep -q "^arg=Resolve the merge conflicts in these files: f\." "$CLAUDE_LOG"
  grep -q "CLAUDE OUTPUT" "$TMP/tty"

  : > "$CLAUDE_LOG"
  git reset -q --hard
  export WT_CLAUDE_MODE=forced
  run _stash_run claude "$(git rev-parse 'stash@{0}')"
  grep -qx "arg=--dangerously-skip-permissions" "$CLAUDE_LOG"
}

@test "claude: not launched when the stash applies cleanly" {
  printf '#!/usr/bin/env bash\necho called >> "%s"\n' "$TMP/claude.called" > "$STUBS/claude"
  chmod +x "$STUBS/claude"
  echo x > f
  git stash push -q -m s1
  export WT_CLAUDE_MODE=forced _WT_STASH_TTY="$TMP/tty"
  run --separate-stderr _stash_run claude "$(git rev-parse 'stash@{0}')"
  assert_success
  [[ "$stderr" == *"No conflicts"* ]]
  [[ ! -e "$TMP/claude.called" ]]
}

# --- menu / stdout contract -------------------------------------------------------

@test "menu: Esc returns 1 with an empty stdout; the empty menu offers ^N/^E" {
  run menu_stash
  assert_failure
  assert_output ""
  grep -qx -- "--expect=ctrl-n,ctrl-e" "$Q/fzf.1.args"
  grep -qx -- "--footer=^N new · ^E partial" "$Q/fzf.1.args"
}

@test "menu: Enter opens the sub-menu for the stash and runs the chosen action" {
  echo x > f
  git stash push -q -m one
  fzf_answer 1 ""$'\n'"$(stash_line one)"
  fzf_answer 2 ""$'\n'"apply"$'\t'"Apply (keep stash)"
  run --separate-stderr menu_stash
  assert_output ""
  [[ "$stderr" == *"Stash stash@{0} applied"* ]]
  [[ "$(cat f)" == "x" ]]
  grep -q "^_WT_STASH_SHA=$(git rev-parse 'stash@{0}')$" "$Q/fzf.2.env"
}

@test "fzf: every stash menu opens with the installed fzf (options parse)" {
  command -v fzf >/dev/null 2>&1 || skip "fzf not installed"
  echo x > f
  echo u > u.txt
  fzf_answer 1 "ctrl-e"
  menu_stash >/dev/null 2>&1 || true
  git stash push -q -u -m one
  fzf_answer 4 ""$'\n'"$(stash_line one)"
  menu_stash >/dev/null 2>&1 || true
  local n rc
  for n in 1 2 3 4 5; do
    [[ -f "$Q/fzf.$n.argv" ]]
    eval "set -- $(cat "$Q/fzf.$n.argv")"
    rc=0
    unset _WT_FZF_FOOTER
    real_wt_fzf "$@" --filter=zz </dev/null >/dev/null 2>"$TMP/fzf.err" || rc=$?
    [[ $rc -ne 2 ]] || { cat "$TMP/fzf.err"; false; }
  done
}
