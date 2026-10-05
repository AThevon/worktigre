#!/usr/bin/env bats
# Worktree operations (lib/git.sh): listing, status icons, preview, creation
# from a branch / new branch / issue / PR (same repo and forks), .env copy.
# Every test works on throwaway repos: a bare "remote", a seed clone that
# pushes to it, and the user's clone ($TMP/proj). fzf and gum are stubs.

load 'test_helper/common'

bats_require_minimum_version 1.5.0

setup() {
  unset WT_WORKTREE_DIR WT_FEATURE_PREFIX WT_AUTO_FETCH WT_PLATFORM WT_CONFIG_FILE
  unset _WT_PLATFORM _WT_DEFAULT_BRANCH _WT_MERGE_TARGET _WT_FZF_FOOTER _WT_CACHE_REPO
  load_wt
  _WT_PLATFORM="github"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.email t@example.com
  git config --global user.name t
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  export WT_CONFIG_FILE="$TMP/wtconfig"

  STUBS="$TMP/stubs"
  mkdir -p "$STUBS"
  # fzf: prints the first stdin line matching $FZF_PICK (ERE), or exits $FZF_RC.
  # Arguments and stdin are logged to $FZF_LOG.
  export FZF_LOG="$TMP/fzf.log"
  cat > "$STUBS/fzf" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == --filter* ]] && exit 0; done
input=$(cat)
{ printf 'ARGS:'; printf ' %s' "$@"; printf '\n%s\n--\n' "$input"; } >> "$FZF_LOG"
[[ -n "${FZF_RC:-}" ]] && exit "$FZF_RC"
line=$(printf '%s\n' "$input" | grep -E -m1 -- "${FZF_PICK:-^}") || exit 1
printf '%s\n' "$line"
EOF
  # gum: input answers $GUM_INPUT (or exits $GUM_INPUT_RC), the rest goes to stderr
  cat > "$STUBS/gum" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  input) [[ -n "${GUM_INPUT_RC:-}" ]] && exit "$GUM_INPUT_RC"; printf '%s\n' "${GUM_INPUT:-}" ;;
  confirm) exit "${GUM_CONFIRM_RC:-0}" ;;
  *) shift; printf '%s\n' "$*" >&2 ;;
esac
EOF
  # gh: unavailable for checkouts unless a test replaces it
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
  chmod +x "$STUBS/fzf" "$STUBS/gum" "$STUBS/gh"
  export PATH="$STUBS:$PATH"
}

# remote.git (bare) + seed (pushes to it) + proj (the user's clone, cwd)
make_fixture() {
  git init -q --bare "$TMP/remote.git"
  git clone -q "$TMP/remote.git" "$TMP/seed" 2>/dev/null
  printf '.env\n.env.local\n' > "$TMP/seed/.gitignore"
  echo a > "$TMP/seed/a.txt"
  git -C "$TMP/seed" add -A
  git -C "$TMP/seed" commit -qm init
  git -C "$TMP/seed" push -q origin main
  git clone -q "$TMP/remote.git" "$TMP/proj"
  MAIN_REPO="$TMP/proj"
  REPO_NAME="proj"
  cd "$MAIN_REPO" || return 1
}

# seed_commit <branch> <file> [<base>]: commit on <branch> in the seed and push
seed_commit() {
  local branch="$1" file="$2" base="${3:-main}"
  if git -C "$TMP/seed" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$TMP/seed" checkout -q "$branch"
  else
    git -C "$TMP/seed" checkout -q -b "$branch" "$base"
  fi
  echo "$file" >> "$TMP/seed/$file"
  git -C "$TMP/seed" add -A
  git -C "$TMP/seed" commit -qm "$branch: $file"
  git -C "$TMP/seed" push -q origin "$branch"
  git -C "$TMP/seed" checkout -q main
}

# seed_pr_ref <ref> <file>: a commit on top of main, pushed only as <ref>
# (refs/pull/N/head, refs/merge-requests/N/head), like a fork PR
seed_pr_ref() {
  git -C "$TMP/seed" checkout -q --detach main
  echo "$2" > "$TMP/seed/$2"
  git -C "$TMP/seed" add -A
  git -C "$TMP/seed" commit -qm "fork: $2"
  git -C "$TMP/seed" push -q origin "HEAD:$1"
  git -C "$TMP/seed" checkout -q main
}

