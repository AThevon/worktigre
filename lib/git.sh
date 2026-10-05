#!/usr/bin/env bash
# lib/git.sh - Worktree operations and creation

# =============================================================================
# CLI Auth Setup
# =============================================================================

setup_cli_auth() {
  if has_cli; then
    return 0  # Déjà authentifié
  fi

  local platform cli_name platform_name
  platform=$(detect_platform)
  cli_name=$(get_cli_name)
  platform_name=$(get_platform_name)

  if ! command -v "$cli_name" &>/dev/null; then
    msg "$platform_name CLI ($cli_name) is not installed"
    msg "$(get_pr_term) features will be disabled"
    if command -v brew &>/dev/null; then
      msg "Install with: brew install $cli_name"
    elif [[ "$platform" == "gitlab" ]]; then
      msg "Install: https://gitlab.com/gitlab-org/cli#installation"
    else
      msg "Install: https://cli.github.com"
    fi
    return 1
  fi

  local choice
  choice=$(printf "%s\n" \
    "Login via browser (recommended)" \
    "Login with a token" \
    "Continue without $platform_name" \
    "Back" | \
    wt_fzf --height=40% \
        --layout=reverse \
        --border \
        --header="$platform_name CLI is not configured")

  # Our stdout is captured by the menu that called us, and gh/glab only prompt
  # when stdout is a terminal: their output goes to stderr instead
  local host_args=()
  if [[ "$platform" == "gitlab" ]]; then
    local host
    host=$(_wt_remote_host)
    [[ -n "$host" && "$host" != "gitlab.com" ]] && host_args=(--hostname "$host")
  fi

  case "$choice" in
    *"browser"*)
      "$cli_name" auth login --web ${host_args[@]+"${host_args[@]}"} </dev/tty >&2
      ;;
    *"token"*)
      local token
      token=$(gum input --password --prompt "Token: " \
        --placeholder "Paste your $platform_name access token") || return 1
      [[ -z "$token" ]] && return 1
      if [[ "$platform" == "gitlab" ]]; then
        printf '%s\n' "$token" | glab auth login --stdin ${host_args[@]+"${host_args[@]}"} >&2
      else
        printf '%s\n' "$token" | gh auth login --with-token >&2
      fi
      ;;
    *)
      return 1  # Continue without / Back / Esc: back to the menu
      ;;
  esac
}

# =============================================================================
# Worktrees
# =============================================================================

# Registered worktrees as "<path>\t<branch>" lines (branch empty when the HEAD
# is detached), the main worktree first. Bare entries and folders that no
# longer exist (prunable) are skipped. Nothing is pruned here: a worktree on an
# unmounted disk or a renamed parent folder must stay repairable
# (`git worktree repair`); the prune happens after a deletion.
_wt_worktree_entries() {
  local line path="" branch="" skip=0 main_line="" rest=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }"; branch=""; skip=0 ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      bare|prunable|"prunable "*) skip=1 ;;
      "")
        if [[ -n "$path" && $skip -eq 0 && -d "$path" ]]; then
          if [[ "$path" == "${MAIN_REPO:-}" ]]; then
            main_line="$path"$'\t'"$branch"$'\n'
          else
            rest+="$path"$'\t'"$branch"$'\n'
          fi
        fi
        path=""
        ;;
    esac
  done < <(git -C "${MAIN_REPO:-.}" worktree list --porcelain 2>/dev/null; echo)
  printf '%s%s' "$main_line" "$rest"
}

get_worktrees() {
  _wt_worktree_entries | cut -f1
}

get_secondary_worktrees() {
  get_worktrees | grep -vxF -- "${MAIN_REPO:-}"
}

