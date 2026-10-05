#!/usr/bin/env bash
# lib/menus.sh - PR, issue, create, delete, settings, wizards

# Replace a leading $HOME with ~ for display (same result on bash 3.2 and 5)
_menus_tilde() {
  local p="$1"
  case "$p" in
    "$HOME"|"$HOME"/*) p="~${p#"$HOME"}" ;;
  esac
  printf '%s' "$p"
}

# Run a list fetcher with its stderr kept in a file, so gh/glab errors can be
# shown once the spinner is gone instead of being drawn over by it
_menus_quiet() {
  local errfile="$1"
  shift
  "$@" 2>"$errfile"
}

# =============================================================================
# PRs / MRs
# =============================================================================

get_formatted_prs() {
  cli_pr_list
}

# "#12" on GitHub, "!12" on GitLab
format_pr_ref() {
  if [[ "$(detect_platform)" == "gitlab" ]]; then
    echo "!$1"
  else
    echo "#$1"
  fi
}

pr_preview() {
  # fzf passes the displayed ref (#12 or !12), gh and glab want the number
  local pr_num="${1#\#}"
  pr_num="${pr_num#!}"
  if [[ -z "$pr_num" ]]; then
    echo "Select a $(get_pr_term)"
    return
  fi

  echo "================================================"
  cli_pr_view "$pr_num"
  echo ""
  echo "================================================"
  echo "Changed files:"
  cli_pr_diff_stat "$pr_num"
}

# =============================================================================
# Issues
# =============================================================================

get_formatted_issues() {
  cli_issue_list
}

issue_preview() {
  local issue_num="${1#\#}"
  issue_num="${issue_num#!}"
  if [[ -z "$issue_num" ]]; then
    echo "Select an issue"
    return
  fi

  echo "================================================"
  cli_issue_view "$issue_num"
  echo ""
  echo "================================================"
}

# =============================================================================
# Claude Code Integration
# =============================================================================

# Sélecteur de mode Claude avec fzf
# Retourne le mode sélectionné ou vide si annulé
select_claude_mode() {
  local context_type="$1"  # pr-review, pr-work, issue-work
  local context_num="$2"

  # If a default mode is configured, bypass the picker
  if [[ -n "${WT_CLAUDE_MODE:-}" ]]; then
    case "$WT_CLAUDE_MODE" in
      forced|ask|plan)
        echo "$WT_CLAUDE_MODE"
        return
        ;;
    esac
  fi

  local title
  case "$context_type" in
    "pr-review") title="$(get_pr_term) $(format_pr_ref "$context_num") review" ;;
    "pr-work")   title="$(get_pr_term) $(format_pr_ref "$context_num")" ;;
    "issue-work") title="Issue #$context_num" ;;
    *) title="Claude mode" ;;
  esac

  local header="${C_BOLD}$title${C_RESET}"
  local footer="^F forced · ^A ask · ^P plan"

  local options=">> Forced (full auto)
?> Ask (confirm actions)
## Plan (plan first)"

  local result
  result=$(wt_fzf --height=25% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --footer="$footer" \
        --expect=ctrl-f,ctrl-a,ctrl-p \
        --preview="
          case {} in
            *Forced*)
              echo 'Mode: --dangerously-skip-permissions'
              echo ''
              echo 'Claude executes all actions automatically'
              echo 'without asking for confirmation.'
              echo ''
              echo '!! Full autonomy - use with caution'
              ;;
            *Ask*)
              echo 'Mode: default (interactive)'
              echo ''
              echo 'Claude asks for confirmation before'
              echo 'executing impactful actions.'
              echo ''
              echo '* Recommended for most cases'
              ;;
            *Plan*)
              echo 'Mode: --permission-mode=plan'
              echo ''
              echo 'Claude analyzes and creates a plan'
              echo 'before any execution.'
              echo ''
              echo '* Best for complex tasks'
              ;;
          esac
        " \
        --preview-window=right:50% <<< "$options")

  local key mode
  key=$(printf '%s\n' "$result" | head -1)
  mode=$(printf '%s\n' "$result" | tail -n +2)

  # Handle shortcuts
  case "$key" in
    ctrl-f) mode=">> Forced (full auto)" ;;
    ctrl-a) mode="?> Ask (confirm actions)" ;;
    ctrl-p) mode="## Plan (plan first)" ;;
  esac

  case "$mode" in
    *"Forced"*)
      echo "forced"
      ;;
    *"Ask"*)
      echo "ask"
      ;;
    *"Plan"*)
      echo "plan"
      ;;
    *)
      echo ""
      ;;
  esac
}

# =============================================================================
# Menu Review PR
# =============================================================================

select_pr_action() {
  local pr_num="$1"
  local ci_failed="$2"
  local pr_term=$(get_pr_term)

  local options="Review this $pr_term
Launch Claude
Just create worktree"

  # "Fix CI issues" (and its ^F shortcut) only exists when CI has failed
  local shortcuts="^R review · ^L claude · ^W worktree"
  local expect="ctrl-r,ctrl-l,ctrl-w"
  if [[ "$ci_failed" == "true" ]]; then
    options="Fix CI issues (auto)
$options"
    shortcuts="^F fix CI · $shortcuts"
    expect="ctrl-f,$expect"
  fi

  local header="${C_BOLD}$pr_term $(format_pr_ref "$pr_num")${C_RESET}  ${C_DIM}$shortcuts${C_RESET}"

  local result
  result=$(wt_fzf --height=30% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --expect="$expect" \
        --preview="
          case {} in
            *Fix\ CI*)
              echo 'AUTO-FIX CI FAILURES'
              echo ''
              echo 'Claude will automatically:'
              echo '  1. Fetch failed CI logs'
              echo '  2. Analyze the errors'
              echo '  3. Fix the code'
              echo '  4. Push the fix'
              echo ''
              echo '!! Runs in FORCED mode (full auto)'
              ;;
            *Review*)
              echo 'Code review mode'
              echo ''
              echo 'Claude will analyze the $pr_term for:'
              echo '  - Bugs and logic errors'
              echo '  - Security issues'
              echo '  - Performance problems'
              echo '  - Code quality'
              ;;
            *Launch*)
              echo 'Work on this $pr_term'
              echo ''
              echo 'Claude will help you:'
              echo '  - Understand the changes'
              echo '  - Make modifications'
              echo '  - Fix issues'
              ;;
            *Just*)
              echo 'Create worktree only'
              echo ''
              echo 'No Claude integration.'
              echo 'Just checkout the $pr_term branch.'
              ;;
          esac
        " \
        --preview-window=right:50% <<< "$options")

  local key action
  key=$(printf '%s\n' "$result" | head -1)
  action=$(printf '%s\n' "$result" | tail -n +2)

  # Handle shortcuts
  case "$key" in
    ctrl-f) [[ "$ci_failed" == "true" ]] && action="Fix CI issues (auto)" ;;
    ctrl-r) action="Review this $pr_term" ;;
    ctrl-l) action="Launch Claude" ;;
    ctrl-w) action="Just create worktree" ;;
  esac

  echo "$action"
}

menu_review_pr() {
  if ! has_cli; then
    setup_cli_auth
    if ! has_cli; then
      return 1
    fi
  fi

  local pr_term=$(get_pr_term)
  local prs errfile rc
  errfile=$(mktemp)
  prs=$(ui_spin_fn "Fetching ${pr_term}s..." _menus_quiet "$errfile" get_formatted_prs)
  rc=$?
  [[ -s "$errfile" ]] && cat "$errfile" >&2
  rm -f "$errfile"
  if [[ $rc -ne 0 || -z "$prs" ]]; then
    msg ""
    if [[ $rc -ne 0 ]]; then
      msg_error "Could not list ${pr_term}s"
    else
      msg "No open ${pr_term}s found."
    fi
    msg "Press Enter to continue..."
    read -r </dev/tty
    return 1
  fi

  # Boucle pour permettre Ctrl+O sans quitter
  local header="${C_BOLD}Open ${pr_term}s${C_RESET}"
  local footer="Enter select · ^O browser"
  while true; do
    local result
    result=$(printf '%s\n' "$prs" | \
      wt_fzf --height=70% \
          --layout=reverse \
          --border \
          --ansi \
          --header="$header" \
          --footer="$footer" \
          --delimiter='\t' \
          --with-nth=1,2,3,4 \
          --preview="bash \"$SCRIPT_PATH\" --pr-preview {1}" \
          --preview-window=right:50% \
          --expect=ctrl-o)

    local key selected
    key=$(printf '%s\n' "$result" | head -1)
    selected=$(printf '%s\n' "$result" | tail -n +2)

    if [[ -z "$selected" ]]; then
      return 1
    fi

    # Fields: ref | CI+review | title | @author | head branch | cross-repo | CI state
    local pr_num pr_branch pr_cross pr_ci
    pr_num=$(printf '%s\n' "$selected" | cut -f1 | tr -cd '0-9')
    pr_branch=$(printf '%s\n' "$selected" | cut -f5)
    pr_cross=$(printf '%s\n' "$selected" | cut -f6)
    pr_ci=$(printf '%s\n' "$selected" | cut -f7)
    local ci_failed="false"
    [[ "$pr_ci" == "fail" ]] && ci_failed="true"

    if [[ "$key" == "ctrl-o" ]]; then
      cli_open_pr_in_browser "$pr_num"
      continue
    fi

    local claude_ok="false"
    has_claude && claude_ok="true"

    while true; do
      # Select action (pass CI status)
      local action
      action=$(select_pr_action "$pr_num" "$ci_failed")
      [[ -z "$action" ]] && break  # Back to PR list

      # Pick the Claude mode before creating anything: Esc here goes back
      # to the action list without leaving a worktree behind
      local mode=""
      if [[ "$claude_ok" == "true" ]]; then
        case "$action" in
          *"Review"*)
            mode=$(select_claude_mode "pr-review" "$pr_num")
            [[ -z "$mode" ]] && continue
            ;;
          *"Launch"*)
            mode=$(select_claude_mode "pr-work" "$pr_num")
            [[ -z "$mode" ]] && continue
            ;;
        esac
        # A fork PR is untrusted code: full auto mode only on confirmation
        if [[ "$pr_cross" == "1" ]] && [[ "$action" == *"Fix CI"* || "$mode" == "forced" ]]; then
          ui_warn "$pr_term $(format_pr_ref "$pr_num") comes from a fork: its code and content are not trusted"
          ui_confirm "Run Claude in full auto mode on it anyway?" || continue
        fi
      fi

      # Create worktree
      local wt_path ret
      wt_path=$(create_from_pr "$pr_branch" "$pr_num" "${pr_cross:-0}")
      ret=$?

      if [[ $ret -eq 0 && -n "$wt_path" ]]; then
        case "$action" in
          *"Fix CI"*)
            if [[ "$claude_ok" == "true" ]]; then
              echo "CLAUDE:ci-fix:$pr_num"
            else
              msg_warn "Claude not installed - skipping auto-fix"
            fi
            ;;
          *"Review"*)
            if [[ -n "$mode" ]]; then
              echo "CLAUDE:pr-review:$pr_num:$mode"
            else
              msg_warn "Claude not installed - skipping review"
            fi
            ;;
          *"Launch"*)
            if [[ -n "$mode" ]]; then
              echo "CLAUDE:pr-work:$pr_num:$mode"
            else
              msg_warn "Claude not installed"
            fi
            ;;
        esac
        echo "$wt_path"
      fi
      return $ret
    done
  done
}

# =============================================================================
# Menu From Issue
# =============================================================================

select_issue_action() {
  local issue_num="$1"

  local options="Auto-resolve (full auto)
Launch Claude
Just create worktree"

  # Shown inside single quotes in the preview below
  local branch_prefix="${WT_FEATURE_PREFIX:-feature/}"
  local sq="'\\''"
  branch_prefix="${branch_prefix//\'/$sq}"

  local header="${C_BOLD}Issue #$issue_num${C_RESET}"
  local footer="^A auto · ^L claude · ^W worktree"

  local result
  result=$(wt_fzf --height=25% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --footer="$footer" \
        --expect=ctrl-a,ctrl-l,ctrl-w \
        --preview="
          case {} in
            *Auto-resolve*)
              echo 'Full autonomous mode'
              echo ''
              echo 'Claude will automatically:'
              echo '  1. Read and analyze the issue'
              echo '  2. Explore the codebase'
              echo '  3. Plan the implementation'
              echo '  4. Write the code'
              echo '  5. Create a $(get_pr_term)'
              echo ''
              echo '!! No human intervention required'
              ;;
            *Launch*)
              echo 'Interactive mode'
              echo ''
              echo 'Claude will help you:'
              echo '  - Understand the issue'
              echo '  - Plan implementation'
              echo '  - Write code with guidance'
              echo ''
              echo 'You choose the level of autonomy.'
              ;;
            *Just*)
              echo 'Create worktree only'
              echo ''
              echo 'No Claude integration.'
              echo 'Branch: ${branch_prefix}{issue}-{title}'
              ;;
          esac
        " \
        --preview-window=right:50% <<< "$options")

  local key action
  key=$(printf '%s\n' "$result" | head -1)
  action=$(printf '%s\n' "$result" | tail -n +2)

  # Handle shortcuts
  case "$key" in
    ctrl-a) action="Auto-resolve (full auto)" ;;
    ctrl-l) action="Launch Claude" ;;
    ctrl-w) action="Just create worktree" ;;
  esac

  echo "$action"
}

menu_from_issue() {
  if ! has_cli; then
    setup_cli_auth
    if ! has_cli; then
      return 1
    fi
  fi

  local issues errfile rc
  errfile=$(mktemp)
  issues=$(ui_spin_fn "Fetching issues..." _menus_quiet "$errfile" get_formatted_issues)
  rc=$?
  [[ -s "$errfile" ]] && cat "$errfile" >&2
  rm -f "$errfile"
  if [[ $rc -ne 0 || -z "$issues" ]]; then
    msg ""
    if [[ $rc -ne 0 ]]; then
      msg_error "Could not list issues"
    else
      msg "No open issues found."
    fi
    msg "Press Enter to continue..."
    read -r </dev/tty
    return 1
  fi

  # Boucle pour permettre Ctrl+O sans quitter
  local header="${C_BOLD}Open Issues${C_RESET}"
  local footer="Enter select · ^O browser"
  while true; do
    local result
    result=$(printf '%s\n' "$issues" | \
      wt_fzf --height=70% \
          --layout=reverse \
          --border \
          --ansi \
          --header="$header" \
          --footer="$footer" \
          --delimiter='\t' \
          --with-nth=1,2,3,4 \
          --preview="bash \"$SCRIPT_PATH\" --issue-preview {1}" \
          --preview-window=right:50% \
          --expect=ctrl-o)

    local key selected
    key=$(printf '%s\n' "$result" | head -1)
    selected=$(printf '%s\n' "$result" | tail -n +2)

    if [[ -z "$selected" ]]; then
      return 1
    fi

    local issue_num issue_title
    issue_num=$(printf '%s\n' "$selected" | cut -f1 | tr -cd '0-9')
    issue_title=$(printf '%s\n' "$selected" | cut -f2)

    if [[ "$key" == "ctrl-o" ]]; then
      cli_open_issue_in_browser "$issue_num"
      continue
    fi

    local claude_ok="false"
    has_claude && claude_ok="true"

    while true; do
      # Select action
      local action
      action=$(select_issue_action "$issue_num")
      [[ -z "$action" ]] && break  # Back to issue list

      # Pick the Claude mode before creating the worktree (Esc = back)
      local mode=""
      if [[ "$claude_ok" == "true" && "$action" == *"Launch"* ]]; then
        mode=$(select_claude_mode "issue-work" "$issue_num")
        [[ -z "$mode" ]] && continue
      fi

      # Create worktree
      local wt_path ret
      wt_path=$(create_from_issue "$issue_num" "$issue_title")
      ret=$?

      if [[ $ret -eq 0 && -n "$wt_path" ]]; then
        case "$action" in
          *"Auto-resolve"*)
            if [[ "$claude_ok" == "true" ]]; then
              echo "CLAUDE:issue-auto:$issue_num"
            else
              msg_warn "Claude not installed - skipping auto-resolve"
            fi
            ;;
          *"Launch"*)
            if [[ -n "$mode" ]]; then
              echo "CLAUDE:issue-work:$issue_num:$mode"
            else
              msg_warn "Claude not installed"
            fi
            ;;
        esac
        echo "$wt_path"
      fi
      return $ret
    done
  done
}

# =============================================================================
# Menu Créer un worktree
# =============================================================================

menu_create_worktree() {
  while true; do
    local pr_term=$(get_pr_term)
    local pr_term_lower=$(echo "$pr_term" | tr '[:upper:]' '[:lower:]')
    local header="${C_BOLD}Create a worktree${C_RESET}"
    local footer="^N new · ^B branch · ^T current · ^G issue · ^P $pr_term_lower"

    # Ctrl+C, Esc and Tab keep their fzf meaning (cancel / nothing):
    # they are never part of --expect
    local result
    result=$(printf "%s\n" \
      "New branch" \
      "From existing branch" \
      "From current (quick copy)" \
      "From an issue" \
      "Review a $pr_term" \
      "Back" | \
      wt_fzf --height=40% \
          --layout=reverse \
          --border \
          --ansi \
          --header="$header" \
          --footer="$footer" \
          --expect=ctrl-n,ctrl-b,ctrl-t,ctrl-g,ctrl-p)

    local key choice
    key=$(printf '%s\n' "$result" | head -1)
    choice=$(printf '%s\n' "$result" | tail -n +2)

    # Handle shortcuts
    case "$key" in
      ctrl-n) choice="New branch" ;;
      ctrl-b) choice="From existing branch" ;;
      ctrl-t) choice="From current (quick copy)" ;;
      ctrl-g) choice="From an issue" ;;
      ctrl-p) choice="Review a $pr_term" ;;
    esac

    # Each step prints the worktree path (and maybe a CLAUDE marker) on
    # success. When it is cancelled or fails, come back to this menu.
    local output ret
    case "$choice" in
      "New branch"*)
        output=$(create_new_branch)
        ;;
      "From existing"*)
        output=$(create_from_branch)
        ;;
      *"current"*|*"quick copy"*)
        output=$(create_from_current)
        ;;
      "From an issue"*)
        output=$(menu_from_issue)
        ;;
      "Review a"*)
        output=$(menu_review_pr)
        ;;
      *"Back"*|"")
        return 1
        ;;
      *)
        continue
        ;;
    esac
    ret=$?

    if [[ $ret -eq 0 && -n "$output" ]]; then
      echo "$output"
      return 0
    fi
  done
}

# =============================================================================
# Actions de suppression - retournent le repo principal pour y naviguer
# =============================================================================

# True when <path> is a locked worktree in `git worktree list --porcelain`
# output; prints the lock reason (may be empty)
_menus_worktree_locked() {
  local porcelain="$1"
  local path="$2"
  printf '%s\n' "$porcelain" | WT_LOCK_PATH="worktree $path" awk '
    $0 == ENVIRON["WT_LOCK_PATH"] { f = 1; next }
    /^worktree / { f = 0 }
    f && /^locked/ { x = 1; sub(/^locked ?/, ""); print }
    END { exit !x }'
}

# True when deleting branch <b> loses no work: merged in the default branch
# (is_branch_merged, a branch without commits of its own included), or a
# temp/* quick copy whose commits are all on another branch
_menus_branch_disposable() {
  local b="$1" tip
  is_branch_merged "$b" && return 0
  [[ "$b" == temp/* ]] || return 1
  tip=$(git -C "$MAIN_REPO" rev-parse -q --verify "refs/heads/$b^{commit}" 2>/dev/null) || return 1
  git -C "$MAIN_REPO" for-each-ref --contains "$tip" --format='%(refname)' refs/heads refs/remotes 2>/dev/null \
    | grep -qvxF "refs/heads/$b"
}

# After a deletion: offer to delete the branches of the removed worktrees that
# hold no work of their own (they pile up otherwise, temp/* above all)
_menus_offer_branch_cleanup() {
  local b disposable=()
  for b in "$@"; do
    [[ -n "$b" ]] || continue
    git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$b" || continue
    _menus_branch_disposable "$b" && disposable+=("$b")
  done
  [[ ${#disposable[@]} -gt 0 ]] || return 0

  msg ""
  msg "Branches with no unmerged work left:"
  for b in "${disposable[@]}"; do
    msg "  $b"
  done
  ui_confirm "Also delete ${#disposable[@]} branch(es)?" || return 0
  for b in "${disposable[@]}"; do
    if git -C "$MAIN_REPO" branch -D "$b" >/dev/null 2>&1; then
      msg "Deleted branch: $b"
    else
      msg_warn "Could not delete branch: $b"
    fi
  done
}

action_delete_worktrees() {
  local worktrees
  worktrees=$(get_secondary_worktrees)

  if [[ -z "$worktrees" ]]; then
    msg "No secondary worktree to delete"
    return 1
  fi

  # Build formatted list
  local tmpfile wt
  tmpfile=$(mktemp)
  while IFS= read -r wt; do
    format_worktree_line "$wt"
  done <<< "$worktrees" > "$tmpfile"

  # Multi-select with Space, confirm with Enter
  local header="${C_BOLD}Delete worktree(s)${C_RESET}"
  local footer="Space select · ^A all · Enter confirm"
  local selected
  selected=$(wt_fzf --height=60% \
        --layout=reverse \
        --border \
        --ansi \
        --delimiter=$'\t' \
        --with-nth=1 \
        --multi \
        --marker='x ' \
        --bind 'space:toggle+down' \
        --bind 'ctrl-a:select-all' \
        --header="$header" \
        --footer="$footer" \
        --preview="bash \"$SCRIPT_PATH\" --worktree-preview {2}" \
        --preview-window=right:50% < "$tmpfile")

  rm -f "$tmpfile"

  if [[ -z "$selected" ]]; then
    return 1
  fi

  # Field 2 is the absolute worktree path. Locked worktrees are left alone:
  # the lock is a deliberate "do not remove" from the user.
  local porcelain
  porcelain=$(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null)
  local to_delete=()
  local locked_list=""
  local dirty_list=""
  local dirty_count=0
  local line path lock_reason
  while IFS= read -r line; do
    path=$(printf '%s\n' "$line" | cut -f2)
    [[ -z "$path" ]] && continue
    if lock_reason=$(_menus_worktree_locked "$porcelain" "$path"); then
      locked_list+="  $(_menus_tilde "$path")${lock_reason:+ ($lock_reason)}"$'\n'
      continue
    fi
    to_delete+=("$path")
    if [[ -d "$path" ]] && [[ -n $(git -C "$path" status --porcelain 2>/dev/null) ]]; then
      dirty_list+="  $(_menus_tilde "$path")"$'\n'
      dirty_count=$((dirty_count + 1))
    fi
  done <<< "$selected"

  if [[ -n "$locked_list" ]]; then
    ui_warn "Locked worktree(s) skipped, run 'git worktree unlock <path>' first:"
    msg "${locked_list%$'\n'}"
  fi

  local count=${#to_delete[@]}
  if [[ $count -eq 0 ]]; then
    msg "Press Enter to continue..."
    read -r </dev/tty
    return 1
  fi

  # Extra confirmation if dirty worktrees
  if [[ $dirty_count -gt 0 ]]; then
    ui_warn "$dirty_count worktree(s) have uncommitted changes"
    msg "${dirty_list%$'\n'}"
    ui_confirm "Delete anyway (lose changes)?" || { msg "Cancelled"; return 1; }
  fi

  # Final confirmation
  if ui_confirm "Delete $count worktree(s)?"; then
    # Branch of each worktree, read before it is removed
    local entries
    entries=$'\n'$(_wt_worktree_entries)
    local to_remove err removed_branches=() wt_branch
    for to_remove in "${to_delete[@]}"; do
      wt_branch="${entries#*$'\n'"$to_remove"$'\t'}"
      [[ "$wt_branch" == "$entries" ]] && wt_branch="" || wt_branch="${wt_branch%%$'\n'*}"
      # Try normal remove, then force (uncommitted changes, submodules)
      if git -C "$MAIN_REPO" worktree remove "$to_remove" 2>/dev/null; then
        msg "Deleted: $to_remove"
      elif err=$(git -C "$MAIN_REPO" worktree remove --force "$to_remove" 2>&1 >/dev/null); then
        msg "Deleted (forced): $to_remove"
      elif [[ ! -e "$to_remove" ]]; then
        # Directory already gone: the prune below drops the stale entry
        msg "Already gone: $to_remove"
      elif [[ "$to_remove" != "$MAIN_REPO" && -f "$to_remove/.git" ]] && rm -rf "$to_remove"; then
        # Last resort for a linked worktree git refuses to remove
        msg "Deleted (manual): $to_remove"
      else
        ui_error "Could not delete: $to_remove"
        [[ -n "$err" ]] && msg "$err"
        continue
      fi
      removed_branches+=("$wt_branch")
    done
    # Always prune from main repo to clean up any stale references
    git -C "$MAIN_REPO" worktree prune 2>/dev/null
    _menus_offer_branch_cleanup ${removed_branches[@]+"${removed_branches[@]}"}
    msg "Done"
    # Return to main repo
    echo "$MAIN_REPO"
  else
    msg "Cancelled"
    return 1
  fi
}

# =============================================================================
# First-time Preferences Wizard
# =============================================================================

# One row of the wizard summary box: 12-column label, value padded to the frame
_wizard_box_row() {
  local label="$1"
  local value="$2"
  local width=24
  if [[ ${#value} -gt $width ]]; then
    value="...${value:$(( ${#value} - width + 3 ))}"
  fi
  msg "  ║  $(printf '%-12s' "$label")${value}$(printf '%*s' $(( width - ${#value} )) '')║"
}

# Ask for the editor and the platform. Only these two keys are written, and
# only when answered (^S / Esc keep the current value); the other keys are
# added with their default when missing. Nothing is ever removed.
# --standalone: called on its own (wt --wizard, Settings reset), so it does
# not announce that the main menu is starting.
run_preferences_wizard() {
  local standalone=false
  [[ "${1:-}" == "--standalone" ]] && standalone=true

  msg ""
  msg "  ${C_BOLD}Let's configure wt${C_RESET} in 2 quick steps."
  msg "  ${C_DIM}(Press ^S to skip any step)${C_RESET}"
  msg ""

  # Detect available editors
  local available_editors=()
  command -v cursor &>/dev/null && available_editors+=("cursor")
  command -v code &>/dev/null && available_editors+=("code")
  command -v nvim &>/dev/null && available_editors+=("nvim")
  command -v vim &>/dev/null && available_editors+=("vim")
  # Always offer custom
  available_editors+=("custom...")

  # Step 1: IDE
  local header_step1="${C_BOLD}Step 1/2 - Preferred editor${C_RESET}"
  local footer_step1="^S skip"
  local ide_result
  ide_result=$(printf '%s\n' "${available_editors[@]}" | \
    wt_fzf --height=40% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header_step1" \
        --footer="$footer_step1" \
        --expect=ctrl-s \
        --preview='
          case {} in
            cursor*) echo "Cursor"
                     echo ""
                     echo "VS Code based editor with AI features"
                     ;;
            code*)   echo "Visual Studio Code"
                     echo ""
                     echo "Microsoft'"'"'s open-source editor"
                     ;;
            nvim*)   echo "Neovim"
                     echo ""
                     echo "Hyperextensible Vim-based editor"
                     ;;
            vim*)    echo "Vim"
                     echo ""
                     echo "Classic terminal editor"
                     ;;
            custom*) echo "Custom editor"
                     echo ""
                     echo "Enter your editor command"
                     echo "(e.g. emacs, nano, subl)"
                     ;;
          esac
          echo ""
          echo "Used when pressing Ctrl+E"
          echo "in the worktree menu."
        ' \
        --preview-window=right:40%)

  local ide_key ide_choice
  ide_key=$(printf '%s\n' "$ide_result" | head -1)
  ide_choice=$(printf '%s\n' "$ide_result" | tail -n +2)
  # Strip ANSI codes and take first word
  ide_choice=$(printf '%s\n' "$ide_choice" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $1}')

  local selected_editor=""
  local editor_answered=false
  if [[ "$ide_key" != "ctrl-s" && -n "$ide_choice" ]]; then
    if [[ "$ide_choice" == "custom..." ]]; then
      if selected_editor=$(ui_input "Editor command:" "emacs, nano, subl..." "${WT_EDITOR:-}") \
         && [[ -n "$selected_editor" ]]; then
        editor_answered=true
      fi
    else
      selected_editor="$ide_choice"
      editor_answered=true
    fi
  fi

  # Step 2: Platform
  local header_step2="${C_BOLD}Step 2/2 - Git platform${C_RESET}"
  local footer_step2="^S skip"
  # Same rule as detect_platform: only the host of the remote counts
  local current_remote_guess="github"
  case "$(_wt_remote_host)" in
    *gitlab*) current_remote_guess="gitlab" ;;
  esac

  local platform_result
  platform_result=$(printf '%s\n' \
    "auto" \
    "github" \
    "gitlab" | \
    wt_fzf --height=30% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header_step2" \
        --footer="$footer_step2" \
        --expect=ctrl-s \
        --preview="
          case {} in
            auto*)
              echo 'auto (recommended)'
              echo ''
              echo 'Reads your git remote URL'
              echo 'to detect GitHub vs GitLab.'
              echo ''
              echo \"Detected for this repo: $current_remote_guess\"
              ;;
            github*)
              echo 'GitHub'
              echo ''
              echo 'Forces GitHub mode.'
              echo 'Uses: gh CLI'
              ;;
            gitlab*)
              echo 'GitLab'
              echo ''
              echo 'Forces GitLab mode.'
              echo 'Uses: glab CLI'
              ;;
          esac
        " \
        --preview-window=right:40%)

  local platform_key platform_choice
  platform_key=$(printf '%s\n' "$platform_result" | head -1)
  platform_choice=$(printf '%s\n' "$platform_result" | tail -n +2 | awk '{print $1}')

  local selected_platform=""
  local platform_answered=false
  if [[ "$platform_key" != "ctrl-s" && -n "$platform_choice" ]]; then
    selected_platform="$platform_choice"
    platform_answered=true
  fi

  # Write config: answered steps, then defaults for the missing keys only
  [[ "$editor_answered" == "true" ]] && save_config_value "WT_EDITOR" "$selected_editor"
  [[ "$platform_answered" == "true" ]] && save_config_value "WT_PLATFORM" "$selected_platform"
  local kv key
  for kv in "WT_EDITOR=" "WT_PLATFORM=auto" "WT_WORKTREE_DIR=" "WT_AUTO_CD=true" \
            "WT_FEATURE_PREFIX=feature/" "WT_AUTO_FETCH=true" "WT_CLAUDE_MODE=" \
            "WT_LIST_LIMIT=20"; do
    key="${kv%%=*}"
    grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$WT_CONFIG_FILE" 2>/dev/null \
      || save_config_value "$key" "${kv#*=}"
  done

  # Reload, and make this session follow what was just chosen
  load_config
  [[ "$editor_answered" == "true" ]] && export WT_EDITOR="$selected_editor"
  [[ "$platform_answered" == "true" ]] && export WT_PLATFORM="$selected_platform"
  if [[ -n "${MAIN_REPO:-}" ]]; then
    _WT_PLATFORM=""
    _WT_PLATFORM=$(detect_platform)
    export _WT_PLATFORM
  fi

  # Success screen
  msg ""
  msg "  ╔══════════════════════════════════════╗"
  msg "  ║  ${C_GREEN}✓${C_RESET}  wt is configured                 ║"
  msg "  ╠══════════════════════════════════════╣"
  msg "  ║                                      ║"
  _wizard_box_row "IDE" "${WT_EDITOR:-auto-detect}"
  _wizard_box_row "Platform" "${WT_PLATFORM:-auto}"
  msg "  ║                                      ║"
  _wizard_box_row "Config" "$(_menus_tilde "$WT_CONFIG_FILE")"
  msg "  ║                                      ║"
  msg "  ║  Tip: wt > ⚙ Settings to change      ║"
  msg "  ║                                      ║"
  msg "  ╚══════════════════════════════════════╝"
  msg ""
  if [[ "$standalone" != "true" ]]; then
    msg "  Launching wt..."
    msg ""
    sleep 1
  fi
}

# =============================================================================
# First-time Install Wizard
# =============================================================================

run_install_wizard() {
  print_logo

  # SCRIPT_PATH is the resolved wt.sh (set by wt.sh, symlinks followed)
  local script_path="${SCRIPT_PATH:-}"
  local init_line='command -v wt-core >/dev/null 2>&1 && eval "$(wt-core --shell-init)"'

  # Packaged installs are not symlinked by hand: a Nix store path can be
  # garbage-collected (and bypasses the wrapper's PATH), Homebrew links it
  local managed=""
  case "$script_path" in
    /nix/store/*) managed="nix" ;;
    */Cellar/*)   managed="brew" ;;
  esac

  # Detect what needs to be installed
  local needs_symlink=false
  local needs_rc=false
  local install_dir="/usr/local/bin"
  if [[ -z "$managed" && -n "$script_path" ]] && ! command -v wt-core >/dev/null 2>&1; then
    needs_symlink=true
    if [[ ! -d "/usr/local/bin" || ! -w "/usr/local/bin" ]]; then
      install_dir="${HOME}/.local/bin"
    fi
  fi

  # The wt shell function is bash/zsh only: other shells get instructions
  local shell_name rc_file=""
  shell_name=$(basename "${SHELL:-sh}")
  case "$shell_name" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash) rc_file="$HOME/.bashrc" ;;
  esac

  if [[ -z "$managed" && -n "$rc_file" ]] && ! grep -q "wt-core --shell-init" "$rc_file" 2>/dev/null; then
    needs_rc=true
  fi

  if [[ "$managed" == "nix" ]]; then
    msg "  ${C_BOLD}wt${C_RESET} is running from the Nix store, wt-core is not installed."
    msg "  Install it with: ${C_CYAN}nix profile install github:AThevon/worktigre${C_RESET}"
    msg "  (or add it to your flake / home-manager packages)"
    msg ""
  elif [[ "$managed" == "brew" ]]; then
    msg "  ${C_BOLD}wt-core${C_RESET} is installed by Homebrew but is not in your PATH."
    msg "  Add Homebrew to your PATH: ${C_CYAN}eval \"\$(brew shellenv)\"${C_RESET}"
    msg ""
  fi
  if [[ -n "$managed" && -n "$rc_file" ]] && ! grep -q "wt-core --shell-init" "$rc_file" 2>/dev/null; then
    msg "  Then add this line to ${C_CYAN}${rc_file}${C_RESET}:"
    msg "    $init_line"
    msg ""
  fi
  if [[ -z "$rc_file" ]]; then
    msg "  ${C_YELLOW}!${C_RESET} The ${C_BOLD}wt${C_RESET} shell function supports zsh and bash, not ${shell_name}."
    msg "  To use it from zsh or bash, add this line to ~/.zshrc or ~/.bashrc:"
    msg "    $init_line"
    msg ""
  fi

  # If nothing to install, skip to preferences
  if [[ "$needs_symlink" == "false" && "$needs_rc" == "false" ]]; then
    [[ -f "$WT_CONFIG_FILE" ]] || run_preferences_wizard
    return 0
  fi

  # Build what-will-happen list
  msg "  ${C_BOLD}wt${C_RESET} needs a quick one-time setup."
  msg "  This will:"
  msg ""
  [[ "$needs_symlink" == "true" ]] && msg "    ${C_DIM}→${C_RESET} Create symlink  ${C_CYAN}${install_dir}/wt-core${C_RESET} ${C_DIM}→ $(_menus_tilde "$script_path")${C_RESET}"
  [[ "$needs_rc" == "true" ]]      && msg "    ${C_DIM}→${C_RESET} Add init line   ${C_CYAN}${rc_file}${C_RESET}"
  msg ""

  local confirm_result
  confirm_result=$(printf '%s\n' \
    "Yes, set it up" \
    "No, skip for now" | \
    wt_fzf --height=15% \
        --layout=reverse \
        --border \
        --ansi \
        --no-sort \
        --header="${C_BOLD}Install now?${C_RESET}")

  if [[ "$confirm_result" != "Yes"* ]]; then
    msg ""
    msg "  Skipping install. Run: ${C_CYAN}$(_menus_tilde "$script_path") --setup${C_RESET} to install later."
    msg ""
    return 1
  fi

  # Perform installation
  local install_ok=true
  if [[ "$needs_symlink" == "true" ]]; then
    if mkdir -p "$install_dir" 2>/dev/null && ln -sf "$script_path" "${install_dir}/wt-core"; then
      msg "  ${C_GREEN}✓${C_RESET} Created: ${install_dir}/wt-core"
    else
      msg_error "Could not create ${install_dir}/wt-core"
      install_ok=false
    fi
  fi

  if [[ "$needs_rc" == "true" ]]; then
    if { echo ""; echo "# worktigre - Git Worktree Manager"; echo "$init_line"; } >> "$rc_file"; then
      msg "  ${C_GREEN}✓${C_RESET} Added init line to ${rc_file}"
    else
      msg_error "Could not write to ${rc_file}"
      install_ok=false
    fi
  fi

  # The init line only works if wt-core can be found when the shell starts
  local path_ok=true
  if [[ "$needs_symlink" == "true" && ":$PATH:" != *":$install_dir:"* ]]; then
    path_ok=false
    msg ""
    if [[ -n "$rc_file" ]]; then
      msg_warn "${install_dir} is not in your PATH. Add this line to ${rc_file}, above the worktigre line:"
    else
      msg_warn "${install_dir} is not in your PATH. Add it in your shell configuration:"
    fi
    msg ""
    msg "    export PATH=\"${install_dir}:\$PATH\""
  fi

  msg ""
  if [[ "$install_ok" != "true" ]]; then
    msg "  ${C_BOLD}Setup incomplete${C_RESET}, see the errors above."
  elif [[ "$path_ok" != "true" ]]; then
    msg "  ${C_BOLD}Almost done!${C_RESET} Fix your PATH as shown above, then restart your terminal."
  elif [[ -n "$rc_file" ]]; then
    msg "  ${C_BOLD}Installation complete!${C_RESET}"
    msg "  Run ${C_CYAN}source ${rc_file}${C_RESET} to activate (or restart your terminal)."
  else
    msg "  ${C_BOLD}Installation complete!${C_RESET}"
  fi
  msg ""
  sleep 1

  # Continue to preferences
  [[ -f "$WT_CONFIG_FILE" ]] || run_preferences_wizard
}

# =============================================================================
# Settings Menu
# =============================================================================

menu_settings() {
  while true; do
    # Read current values (live from variables, which were loaded from config)
    local cur_editor="${WT_EDITOR:-$(get_editor) (auto)}"
    local cur_platform="${WT_PLATFORM:-auto}"
    local cur_worktree_dir="${WT_WORKTREE_DIR:-default}"
    local cur_auto_cd="${WT_AUTO_CD:-true}"
    local cur_feature_prefix="${WT_FEATURE_PREFIX:-feature/}"
    local cur_auto_fetch="${WT_AUTO_FETCH:-true}"
    local cur_claude_mode="${WT_CLAUDE_MODE:-prompt each time}"
    local cur_list_limit="${WT_LIST_LIMIT:-20}"

    local header="${C_BOLD}⚙ Settings${C_RESET}"
    local footer="Enter to edit · ^R reset"

    local options
    options=$(printf '%s\n' \
      "IDE              ${C_CYAN}${cur_editor}${C_RESET}" \
      "Platform         ${C_CYAN}${cur_platform}${C_RESET}" \
      "Worktree dir     ${C_CYAN}${cur_worktree_dir}${C_RESET}" \
      "Auto-CD          ${C_CYAN}${cur_auto_cd}${C_RESET}" \
      "Feature prefix   ${C_CYAN}${cur_feature_prefix}${C_RESET}" \
      "Auto-fetch       ${C_CYAN}${cur_auto_fetch}${C_RESET}" \
      "Claude mode      ${C_CYAN}${cur_claude_mode}${C_RESET}" \
      "PR/Issue limit   ${C_CYAN}${cur_list_limit}${C_RESET}" \
      "──────────────────────────────────────" \
      "↺ Reset to defaults")

    local result
    result=$(printf '%s\n' "$options" | \
      wt_fzf --height=60% \
          --layout=reverse \
          --border \
          --ansi \
          --header="$header" \
          --footer="$footer" \
          --expect=ctrl-r \
          --preview='
            case {} in
              IDE*)
                echo "Preferred code editor"
                echo ""
                echo "Used when pressing Ctrl+E"
                echo "in the main worktree menu."
                echo ""
                echo "auto = detect cursor > code > $EDITOR > vim"
                ;;
              Platform*)
                echo "Git hosting platform"
                echo ""
                echo "auto   = detect from remote URL"
                echo "github = force GitHub (gh CLI)"
                echo "gitlab = force GitLab (glab CLI)"
                ;;
              Worktree*)
                echo "Base directory for new worktrees"
                echo ""
                echo "default = created next to main repo"
                echo "custom  = absolute path or ~/..., e.g. ~/worktrees"
                echo ""
                echo "Type \"default\" to go back to the default."
                ;;
              Auto-CD*)
                echo "Auto-navigate after worktree selection"
                echo ""
                echo "true  = cd to worktree on selection"
                echo "false = no automatic cd"
                ;;
              Feature*)
                echo "Branch prefix for issue worktrees"
                echo ""
                echo "Used when creating a worktree"
                echo "from a GitHub/GitLab issue."
                echo ""
                echo "Examples: feature/ feat/ task/"
                ;;
              Auto-fetch*)
                echo "Fetch before branch operations"
                echo ""
                echo "true  = git fetch --all before listing branches"
                echo "false = use cached branch list (faster offline)"
                ;;
              Claude*)
                echo "Default Claude launch mode"
                echo ""
                echo "prompt each time = show picker (default)"
                echo "forced  = --dangerously-skip-permissions"
                echo "ask     = interactive mode"
                echo "plan    = --permission-mode=plan"
                ;;
              PR*)
                echo "Max items in PR and issue lists"
                echo ""
                echo "Higher = more results, slower API call"
                echo "Lower  = fewer results, faster"
                ;;
              *Reset*)
                echo "Reset all settings to defaults"
                echo ""
                echo "Deletes your config file, then runs"
                echo "the setup wizard again."
                ;;
            esac
          ' \
          --preview-window=right:45%)

    local key selected
    key=$(printf '%s\n' "$result" | head -1)
    selected=$(printf '%s\n' "$result" | tail -n +2)
    # Strip ANSI and take first word to get the setting name
    selected=$(printf '%s\n' "$selected" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $1}')

    # Ctrl+R or ↺ Reset to defaults
    if [[ "$key" == "ctrl-r" ]] || [[ "$selected" == "↺" ]]; then
      local confirm
      confirm=$(printf '%s\n' "Yes, reset everything" "No, cancel" | \
        wt_fzf --height=15% --layout=reverse --border --ansi \
            --header="${C_BOLD}Reset all settings to defaults?${C_RESET}")
      if [[ "$confirm" == "Yes"* ]]; then
        rm -f "$WT_CONFIG_FILE"
        run_preferences_wizard --standalone
        load_config
        msg_success "Settings reset to defaults"
      fi
      continue
    fi

    # Exit on empty selection (Escape)
    [[ -z "$selected" ]] && return 0

    # Edit each setting based on first word of selection.
    # Esc in a text field (ui_input fails) never changes the stored value.
    case "$selected" in
      IDE)
        local editors=()
        command -v cursor &>/dev/null && editors+=("cursor")
        command -v code &>/dev/null && editors+=("code")
        command -v nvim &>/dev/null && editors+=("nvim")
        command -v vim &>/dev/null && editors+=("vim")
        editors+=("custom...")
        local choice
        choice=$(printf '%s\n' "${editors[@]}" | \
          wt_fzf --height=30% --layout=reverse --border --ansi \
              --header="${C_BOLD}Select IDE${C_RESET}")
        if [[ "$choice" == "custom..." ]]; then
          choice=$(ui_input "Editor command:" "emacs, nano, subl..." "${WT_EDITOR:-}") || continue
        fi
        if [[ -n "$choice" ]]; then
          save_config_value "WT_EDITOR" "$choice"
          export WT_EDITOR="$choice"
        fi
        ;;
      Platform)
        local choice
        choice=$(printf '%s\n' "auto" "github" "gitlab" | \
          wt_fzf --height=20% --layout=reverse --border --ansi \
              --header="${C_BOLD}Select platform${C_RESET}")
        if [[ -n "$choice" ]]; then
          save_config_value "WT_PLATFORM" "$choice"
          export WT_PLATFORM="$choice"
          # Drop the cached value so "auto" detects from the remote again
          _WT_PLATFORM=""
          _WT_PLATFORM=$(detect_platform)
          export _WT_PLATFORM
        fi
        ;;
      Worktree)
        local dir
        dir=$(ui_input "Worktree base directory:" "~/worktrees, or default" "${WT_WORKTREE_DIR:-}") || continue
        [[ -z "$dir" ]] && continue
        [[ "$dir" == "default" ]] && dir=""
        case "$dir" in
          ""|"~"|"~/"*|/*) ;;
          *)
            msg_warn "Not saved: use an absolute path or ~/... (a relative path would depend on where wt runs)"
            sleep 2
            continue
            ;;
        esac
        save_config_value "WT_WORKTREE_DIR" "$dir"
        export WT_WORKTREE_DIR="$dir"
        ;;
      Auto-CD)
        local choice
        choice=$(printf '%s\n' "true" "false" | \
          wt_fzf --height=15% --layout=reverse --border --ansi \
              --header="${C_BOLD}Auto-CD${C_RESET}")
        if [[ -n "$choice" ]]; then
          save_config_value "WT_AUTO_CD" "$choice"
          export WT_AUTO_CD="$choice"
        fi
        ;;
      Feature)
        local prefix
        prefix=$(ui_input "Feature prefix:" "feature/" "${WT_FEATURE_PREFIX:-}") || continue
        if [[ -n "$prefix" ]]; then
          save_config_value "WT_FEATURE_PREFIX" "$prefix"
          export WT_FEATURE_PREFIX="$prefix"
        fi
        ;;
      Auto-fetch)
        local choice
        choice=$(printf '%s\n' "true" "false" | \
          wt_fzf --height=15% --layout=reverse --border --ansi \
              --header="${C_BOLD}Auto-fetch${C_RESET}")
        if [[ -n "$choice" ]]; then
          save_config_value "WT_AUTO_FETCH" "$choice"
          export WT_AUTO_FETCH="$choice"
        fi
        ;;
      Claude)
        local choice
        choice=$(printf '%s\n' \
          "prompt each time" \
          "forced" \
          "ask" \
          "plan" | \
          wt_fzf --height=25% --layout=reverse --border --ansi \
              --header="${C_BOLD}Claude mode${C_RESET}")
        if [[ -n "$choice" ]]; then
          local mode_val=""
          case "$choice" in
            "forced"*) mode_val="forced" ;;
            "ask"*)    mode_val="ask" ;;
            "plan"*)   mode_val="plan" ;;
          esac
          save_config_value "WT_CLAUDE_MODE" "$mode_val"
          export WT_CLAUDE_MODE="$mode_val"
        fi
        ;;
      PR/Issue)
        local limit
        limit=$(ui_input "Max items in lists:" "20" "${WT_LIST_LIMIT:-}") || continue
        if [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
          save_config_value "WT_LIST_LIMIT" "$limit"
          export WT_LIST_LIMIT="$limit"
        elif [[ -n "$limit" ]]; then
          msg_warn "Not saved: enter a number >= 1"
          sleep 2
        fi
        ;;
      "──────────────────────────────────────")
        continue
        ;;
    esac
  done
}