# Plain text line of the worktree list for <path> (colors off in tests)
line_for() {
  format_all_worktrees | grep -F "$(printf '\t')$1"
}

# =============================================================================
# Listing
# =============================================================================

@test "get_worktrees: main first, secondary list excludes it" {
  make_fixture
  git worktree add -q "$TMP/proj-b" -b b
  run get_worktrees
  assert_success
  assert_line --index 0 "$TMP/proj"
  assert_line --index 1 "$TMP/proj-b"
  run get_secondary_worktrees
  assert_output "$TMP/proj-b"
}

@test "get_worktrees: a missing worktree is hidden but never pruned" {
  make_fixture
  git worktree add -q "$TMP/proj-b" -b b
  mv "$TMP/proj-b" "$TMP/unmounted"
  run get_worktrees
  assert_output "$TMP/proj"
  # metadata kept: the worktree works again once its folder is back
  mv "$TMP/unmounted" "$TMP/proj-b"
  run git -C "$TMP/proj-b" branch --show-current
  assert_success
  assert_output "b"
}

@test "get_worktrees: bare entry skipped in a bare + worktrees layout" {
  make_fixture
  git clone -q --bare "$TMP/remote.git" "$TMP/bp/.bare"
  echo "gitdir: ./.bare" > "$TMP/bp/.git"
  git -C "$TMP/bp" worktree add -q "$TMP/bp/main" main
  git -C "$TMP/bp" worktree add -q -b feat "$TMP/bp/feat" main
  cd "$TMP/bp/feat"
  MAIN_REPO="$TMP/bp/main"
  run get_worktrees
  assert_line --index 0 "$TMP/bp/main"
  refute_output --partial ".bare"
  run get_secondary_worktrees
  assert_output "$TMP/bp/feat"
}

# =============================================================================
# Default branch
# =============================================================================

@test "get_default_branch: origin/HEAD" {
  make_fixture
  git remote set-head origin main >/dev/null
  run get_default_branch
  assert_output "main"
}

@test "get_default_branch: master repo without origin/HEAD" {
  git init -q --bare "$TMP/r.git"
  git init -q -b master "$TMP/m"
  git -C "$TMP/m" commit -q --allow-empty -m i
  git -C "$TMP/m" remote add origin "$TMP/r.git"
  git -C "$TMP/m" push -q -u origin master
  git -C "$TMP/m" update-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
  MAIN_REPO="$TMP/m"
  run get_default_branch
  assert_output "master"
}

@test "get_default_branch: dangling origin/HEAD falls back on an existing branch" {
  make_fixture
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
  run get_default_branch
  assert_output "main"
}

@test "get_default_branch: local master without any remote, then the cache wins" {
  git init -q -b master "$TMP/l"
  git -C "$TMP/l" commit -q --allow-empty -m i
  MAIN_REPO="$TMP/l"
  run get_default_branch
  assert_output "master"
  _WT_DEFAULT_BRANCH="trunk"
  run get_default_branch
  assert_output "trunk"
}

# =============================================================================
# List line and icons
# =============================================================================

@test "format_worktree_line: absolute path in field 2, detached shown as (detached)" {
  make_fixture
  git worktree add -q --detach "$TMP/det" main
  run line_for "$TMP/det"
  assert_output "◌ (detached)	$TMP/det"
  run line_for "$TMP/proj"
  assert_output "● main	$TMP/proj"
}

@test "icons: a fresh branch is ★, not ✓ (even from origin/main)" {
  make_fixture
  git worktree add -q --no-track -b fresh "$TMP/fresh" origin/main
  # an old wt branch that tracks origin/main was never pushed either
  git worktree add -q --track -b old "$TMP/old" origin/main
  run line_for "$TMP/fresh"
  assert_output "★ fresh	$TMP/fresh"
  run line_for "$TMP/old"
  assert_output "★ old	$TMP/old"
}