# Path of the worktree that has <branch> checked out (fails if none)
_wt_branch_worktree() {
  local p b
  while IFS=$'\t' read -r p b; do
    if [[ -n "$b" && "$b" == "$1" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done < <(_wt_worktree_entries)
  return 1
}

# Default branch of the repository. Uses the session cache _WT_DEFAULT_BRANCH
# (set by the entry point) when present. Without a valid origin/HEAD (repo
# created with init + push, git < 2.48, renamed default branch), falls back on
# origin/main, origin/master, then the local main/master, then "main".
get_default_branch() {
  if [[ -n "${_WT_DEFAULT_BRANCH:-}" ]]; then
    echo "$_WT_DEFAULT_BRANCH"
    return 0
  fi

  local repo="${MAIN_REPO:-.}" head refs ref
  head=$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
  refs=$'\n'$(git -C "$repo" for-each-ref --format='%(refname)' ${head:+"$head"} \
    refs/remotes/origin/main refs/remotes/origin/master \
    refs/heads/main refs/heads/master 2>/dev/null)$'\n'
  for ref in ${head:+"$head"} refs/remotes/origin/main refs/remotes/origin/master \
             refs/heads/main refs/heads/master; do
    if [[ "$refs" == *$'\n'"$ref"$'\n'* ]]; then
      ref="${ref#refs/remotes/origin/}"
      echo "${ref#refs/heads/}"
      return 0
    fi
  done
  echo "main"
}

# Ref the branches are compared to: origin/<default> (a fetch is enough, no
# pull needed), else the local default branch. Empty if neither exists.
_wt_merge_target() {
  if [[ -n "${_WT_MERGE_TARGET:-}" ]]; then
    echo "$_WT_MERGE_TARGET"
    return 0
  fi
  local default_branch ref
  default_branch=$(get_default_branch)
  for ref in "refs/remotes/origin/$default_branch" "refs/heads/$default_branch"; do
    if git -C "${MAIN_REPO:-.}" show-ref --verify --quiet "$ref"; then
      echo "$ref"
      return 0
    fi
  done
}

# Read in one git call what the status of a branch needs. Fills the _bi_*
# variables declared local by the caller: upstream ref, tracking state
# ("[ahead 1]", "[gone]"...), upstream branch name on its remote, tree of the
# branch, whether origin/<branch> exists, the comparison target and its tree.
_wt_load_branch_info() {
  local branch="$1" ref up track rref tree
  _bi_up="" _bi_track="" _bi_rref="" _bi_tree="" _bi_on_origin=0 _bi_ttree=""
  _bi_target=$(_wt_merge_target)
  # ":" cannot appear in a ref name, and unlike a tab it does not collapse
  # empty fields in `read`
  while IFS=: read -r ref up track rref tree; do
    case "$ref" in
      "refs/heads/$branch")
        _bi_up="$up" _bi_track="$track" _bi_rref="$rref" _bi_tree="$tree" ;;
      "refs/remotes/origin/$branch")
        _bi_on_origin=1 ;;
    esac
    [[ -n "$_bi_target" && "$ref" == "$_bi_target" ]] && _bi_ttree="$tree"
  done < <(git -C "${MAIN_REPO:-.}" for-each-ref \
    --format='%(refname):%(upstream):%(upstream:track):%(upstream:remoteref):%(tree)' \
    "refs/heads/$branch" "refs/remotes/origin/$branch" ${_bi_target:+"$_bi_target"} 2>/dev/null)
}

# Pushed = the branch exists on a remote under its own name: an upstream with
# the same name (even [gone]), or origin/<branch> (pushed without -u). A branch
# that tracks another name (old wt branches tracking origin/main) is not.
_wt_info_pushed() {
  [[ "$_bi_on_origin" -eq 1 ]] && return 0
  [[ -n "$_bi_up" && "$_bi_rref" == "refs/heads/$1" ]]
}

# Merged = the work of the branch is in the default branch: ancestor (merge or
# fast-forward), same tree (squash merge as the latest commit), or, when the
# remote branch was deleted ([gone], the usual "delete branch after merge"),
# a squash merge found by git cherry on a virtual commit that squashes the
# branch on its merge base. Fully local, no network.
_wt_info_merged() {
  local branch="$1"
  [[ -n "$_bi_target" && -n "$_bi_tree" ]] || return 1
  git -C "$MAIN_REPO" merge-base --is-ancestor "refs/heads/$branch" "$_bi_target" 2>/dev/null && return 0
  [[ "$_bi_tree" == "$_bi_ttree" ]] && return 0
  [[ "$_bi_track" == "[gone]" ]] || return 1

  local base virtual
  base=$(git -C "$MAIN_REPO" merge-base "$_bi_target" "refs/heads/$branch" 2>/dev/null) || return 1
  # Fixed identity and date: the same branch always gives the same object, and
  # signing is off so no GPG/SSH prompt pops up while drawing the list
  virtual=$(GIT_AUTHOR_NAME=wt GIT_AUTHOR_EMAIL=wt@localhost GIT_AUTHOR_DATE='@1112911993 +0000' \
    GIT_COMMITTER_NAME=wt GIT_COMMITTER_EMAIL=wt@localhost GIT_COMMITTER_DATE='@1112911993 +0000' \
    git -C "$MAIN_REPO" -c commit.gpgSign=false commit-tree "$_bi_tree" -p "$base" \
      -m "wt squash check" 2>/dev/null) || return 1
  [[ "$(git -C "$MAIN_REPO" cherry "$_bi_target" "$virtual" 2>/dev/null)" == "-"* ]]
}

# Check if the work of a branch is in the default branch (a branch without
# commits of its own counts as merged: deleting it loses nothing)
is_branch_merged() {
  local _bi_up _bi_track _bi_rref _bi_tree _bi_on_origin _bi_target _bi_ttree
  [[ "$1" == "$(get_default_branch)" ]] && return 1
  _wt_load_branch_info "$1"
  _wt_info_merged "$1"
}