@test "icons: merged ✓, in progress ○, pushed without -u is not ★" {
  make_fixture
  seed_commit feat/merged m.txt
  git -C "$TMP/seed" merge -q --no-ff -m merge feat/merged
  git -C "$TMP/seed" push -q origin main
  seed_commit feat/wip w.txt
  git fetch -q origin
  git worktree add -q "$TMP/wm" feat/merged
  git worktree add -q "$TMP/ww" feat/wip
  git worktree add -q --no-track -b nou "$TMP/nou" origin/feat/wip
  echo x > "$TMP/nou/x"; git -C "$TMP/nou" add x; git -C "$TMP/nou" commit -qm x
  git -C "$TMP/nou" push -q origin nou
  run line_for "$TMP/wm"
  assert_output "✓ feat/merged	$TMP/wm"
  run line_for "$TMP/ww"
  assert_output "○ feat/wip	$TMP/ww"
  run line_for "$TMP/nou"
  assert_output "○ nou	$TMP/nou"
}

@test "icons: squash merge detected after more commits and remote branch deletion" {
  make_fixture
  seed_commit feat/sq s1.txt
  seed_commit feat/sq s2.txt
  git fetch -q origin
  git worktree add -q "$TMP/wsq" feat/sq
  git -C "$TMP/seed" merge -q --squash feat/sq
  git -C "$TMP/seed" commit -qm "squash"
  echo later > "$TMP/seed/later"; git -C "$TMP/seed" add later; git -C "$TMP/seed" commit -qm later
  git -C "$TMP/seed" push -q origin main
  git -C "$TMP/seed" push -q origin --delete feat/sq
  git fetch -q --prune origin
  run line_for "$TMP/wsq"
  assert_output "✓ feat/sq	$TMP/wsq"
  # no object written per redraw: the virtual commit is always the same
  local before after
  before=$(git count-objects | cut -d' ' -f1)
  line_for "$TMP/wsq" >/dev/null
  after=$(git count-objects | cut -d' ' -f1)
  [[ "$before" == "$after" ]] || false
}

@test "icons: review worktree ◎, dirty marker *" {
  make_fixture
  seed_commit feat/r r.txt
  git fetch -q origin
  git worktree add -q "$TMP/proj-reviewing-feat-r" feat/r
  echo dirty > "$TMP/proj-reviewing-feat-r/d"
  run line_for "$TMP/proj-reviewing-feat-r"
  assert_output "◎ feat/r *	$TMP/proj-reviewing-feat-r"
}

# =============================================================================
# Preview
# =============================================================================

@test "worktree_preview: same status as the icon, no upstream info for a new branch" {
  make_fixture
  seed_commit feat/merged m.txt
  git -C "$TMP/seed" merge -q --no-ff -m merge feat/merged
  git -C "$TMP/seed" push -q origin main
  git fetch -q origin
  git worktree add -q "$TMP/wm" feat/merged
  git worktree add -q --no-track -b fresh "$TMP/fresh" origin/main
  cli_pr_status() { echo "PR-LOOKUP:$1"; }
  run worktree_preview "$TMP/wm"
  assert_output --partial "Branch: feat/merged"
  assert_output --partial "✓ merged"
  assert_output --partial "In sync with origin/feat/merged"
  assert_output --partial "PR-LOOKUP:feat/merged"
  run worktree_preview "$TMP/fresh"
  assert_output --partial "★ never pushed"
  assert_output --partial "No upstream: 0 commit(s) not in origin/main"
}

@test "worktree_preview: detached HEAD never looks up a PR" {
  make_fixture
  git worktree add -q --detach "$TMP/det" main
  cli_pr_status() { echo "PR-LOOKUP:[$1]"; }
  run worktree_preview "$TMP/det"
  assert_output --partial "HEAD: detached at"
  refute_output --partial "PR-LOOKUP"
}

@test "worktree_preview: fork review branch looks up the PR by number" {
  make_fixture
  git worktree add -q --no-track -b pr/12-main "$TMP/proj-reviewing-pr-12-main" main
  cli_pr_status() { echo "PR-LOOKUP:$1"; }
  run worktree_preview "$TMP/proj-reviewing-pr-12-main"
  assert_output --partial "PR-LOOKUP:12"
}

# =============================================================================
# .env copy
# =============================================================================

@test "copy_env_to_worktree: untracked only, no templates, never overwrites" {
  make_fixture
  echo 'API=prod' > "$TMP/seed/.env.production"
  git -C "$TMP/seed" add .env.production
  git -C "$TMP/seed" commit -qm env
  git -C "$TMP/seed" push -q origin main
  git pull -q
  echo 'API=local-edit' > .env.production
  echo 'SECRET=1' > .env
  echo 'L=1' > .env.local
  echo 'X=1' > .env.example
  echo 'X=1' > .env.sample
  echo 'X=1' > .env.template
  mkdir -p "$TMP/target"
  echo 'KEEP=me' > "$TMP/target/.env.local"
  echo 'API=prod' > "$TMP/target/.env.production"
  run copy_env_to_worktree "$TMP/target"
  assert_output "Copied 1 env file(s) to worktree"
  [[ "$(cat "$TMP/target/.env")" == "SECRET=1" ]] || false
  [[ "$(cat "$TMP/target/.env.local")" == "KEEP=me" ]] || false
  [[ "$(cat "$TMP/target/.env.production")" == "API=prod" ]] || false
  [[ ! -e "$TMP/target/.env.example" && ! -e "$TMP/target/.env.sample" && ! -e "$TMP/target/.env.template" ]] || false
}

# =============================================================================
# From existing branch / new branch / current
# =============================================================================

@test "create_from_branch: remote branch gives a local tracking branch, list has no origin/HEAD" {
  make_fixture
  seed_commit feat/remote-only r.txt
  git fetch -q origin
  export FZF_PICK='^origin/feat/remote-only'
  run --separate-stderr create_from_branch
  assert_success
  assert_output "$TMP/proj-feat-remote-only"
  run git -C "$TMP/proj-feat-remote-only" rev-parse --abbrev-ref '@{upstream}'
  assert_output "origin/feat/remote-only"
  run grep -E '^(origin|origin/HEAD|origin/main)(	|$)' "$FZF_LOG"
  assert_failure
  grep -q -- '--delimiter=	' "$FZF_LOG"
}

@test "create_from_branch: branch already open returns its worktree" {
  make_fixture
  export FZF_PICK='^main	'
  run --separate-stderr create_from_branch
  assert_success
  assert_output "$TMP/proj"
  [[ "$stderr" == *"already open"* ]] || false
}

@test "create_from_current: git errors are shown, detached HEAD handled" {
  make_fixture
  git branch temp
  run --separate-stderr create_from_current
  assert_failure
  assert_output ""
  [[ "$stderr" == *"Error creating worktree"* && "$stderr" == *"temp"* ]] || false
  git branch -D -q temp
  git checkout -q --detach
  run --separate-stderr create_from_current
  assert_success
  [[ "$output" == "$TMP/proj-detached-copy-"* ]] || false
  run git -C "$output" branch --show-current
  [[ "$output" == temp/detached-* ]] || false
}

@test "create_new_branch: Esc at the base selection cancels" {
  make_fixture
  export GUM_INPUT="feat/typo" FZF_RC=130
  run --separate-stderr create_new_branch
  assert_failure
  assert_output ""
  run git show-ref --verify --quiet refs/heads/feat/typo
  assert_failure
}

@test "create_new_branch: from origin/main without tracking it" {
  make_fixture
  export GUM_INPUT="  feat/x  " FZF_PICK='^origin/main	'
  run --separate-stderr create_new_branch
  assert_success
  assert_output "$TMP/proj-feat-x"
  run git config branch.feat/x.remote
  assert_failure
  grep -q 'Esc cancel' "$FZF_LOG"
}

@test "create_new_branch: detached HEAD as base, invalid names refused" {
  make_fixture
  git checkout -q --detach
  export GUM_INPUT="feat/y" FZF_PICK='\(current\)'
  run --separate-stderr create_new_branch
  assert_success
  assert_output "$TMP/proj-feat-y"
  grep -q 'HEAD (detached at' "$FZF_LOG"
  export GUM_INPUT="my feature"
  run --separate-stderr create_new_branch
  assert_failure
  [[ "$stderr" == *"Invalid branch name"* ]] || false
}

@test "relative WT_WORKTREE_DIR is taken from the main worktree's parent" {
  make_fixture
  git worktree add -q "$TMP/proj-b" -b b
  cd "$TMP/proj-b"
  export WT_WORKTREE_DIR="wts" GUM_INPUT="feat/rel" FZF_PICK='\(current\)'
  run --separate-stderr create_new_branch
  assert_success
  assert_output "$TMP/wts/proj-feat-rel"
  run git -C "$TMP/proj-b" status --porcelain
  assert_output ""
}

# =============================================================================
# From an issue
# =============================================================================