# Status of a worktree, shared by the list icon and the preview:
# default | detached | merged | review | new | wip
# A branch never pushed is "new" even when it is an ancestor of the default
# branch (a fresh branch has no commit of its own, it is not "merged").
_wt_branch_state() {
  local wt_path="$1" branch="$2"
  if [[ -z "$branch" ]]; then
    echo detached
    return 0
  fi
  if [[ "$branch" == "$(get_default_branch)" ]]; then
    echo default
    return 0
  fi

  local _bi_up _bi_track _bi_rref _bi_tree _bi_on_origin _bi_target _bi_ttree
  _wt_load_branch_info "$branch"
  local review=0 pushed=0
  [[ "${wt_path##*/}" == *"-reviewing-"* ]] && review=1
  _wt_info_pushed "$branch" && pushed=1

  if [[ $review -eq 1 || $pushed -eq 1 ]] && _wt_info_merged "$branch"; then
    echo merged
  elif [[ $review -eq 1 ]]; then
    echo review
  elif [[ $pushed -eq 0 ]]; then
    echo new
  else
    echo wip
  fi
}

# Une ligne du menu: "<icone> <branche>[ *]<TAB><chemin absolu>"
# Usage: format_worktree_line <path> [<branch>]  (branch read from git if omitted)
format_worktree_line() {
  local wt_path="$1" branch
  if [[ $# -ge 2 ]]; then
    branch="$2"
  else
    branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
  fi

  # Dirty check
  local dirty=""
  if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]]; then
    dirty=" *"
  fi

  local status_icon
  case "$(_wt_branch_state "$wt_path" "$branch")" in
    default)  status_icon="${C_DIM}●${C_RESET}" ;;      # Main branch - neutral
    detached) status_icon="${C_DIM}◌${C_RESET}" ;;      # Detached HEAD - no branch
    merged)   status_icon="${C_GREEN}✓${C_RESET}" ;;    # Merged - green checkmark
    review)   status_icon="${C_MAGENTA}◎${C_RESET}" ;;  # Review worktree - magenta eye
    new)      status_icon="${C_YELLOW}★${C_RESET}" ;;   # Never pushed - yellow star
    *)        status_icon="${C_ORANGE}○${C_RESET}" ;;   # In progress (pushed, not merged)
  esac

  printf "%s %s%s\t%s\n" "$status_icon" "${branch:-(detached)}" "$dirty" "$wt_path"
}

format_all_worktrees() {
  # Computed once for the whole list instead of once per line
  local _WT_DEFAULT_BRANCH="${_WT_DEFAULT_BRANCH:-$(get_default_branch)}"
  local _WT_MERGE_TARGET="${_WT_MERGE_TARGET:-$(_wt_merge_target)}"
  local wt branch
  while IFS=$'\t' read -r wt branch; do
    format_worktree_line "$wt" "$branch"
  done < <(_wt_worktree_entries)
}

# Preview of a worktree (main menu, Delete): branch with the same status as the
# list icon, uncommitted changes, sync with the upstream, recent commits, then
# the PR/MR of the branch (network, so last)
worktree_preview() {
  local wt_path="$1"
  [[ -z "$wt_path" ]] && return 0
  if [[ ! -d "$wt_path" ]]; then
    echo "Worktree not found: $wt_path"
    return 0
  fi

  local branch state
  branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
  state=$(_wt_branch_state "$wt_path" "$branch")

  local rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  printf '%s\n' "$rule"
  case "$state" in
    detached) printf '  HEAD: detached at %s\n' "$(git -C "$wt_path" rev-parse --short HEAD 2>/dev/null)" ;;
    default)  printf '  Branch: %s  \033[2m● default branch\033[0m\n' "$branch" ;;
    merged)   printf '  Branch: %s  \033[32m✓ merged\033[0m\n' "$branch" ;;
    review)   printf '  Branch: %s  \033[35m◎ review, not merged\033[0m\n' "$branch" ;;
    new)      printf '  Branch: %s  \033[33m★ never pushed\033[0m\n' "$branch" ;;
    *)        printf '  Branch: %s  \033[38;5;208m○ not merged\033[0m\n' "$branch" ;;
  esac
  printf '%s\n\n' "$rule"

  # Uncommitted changes
  local changes count
  changes=$(git -C "$wt_path" status --porcelain 2>/dev/null)
  if [[ -n "$changes" ]]; then
    printf '  \033[33mUncommitted changes:\033[0m\n'
    printf '%s\n' "$changes" | head -8
    count=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
    [[ $count -gt 8 ]] && printf '  ... and %s more\n' "$((count - 8))"
    echo ''
  fi

  # Sync status with remote
  if [[ -n "$branch" ]]; then
    local upstream track ahead=0 behind=0 re
    IFS=: read -r upstream track < <(git -C "$wt_path" for-each-ref \
      --format='%(upstream:short):%(upstream:track)' "refs/heads/$branch" 2>/dev/null)
    re='ahead ([0-9]+)'; [[ "$track" =~ $re ]] && ahead="${BASH_REMATCH[1]}"
    re='behind ([0-9]+)'; [[ "$track" =~ $re ]] && behind="${BASH_REMATCH[1]}"
    if [[ -z "$upstream" ]]; then
      local target
      target=$(_wt_merge_target)
      if [[ -n "$target" ]]; then
        ahead=$(git -C "$wt_path" rev-list --count "$target..HEAD" 2>/dev/null || echo 0)
        target="${target#refs/remotes/}"
        printf '  No upstream: %s commit(s) not in %s\n' "$ahead" "${target#refs/heads/}"
      else
        printf '  No upstream\n'
      fi
    elif [[ "$track" == "[gone]" ]]; then
      printf '  Upstream %s is gone (deleted on the remote)\n' "$upstream"
    elif [[ $ahead -gt 0 && $behind -gt 0 ]]; then
      printf '  ↑%s ↓%s  (diverged from %s)\n' "$ahead" "$behind" "$upstream"
    elif [[ $ahead -gt 0 ]]; then
      printf '  ↑%s ahead of %s\n' "$ahead" "$upstream"
    elif [[ $behind -gt 0 ]]; then
      printf '  ↓%s behind %s\n' "$behind" "$upstream"
    else
      printf '  ✓ In sync with %s\n' "$upstream"
    fi
    echo ''
  fi

  # Recent commits
  printf '  Recent commits:\n'
  git -C "$wt_path" log --oneline --graph --color=always -8 2>/dev/null
  echo ''

  # PR/MR status (at the end, can be slow). Fork review branches
  # (pr/<num>-<head>, mr/<num>-<head>) are looked up by number.
  case "$state" in default|detached) return 0 ;; esac
  local pr_arg="$branch" re_num='^(pr|mr)/([0-9]+)-'
  [[ "$branch" =~ $re_num ]] && pr_arg="${BASH_REMATCH[2]}"
  if declare -F cli_pr_status >/dev/null; then
    cli_pr_status "$pr_arg"
  fi
}

# =============================================================================
# Env file auto-copy
# =============================================================================

# Copy the local .env files of the main worktree into a new worktree. Only
# untracked files (tracked ones are already in the checkout, with the content
# of the target branch), never templates, never over an existing file.
copy_env_to_worktree() {
  local target="$1" f name tracked copied=0
  tracked=$'\n'$(git -C "$MAIN_REPO" ls-files -- '.env*' 2>/dev/null)$'\n'
  for f in "$MAIN_REPO"/.env*; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
    case "$name" in *.example|*.sample|*.template) continue ;; esac
    [[ "$tracked" == *$'\n'"$name"$'\n'* ]] && continue
    [[ -e "$target/$name" || -L "$target/$name" ]] && continue
    cp "$f" "$target/$name" && copied=$((copied + 1))
  done
  if [[ $copied -gt 0 ]]; then
    msg "Copied $copied env file(s) to worktree"
  fi
}

# =============================================================================
# Helpers de création
# =============================================================================

# Absolute path for a new worktree folder <name>, next to the main worktree or
# in WT_WORKTREE_DIR (see get_worktree_base_dir). A path already used gets a
# -2, -3... suffix.
_wt_new_worktree_path() {
  local base
  base=$(get_worktree_base_dir)
  local registered candidate="$base/$1" n=2
  registered=$'\n'$(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')$'\n'
  while [[ -e "$candidate" || -L "$candidate" || "$registered" == *$'\n'"$candidate"$'\n'* ]]; do
    candidate="$base/$1-$n"
    n=$((n + 1))
  done
  echo "$candidate"
}

# git worktree add <args...>, from the main worktree. On failure, git's own
# message is shown (stderr) so the user knows why.
_wt_add_worktree() {
  local out
  if out=$(git -C "$MAIN_REPO" worktree add "$@" 2>&1); then
    return 0
  fi
  ui_error "Error creating worktree"
  [[ -n "$out" ]] && printf '%s\n' "$out" >&2
  return 1
}

# Branches for fzf, one per line: "<label>\t<full ref>\t<local name>".
# Local branches first, then remote ones (origin/HEAD left out). With --dedupe,
# a remote branch that has a local branch of the same name is not listed.
# Usage: _wt_branch_choices [--dedupe] [<local branch to leave out>]
_wt_branch_choices() {
  local dedupe=0 skip
  [[ "${1:-}" == "--dedupe" ]] && { dedupe=1; shift; }
  skip="${1:-}"  # local branch to leave out
  git for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null | \
    awk -v remotes="$(git remote 2>/dev/null | tr '\n' ' ')" -v dedupe="$dedupe" -v skip="$skip" '
      BEGIN { n = split(remotes, R, " ") }
      /^refs\/heads\// {
        name = substr($0, 12); seen[name] = 1
        if (name != skip) print name "\t" $0 "\t" name
        next
      }
      /^refs\/remotes\// {
        rest = substr($0, 14); best = ""
        for (i = 1; i <= n; i++)
          if (index(rest, R[i] "/") == 1 && length(R[i]) > length(best)) best = R[i]
        if (best == "") next
        lname = substr(rest, length(best) + 2)
        if (lname == "HEAD") next
        m++; label[m] = rest; ref[m] = $0; loc[m] = lname
      }
      END {
        for (i = 1; i <= m; i++)
          if (!(dedupe && (loc[i] in seen))) print label[i] "\t" ref[i] "\t" loc[i]
      }'
}