@test "create_from_issue: fresh base, no tracking, existing worktree reused" {
  make_fixture
  seed_commit main later.txt
  export WT_AUTO_FETCH=true
  run --separate-stderr create_from_issue 42 "Fix the Login Page for mobile users please"
  assert_success
  assert_output "$TMP/proj-feature-42-fix-the-login-page-for-mobile"
  local wt="$output"
  # based on the freshly fetched origin/main
  [[ -f "$wt/later.txt" ]] || false
  run git config branch.feature/42-fix-the-login-page-for-mobile.remote
  assert_failure
  run --separate-stderr create_from_issue 42 "Fix the Login Page for mobile users please"
  assert_success
  assert_output "$wt"
  run git show-ref --verify --quiet refs/heads/feature/42-fix-the-login-page-for-mobile-2
  assert_failure
}

@test "create_from_issue: master repo without origin/HEAD" {
  git init -q --bare "$TMP/r.git"
  git init -q -b master "$TMP/m"
  git -C "$TMP/m" commit -q --allow-empty -m i
  git -C "$TMP/m" remote add origin "$TMP/r.git"
  git -C "$TMP/m" push -q -u origin master
  git -C "$TMP/m" update-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
  MAIN_REPO="$TMP/m" REPO_NAME="m"
  cd "$TMP/m"
  export WT_AUTO_FETCH=false
  run --separate-stderr create_from_issue 5 "Do stuff"
  assert_success
  assert_output "$TMP/m-feature-5-do-stuff"
  [[ "$stderr" == *"from 'origin/master'"* ]] || false
}

@test "_wt_slugify: no trailing dash, fallback, accents when perl is there" {
  run _wt_slugify "Add a very long title with se- x"
  assert_output "add-a-very-long-title-with-se"
  run _wt_slugify "🚀🚀🚀"
  assert_output "issue"
  if command -v perl >/dev/null && perl -MUnicode::Normalize -e1 2>/dev/null; then
    run _wt_slugify "Créer l'écran Paramètres"
    assert_output "creer-l-ecran-parametres"
  fi
}

# =============================================================================
# From a PR / MR
# =============================================================================

@test "create_from_pr: same-repo PR tracks origin, unpushed local commits are kept" {
  make_fixture
  seed_commit feat/mine m1.txt
  git fetch -q origin
  run --separate-stderr create_from_pr feat/mine 5 0
  assert_success
  assert_output "$TMP/proj-reviewing-feat-mine"
  run git -C "$TMP/proj-reviewing-feat-mine" rev-parse --abbrev-ref '@{upstream}'
  assert_output "origin/feat/mine"
  echo local > "$TMP/proj-reviewing-feat-mine/local.txt"
  git -C "$TMP/proj-reviewing-feat-mine" add -A
  git -C "$TMP/proj-reviewing-feat-mine" commit -qm "unpushed"
  git worktree remove "$TMP/proj-reviewing-feat-mine"
  run --separate-stderr create_from_pr feat/mine 5 0
  assert_success
  run git log -1 --format=%s feat/mine
  assert_output "unpushed"
}

@test "create_from_pr: existing worktree is fast-forwarded, a dirty one only warned" {
  make_fixture
  seed_commit feat/wip w1.txt
  local wt
  wt=$(create_from_pr feat/wip 3 0 2>/dev/null)
  seed_commit feat/wip w2.txt
  run --separate-stderr create_from_pr feat/wip 3 0
  assert_success
  assert_output "$wt"
  [[ -f "$wt/w2.txt" ]] || false
  seed_commit feat/wip w3.txt
  echo edit >> "$wt/w1.txt"
  run --separate-stderr create_from_pr feat/wip 3 0
  assert_output "$wt"
  [[ "$stderr" == *"not updated"* ]] || false
  [[ ! -f "$wt/w3.txt" ]] || false
}

@test "create_from_pr: worktree path with spaces" {
  make_fixture
  seed_commit feat/wip w1.txt
  git fetch -q origin
  git worktree add -q "$TMP/my wt" feat/wip
  run --separate-stderr create_from_pr feat/wip 3 0
  assert_success
  assert_output "$TMP/my wt"
}

@test "create_from_pr: fork PR from 'main' never returns the main worktree" {
  make_fixture
  seed_pr_ref refs/pull/12/head fork.txt
  run --separate-stderr create_from_pr main 12 1
  assert_success
  assert_output "$TMP/proj-reviewing-pr-12-main"
  run git -C "$TMP/proj-reviewing-pr-12-main" log -1 --format=%s
  assert_output "fork: fork.txt"
  run git -C "$TMP/proj" log -1 --format=%s
  assert_output "init"
}