# Trim the spaces around a name typed by the user
_wt_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ASCII slug of an issue title: accents transliterated (perl NFD, else iconv),
# 30 characters max, no dash at the ends, "issue" when nothing is left
_wt_slugify() {
  local text="$1" ascii=""
  if command -v perl >/dev/null 2>&1; then
    ascii=$(printf '%s' "$text" | perl -CSA -MUnicode::Normalize -pe '$_ = NFD($_); s/\pM//g' 2>/dev/null)
  fi
  if [[ -z "$ascii" ]] && command -v iconv >/dev/null 2>&1; then
    # macOS iconv writes accents as separate marks ('e, `a): drop them
    ascii=$(printf '%s' "$text" | tr "'" ' ' | iconv -c -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | tr -d "'\"^\`~")
  fi
  [[ -z "$ascii" ]] && ascii="$text"
  local slug
  slug=$(printf '%s' "$ascii" | LC_ALL=C tr '[:upper:]' '[:lower:]' | \
    LC_ALL=C sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//' | cut -c1-30 | sed 's/-$//')
  printf '%s' "${slug:-issue}"
}

# Bring an existing worktree up to date with <commit> (already fetched):
# fast-forward only, and only without uncommitted changes. Otherwise warn.
_wt_sync_worktree() {
  local wt="$1" commit="$2" behind ahead
  read -r behind ahead < <(git -C "$wt" rev-list --left-right --count "$commit...HEAD" 2>/dev/null)
  [[ -z "$behind" ]] && return 0
  if [[ "$behind" -eq 0 ]]; then
    [[ "${ahead:-0}" -gt 0 ]] && msg "Local branch kept: $ahead commit(s) not pushed yet"
    return 0
  fi
  if [[ "${ahead:-0}" -gt 0 ]]; then
    msg_warn "Local branch has diverged ($ahead local commit(s), $behind new upstream): not updated"
    return 1
  fi
  if [[ -n $(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null) ]]; then
    msg_warn "Uncommitted changes: worktree not updated ($behind new commit(s) upstream)"
    return 1
  fi
  if git -C "$wt" merge -q --ff-only "$commit" >/dev/null 2>&1; then
    msg "Updated to the latest commit ($behind new)"
  else
    msg_warn "Could not fast-forward the worktree ($behind new commit(s) upstream)"
    return 1
  fi
}

# Fetch one ref from origin, print the fetched commit
_wt_fetch_commit() {
  git -C "$MAIN_REPO" fetch -q origin "$1" >/dev/null 2>&1 || return 1
  git -C "$MAIN_REPO" rev-parse -q --verify "FETCH_HEAD^{commit}" 2>/dev/null
}

# =============================================================================
# Actions de création - retournent le path sur stdout
# =============================================================================

# Créer un worktree à partir de la branche actuelle (duplicate)
create_from_current() {
  local current_branch head
  current_branch=$(git branch --show-current 2>/dev/null)
  if ! head=$(git rev-parse -q --verify "HEAD^{commit}" 2>/dev/null); then
    ui_error "No commit to copy yet"
    return 1
  fi
  local timestamp sanitized worktree_path
  timestamp=$(date +%Y%m%d-%H%M%S)
  sanitized="${current_branch:-detached}"
  sanitized="${sanitized//\//-}"
  # Toujours créer à côté du repo PRINCIPAL
  worktree_path=$(_wt_new_worktree_path "${REPO_NAME}-${sanitized}-copy-${timestamp}")
  local new_branch="temp/${sanitized}-${timestamp}"

  msg "Creating worktree..."

  _wt_add_worktree --no-track -b "$new_branch" "$worktree_path" "$head" || return 1
  ui_box "Worktree created" "$worktree_path" "Branch: $new_branch"
  copy_env_to_worktree "$worktree_path"
  echo "$worktree_path"  # SEUL output sur stdout
}

# Créer un worktree à partir d'une branche
create_from_branch() {
  if [[ "${WT_AUTO_FETCH:-true}" != "false" ]]; then
    msg "Fetching branches..."
    git fetch --all --prune >/dev/null 2>&1
  fi

  local selected
  local branch_header="${C_BOLD}Select branch${C_RESET}"
  local branch_footer="Enter select · Esc cancel"
  selected=$(_wt_branch_choices --dedupe | \
    wt_fzf --height=60% \
        --layout=reverse \
        --border \
        --ansi \
        --delimiter=$'\t' \
        --with-nth=1 \
        --header="$branch_header" \
        --footer="$branch_footer" \
        --preview="git log --oneline --graph --color=always -10 {2}" \
        --preview-window=right:50%)

  if [[ -z "$selected" ]]; then
    msg "No branch selected"
    return 1
  fi

  local ref local_name
  ref="${selected#*$'\t'}"
  local_name="${ref#*$'\t'}"
  ref="${ref%%$'\t'*}"

  # Branche déjà ouverte dans un worktree: y aller
  local existing
  if existing=$(_wt_branch_worktree "$local_name"); then
    msg "Branch '$local_name' is already open at: $existing"
    echo "$existing"
    return 0
  fi

  local worktree_path
  # Toujours créer à côté du repo PRINCIPAL
  worktree_path=$(_wt_new_worktree_path "${REPO_NAME}-${local_name//\//-}")

  msg "Creating worktree..."

  if [[ "$ref" == refs/remotes/* ]] && \
     ! git show-ref --verify --quiet "refs/heads/$local_name"; then
    # Remote-only branch: a real local branch that tracks it, not a detached HEAD
    _wt_add_worktree --track -b "$local_name" "$worktree_path" "$ref" || return 1
  else
    _wt_add_worktree "$worktree_path" "$local_name" || return 1
  fi
  ui_box "Worktree created" "$worktree_path" "Branch: $local_name"
  copy_env_to_worktree "$worktree_path"
  echo "$worktree_path"  # SEUL output sur stdout
}

# Créer un worktree avec une nouvelle branche
create_new_branch() {
  # 1. Input nom de branche
  local input_branch_name
  input_branch_name=$(ui_input "Branch name:" "feature/...") || { msg "Cancelled"; return 1; }
  input_branch_name=$(_wt_trim "$input_branch_name")

  if [[ -z "$input_branch_name" ]]; then
    msg "No branch name provided"
    return 1
  fi
  if ! git check-ref-format --branch "$input_branch_name" >/dev/null 2>&1; then
    ui_error "Invalid branch name: $input_branch_name"
    return 1
  fi

  # 2. Sélectionner branche de base
  if [[ "${WT_AUTO_FETCH:-true}" != "false" ]]; then
    msg "Fetching branches..."
    git fetch --all --prune >/dev/null 2>&1
  fi

  local current_branch current_label current_ref
  current_branch=$(git branch --show-current 2>/dev/null)
  if [[ -n "$current_branch" ]]; then
    current_label="$current_branch"
    current_ref="refs/heads/$current_branch"
  else
    current_ref=$(git rev-parse -q --verify "HEAD^{commit}" 2>/dev/null)
    current_label="HEAD (detached at ${current_ref:0:7})"
  fi

  local base_header="${C_BOLD}Base branch${C_RESET}"
  local base_footer="Enter select · Esc cancel"
  local selected
  selected=$( { [[ -n "$current_ref" ]] && printf '%s (current)\t%s\t\n' "$current_label" "$current_ref"
                _wt_branch_choices "$current_branch"; } | \
    wt_fzf --height=60% \
        --layout=reverse \
        --border \
        --ansi \
        --delimiter=$'\t' \
        --with-nth=1 \
        --header="$base_header" \
        --footer="$base_footer" \
        --preview="git log --oneline --graph --color=always -10 {2} 2>/dev/null" \
        --preview-window=right:50%)
  local rc=$?

  # Esc / Ctrl-C (ou erreur fzf): annuler, rien n'est créé
  if [[ $rc -ne 0 || -z "$selected" ]]; then
    msg "Cancelled"
    return 1
  fi
  local base_label="${selected%%$'\t'*}"
  base_label="${base_label% (current)}"
  local base_ref="${selected#*$'\t'}"
  base_ref="${base_ref%%$'\t'*}"

  # 3. Incrémenter si la branche existe déjà
  local branch_name="$input_branch_name"
  local counter=2
  while git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null || \
        git show-ref --verify --quiet "refs/remotes/origin/$branch_name" 2>/dev/null; do
    branch_name="${input_branch_name}-${counter}"
    ((counter++))
  done

  # 4. Créer le worktree
  local worktree_path
  worktree_path=$(_wt_new_worktree_path "${REPO_NAME}-${branch_name//\//-}")

  msg "Creating worktree with new branch '$branch_name' from '$base_label'..."

  # --no-track: a new branch must not track its base (origin/main), or a plain
  # `git push` would target the base branch
  _wt_add_worktree --no-track -b "$branch_name" "$worktree_path" "$base_ref" || return 1
  ui_box "Worktree created" "$worktree_path" "Branch: $branch_name (from $base_label)"
  copy_env_to_worktree "$worktree_path"
  echo "$worktree_path"  # SEUL output sur stdout
}

# PR/MR from the same repository: local branch = head branch, tracking origin.
# An existing local branch is never reset: fast-forward only.
_wt_pr_same_repo() {
  local pr_branch="$1" remote_ref="refs/remotes/origin/$1" existing
  if existing=$(_wt_branch_worktree "$pr_branch"); then
    msg "Using existing worktree: $existing"
    _wt_sync_worktree "$existing" "$remote_ref"
    echo "$existing"
    return 0
  fi

  local worktree_path
  # Toujours créer à côté du repo PRINCIPAL, avec préfixe "reviewing"
  worktree_path=$(_wt_new_worktree_path "${REPO_NAME}-reviewing-${pr_branch//\//-}")

  msg "Creating worktree..."
  if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$pr_branch"; then
    _wt_add_worktree "$worktree_path" "$pr_branch" || return 1
    _wt_sync_worktree "$worktree_path" "$remote_ref"
  else
    # Tracking written by hand: `--track` refuses a ref outside the fetch
    # refspec (single-branch or shallow clones)
    _wt_add_worktree --no-track -b "$pr_branch" "$worktree_path" "$remote_ref" || return 1
    git -C "$MAIN_REPO" config "branch.$pr_branch.remote" origin
    git -C "$MAIN_REPO" config "branch.$pr_branch.merge" "refs/heads/$pr_branch"
  fi
  ui_box "Worktree created" "$worktree_path" "Branch: $pr_branch"
  copy_env_to_worktree "$worktree_path"
  echo "$worktree_path"
}

# PR/MR from a fork: its own local branch pr/<num>-<head> (mr/... on GitLab),
# so it never mixes with a branch of origin that has the same name (fork:main)
# or with another fork's PR (patch-1). GitHub: `gh pr checkout` in the
# worktree, which also sets up pushing to the fork. Otherwise (GitLab, or gh
# failing): the PR/MR ref of origin (pull/N/head, merge-requests/N/head).
_wt_pr_fork() {
  local pr_branch="$1" pr_num="$2"
  local platform pr_term pr_ref prefix ref_label
  platform=$(detect_platform)
  pr_term=$(get_pr_term)
  if [[ "$platform" == "gitlab" ]]; then
    pr_ref="refs/merge-requests/$pr_num/head"; prefix="mr"; ref_label="!$pr_num"
  else
    pr_ref="refs/pull/$pr_num/head"; prefix="pr"; ref_label="#$pr_num"
  fi
  local local_branch="$prefix/$pr_num-$pr_branch"
  local use_gh=0
  [[ "$platform" != "gitlab" ]] && command -v gh >/dev/null 2>&1 && use_gh=1

  local existing commit
  if existing=$(_wt_branch_worktree "$local_branch"); then
    msg "Using existing worktree: $existing"
    if [[ $use_gh -eq 1 ]]; then
      if [[ -n $(git -C "$existing" status --porcelain --untracked-files=no 2>/dev/null) ]]; then
        msg_warn "Uncommitted changes: worktree not updated"
      elif ! (cd "$existing" && gh pr checkout "$pr_num" --branch "$local_branch" </dev/null >&2 2>&1); then
        msg_warn "Could not update the worktree to the latest $pr_term head"
      fi
    elif commit=$(_wt_fetch_commit "$pr_ref"); then
      _wt_sync_worktree "$existing" "$commit"
    else
      msg_warn "Could not fetch the latest $pr_term head: worktree not updated"
    fi
    echo "$existing"
    return 0
  fi

  local worktree_path
  worktree_path=$(_wt_new_worktree_path "${REPO_NAME}-reviewing-${local_branch//\//-}")
  msg "Fetching $pr_term from fork..."

  local ok=0
  if [[ $use_gh -eq 1 ]]; then
    local start
    start=$(_wt_merge_target)
    _wt_add_worktree --detach "$worktree_path" "${start:-HEAD}" || return 1
    if (cd "$worktree_path" && gh pr checkout "$pr_num" --branch "$local_branch" </dev/null >&2 2>&1); then
      ok=1
    elif git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$local_branch" && \
         git -C "$worktree_path" checkout -q "$local_branch" 2>/dev/null; then
      # gh refuses to move a local branch that has diverged: keep it as is
      msg_warn "Local branch '$local_branch' differs from the $pr_term head: kept as is"
      ok=1
    else
      git -C "$MAIN_REPO" worktree remove --force "$worktree_path" >/dev/null 2>&1
    fi
  fi

  if [[ $ok -eq 0 ]]; then
    if ! commit=$(_wt_fetch_commit "$pr_ref"); then
      ui_error "Error fetching $pr_term $ref_label"
      return 1
    fi
    if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$local_branch"; then
      _wt_add_worktree "$worktree_path" "$local_branch" || return 1
      _wt_sync_worktree "$worktree_path" "$commit"
    else
      _wt_add_worktree --no-track -b "$local_branch" "$worktree_path" "$commit" || return 1
    fi
  fi

  ui_box "Worktree created" "$worktree_path" "Branch: $local_branch"
  # Fork code is not trusted: local secrets stay out of it
  if compgen -G "$MAIN_REPO/.env*" >/dev/null; then
    msg "Fork $pr_term: .env files not copied"
  fi
  echo "$worktree_path"
}

# Créer un worktree depuis une PR/MR
# Usage: create_from_pr <head_branch> <num> [<cross 0|1>]  -> path on stdout
create_from_pr() {
  local pr_branch="${1#origin/}"
  local pr_num="${2#[#!]}"
  local cross="${3:-}"

  if [[ "$cross" != "1" ]]; then
    msg "Fetching branch..."
    # Explicit refspec: also works in single-branch and shallow clones
    if git -C "$MAIN_REPO" fetch -q origin \
         "+refs/heads/$pr_branch:refs/remotes/origin/$pr_branch" >/dev/null 2>&1; then
      _wt_pr_same_repo "$pr_branch"
      return
    fi
    if [[ -z "$pr_num" ]]; then
      ui_error "Branch '$pr_branch' not found on origin and no $(get_pr_term) number provided"
      return 1
    fi
    msg "Branch not on origin, treating it as a fork $(get_pr_term)"
  fi
  if [[ -z "$pr_num" ]]; then
    ui_error "No $(get_pr_term) number provided"
    return 1
  fi
  _wt_pr_fork "$pr_branch" "$pr_num"
}

# Worktree already open for an issue: branch <prefix><num> or <prefix><num>-*
_wt_issue_worktree() {
  local p b
  while IFS=$'\t' read -r p b; do
    case "$b" in
      "$1"|"$1"-*) printf '%s\n' "$p"; return 0 ;;
    esac
  done < <(_wt_worktree_entries)
  return 1
}

# Créer un worktree depuis une issue
create_from_issue() {
  local issue_num="${1#[#!]}"
  local issue_title="$2"
  local _feature_prefix="${WT_FEATURE_PREFIX:-feature/}"

  # Reprendre le worktree déjà ouvert pour cette issue
  local existing
  if existing=$(_wt_issue_worktree "${_feature_prefix}${issue_num}"); then
    msg "Using existing worktree for issue #$issue_num: $existing"
    echo "$existing"
    return 0
  fi

  # Créer un slug à partir du titre
  local slug
  slug=$(_wt_slugify "$issue_title")
  local base_branch_name="${_feature_prefix}${issue_num}-${slug}"
  local branch_name="$base_branch_name"

  # Incrémenter si la branche existe déjà
  local counter=2
  while git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null || \
        git -C "$MAIN_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch_name" 2>/dev/null; do
    branch_name="${base_branch_name}-${counter}"
    ((counter++))
  done

  local worktree_path
  worktree_path=$(_wt_new_worktree_path "${REPO_NAME}-${branch_name//\//-}")

  # Base: origin/<default> à jour (WT_AUTO_FETCH), sinon la branche locale
  local default_branch base
  default_branch=$(get_default_branch)
  if [[ "${WT_AUTO_FETCH:-true}" != "false" ]]; then
    msg "Fetching $default_branch..."
    git -C "$MAIN_REPO" fetch -q origin \
      "+refs/heads/$default_branch:refs/remotes/origin/$default_branch" >/dev/null 2>&1
  fi
  base=$(_wt_merge_target)
  if [[ -z "$base" ]]; then
    base=$(git -C "$MAIN_REPO" rev-parse -q --verify "HEAD^{commit}" 2>/dev/null) || {
      ui_error "No base commit to create the branch from"
      return 1
    }
  fi
  local base_label="${base#refs/remotes/}"
  base_label="${base_label#refs/heads/}"

  msg "Creating worktree with new branch '$branch_name' from '$base_label'..."

  # --no-track: the issue branch must not track origin/<default>
  _wt_add_worktree --no-track -b "$branch_name" "$worktree_path" "$base" || return 1
  ui_box "Worktree created" "$worktree_path" "Branch: $branch_name"
  copy_env_to_worktree "$worktree_path"
  echo "$worktree_path"  # SEUL output sur stdout
}