@test "create_from_pr: two fork PRs with the same head branch stay apart" {
  make_fixture
  seed_pr_ref refs/pull/10/head alice.txt
  seed_pr_ref refs/pull/11/head bob.txt
  local a b
  a=$(create_from_pr patch-1 10 1 2>/dev/null)
  b=$(create_from_pr patch-1 11 1 2>/dev/null)
  [[ "$a" != "$b" ]] || false
  [[ -f "$a/alice.txt" && ! -f "$a/bob.txt" ]] || false
  [[ -f "$b/bob.txt" && ! -f "$b/alice.txt" ]] || false
  # .env files are not copied into fork code
  [[ ! -e "$a/.env" ]] || false
}

@test "create_from_pr: head branch missing on origin falls back on the PR ref" {
  make_fixture
  seed_pr_ref refs/pull/7/head p7.txt
  run --separate-stderr create_from_pr only-on-fork 7 0
  assert_success
  assert_output "$TMP/proj-reviewing-pr-7-only-on-fork"
}

@test "create_from_pr: GitLab MR from a fork uses merge-requests/N/head" {
  make_fixture
  seed_pr_ref refs/merge-requests/5/head mr.txt
  _WT_PLATFORM="gitlab"
  run --separate-stderr create_from_pr fork-branch 5 1
  assert_success
  assert_output "$TMP/proj-reviewing-mr-5-fork-branch"
  [[ -f "$output/mr.txt" ]] || false
}

@test "create_from_pr: GitHub fork PR goes through gh pr checkout --branch" {
  make_fixture
  seed_pr_ref refs/pull/9/head gh.txt
  cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[[ "$1 $2" == "pr checkout" && "$4" == "--branch" ]] || exit 1
git fetch -q origin "refs/pull/$3/head:$5" && git checkout -q "$5" && \
  git config "branch.$5.pushRemote" https://example.invalid/fork.git
EOF
  export GH_LOG="$TMP/gh.log"
  run --separate-stderr create_from_pr patch-1 9 1
  assert_success
  assert_output "$TMP/proj-reviewing-pr-9-patch-1"
  run git -C "$TMP/proj-reviewing-pr-9-patch-1" branch --show-current
  assert_output "pr/9-patch-1"
  grep -q "pr checkout 9 --branch pr/9-patch-1" "$GH_LOG"
  run git config branch.pr/9-patch-1.pushRemote
  assert_output "https://example.invalid/fork.git"
}

@test "create_from_pr: single-branch clone" {
  make_fixture
  seed_commit feat/wip w1.txt
  git clone -q --single-branch --branch main "$TMP/remote.git" "$TMP/single"
  MAIN_REPO="$TMP/single" REPO_NAME="single"
  cd "$TMP/single"
  run --separate-stderr create_from_pr feat/wip 3 0
  assert_success
  assert_output "$TMP/single-reviewing-feat-wip"
  [[ -f "$output/w1.txt" ]] || false
}

# =============================================================================
# CLI auth
# =============================================================================

@test "setup_cli_auth: Back returns to the caller instead of exiting" {
  make_fixture
  has_cli() { return 1; }
  export FZF_PICK='^Back$'
  # the old "Quit" did `exit 0`, which never reached the next command
  run --separate-stderr eval '( setup_cli_auth; echo "rc=$?" )'
  assert_output "rc=1"
  grep -q '^Back$' "$FZF_LOG"
  run grep -q '^Quit$' "$FZF_LOG"
  assert_failure
}

@test "setup_cli_auth: token login asks for the token and pipes it to gh" {
  make_fixture
  has_cli() { return 1; }
  cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGS: $*"; echo "STDIN: $(cat)"; } >> "$GH_LOG"
EOF
  export GH_LOG="$TMP/gh.log" FZF_PICK='token' GUM_INPUT="ghp_secret"
  run --separate-stderr setup_cli_auth
  assert_success
  grep -q "ARGS: auth login --with-token" "$GH_LOG"
  grep -q "STDIN: ghp_secret" "$GH_LOG"
  export GUM_INPUT_RC=130
  : > "$GH_LOG"
  run --separate-stderr setup_cli_auth
  assert_failure
  [[ ! -s "$GH_LOG" ]] || false
}
