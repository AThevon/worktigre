#!/usr/bin/env bash
# lib/stash.sh - Stash management
#
# Contrat stdout: menu_stash n'écrit sur stdout que le chemin d'un worktree à
# ouvrir. Toutes les sorties git vont sur stderr, less et claude sur le TTY.
# Les stashes sont identifiés par leur sha: les index stash@{N} bougent à
# chaque push/drop, la ref est résolue juste avant chaque action.

# Chemin absolu de ce fichier: les previews fzf le re-sourcent pour appeler
# les mêmes fonctions que le menu
case "${BASH_SOURCE[0]}" in
  /*) _WT_STASH_LIB="${BASH_SOURCE[0]}" ;;
  *)  _WT_STASH_LIB="$PWD/${BASH_SOURCE[0]}" ;;
esac

# Raccourcis du menu stash, partagés par la liste et le sous-menu d'actions
# (--expect, aide '?', libellés et touches du sous-menu sont générés depuis
# cette table).
# Format: touche|affichage|action|portée|section de l'aide|libellé court|libellé
# Portée "stash" = action sur un stash (aussi dans le sous-menu), "global" =
# liste seulement. L'ordre est celui du sous-menu.
_STASH_KEYMAP='ctrl-a|^A|apply|stash|ACTIONS|apply|Apply (keep stash)
ctrl-p|^P|pop|stash|ACTIONS|pop|Pop (apply and remove)
ctrl-l|^L|claude|stash|ADVANCED|claude|Apply + resolve conflicts with Claude
ctrl-w|^W|worktree|stash|ADVANCED|wt|Create worktree from stash
ctrl-d|^D|drop|stash|ACTIONS|drop|Drop (delete)
ctrl-b|^B|branch|stash|ADVANCED|branch|Create branch from stash
ctrl-x|^X|export|stash|VIEW / EXPORT|export|Export as patch
ctrl-s|^S|show|stash|VIEW / EXPORT|show|Show full diff
ctrl-r|^R|rename|stash|ADVANCED|rename|Rename stash
ctrl-n|^N|new|global|CREATE|new|New stash (all changes)
ctrl-e|^E|partial|global|CREATE|partial|Partial stash (select files)'

# =============================================================================
# Stash Management - Keymap helpers
# =============================================================================

# Touches pour --expect: _stash_keys all|stash|global
_stash_keys() {
  local filter="$1" key hint action scope rest out=""
  while IFS='|' read -r key hint action scope rest; do
    [[ "$filter" != "all" && "$scope" != "$filter" ]] && continue
    out+="${out:+,}$key"
  done <<< "$_STASH_KEYMAP"
  printf '%s\n' "$out"
}

# Action associée à une touche fzf
_stash_key_action() {
  local want="$1" key hint action rest
  while IFS='|' read -r key hint action rest; do
    if [[ "$key" == "$want" ]]; then
      printf '%s\n' "$action"
      return 0
    fi
  done <<< "$_STASH_KEYMAP"
  return 1
}

# Footer "^A apply · ^P pop ..." pour les actions données
_stash_footer() {
  local a key hint action scope section short label out=""
  for a in "$@"; do
    while IFS='|' read -r key hint action scope section short label; do
      [[ "$action" == "$a" ]] && out+="${out:+ · }$hint $short"
    done <<< "$_STASH_KEYMAP"
  done
  printf '%s\n' "$out"
}

# Aide complète du raccourci '?'
_stash_help() {
  local bar="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local sec key hint action scope section short label underline i
  printf '%s\n  KEYBOARD SHORTCUTS\n%s\n' "$bar" "$bar"
  for sec in "ACTIONS" "CREATE" "ADVANCED" "VIEW / EXPORT"; do
    underline=""
    for ((i = 0; i < ${#sec}; i++)); do underline+="─"; done
    printf '\n  %s\n  %s\n' "$sec" "$underline"
    [[ "$sec" == "ACTIONS" ]] && printf '  %-9s %s\n' "Enter" "Open actions menu"
    while IFS='|' read -r key hint action scope section short label; do
      [[ "$section" == "$sec" ]] || continue
      [[ "$action" == "drop" ]] && label="${label%)}, multi-select)"
      printf '  %-9s %s\n' "Ctrl+${hint#^}" "$label"
    done <<< "$_STASH_KEYMAP"
  done
  printf '\n  SELECTION\n  ─────────\n'
  printf '  %-9s %s\n' "Space" "Toggle selection" "Esc" "Back / Cancel"
  printf '\n%s\n  Move the cursor to hide this help\n%s\n\n' "$bar" "$bar"
}

# =============================================================================
# Stash Management - Helper functions
# =============================================================================

# Âge lisible depuis un timestamp: _stash_age <epoch> [now] -> _STASH_AGE
_stash_age() {
  local ts="$1" now="${2:-}" diff
  [[ -n "$now" ]] || now=$(date +%s)
  if [[ ! "$ts" =~ ^[0-9]+$ ]]; then
    _STASH_AGE="?"
    return
  fi
  diff=$((now - ts))
  [[ $diff -lt 0 ]] && diff=0
  if [[ $diff -lt 3600 ]]; then
    _STASH_AGE="$((diff / 60))m"
  elif [[ $diff -lt 86400 ]]; then
    _STASH_AGE="$((diff / 3600))h"
  elif [[ $diff -lt 604800 ]]; then
    _STASH_AGE="$((diff / 86400))d"
  elif [[ $diff -lt 2592000 ]]; then
    _STASH_AGE="$((diff / 604800))w"
  else
    _STASH_AGE="$((diff / 2592000))mo"
  fi
}

# Découpe le sujet reflog d'un stash ("WIP on <branche>: ..." sans message,
# "On <branche>: <message>" avec -m) -> _STASH_BRANCH et _STASH_MSG.
# Un nom de branche ne contient jamais ':', on coupe donc au premier ': '.
_stash_split_subject() {
  local subj="$1" rest
  _STASH_BRANCH=""
  _STASH_MSG="$subj"
  case "$subj" in
    "WIP on "*) rest="${subj#WIP on }" ;;
    "On "*)     rest="${subj#On }" ;;
    *)          return ;;
  esac
  if [[ "$rest" == *": "* ]]; then
    _STASH_BRANCH="${rest%%: *}"
    _STASH_MSG="${rest#*: }"
  fi
}

# Retrouve un stash par son sha -> _STASH_REF (stash@{N}), _STASH_CT, _STASH_SUBJ
_stash_lookup() {
  local want="$1" ref sha ct subj
  [[ -n "$want" ]] || return 1
  while IFS=$'\t' read -r ref sha ct subj; do
    if [[ "$sha" == "$want" ]]; then
      _STASH_REF="$ref"
      _STASH_CT="$ct"
      _STASH_SUBJ="$subj"
      return 0
    fi
  done <<< "$(git stash list --format='%gd%x09%H%x09%ct%x09%gs' 2>/dev/null)"
  return 1
}

# Ref courante d'un stash, ou message d'erreur si la liste a changé
_stash_ref_of() {
  if _stash_lookup "$1"; then
    printf '%s\n' "$_STASH_REF"
    return 0
  fi
  msg_error "Stash not found (the stash list changed?)"
  return 1
}

# Lignes de $2 présentes dans $1 (sans fork, chemins pris littéralement)
_stash_common_lines() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case $'\n'"$1"$'\n' in
      *$'\n'"$line"$'\n'*) printf '%s\n' "$line" ;;
    esac
  done <<< "$2"
}

# Liste de chemins (une par ligne) jointe par ", "
_stash_join() {
  local line out=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && out+="${out:+, }$line"
  done <<< "$1"
  printf '%s\n' "$out"
}

# Liste de chemins affichée "  ! chemin" (preview)
_stash_print_files() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && printf '  ! %s\n' "$line"
  done <<< "$1"
}

# Nombre de fichiers (suivis + untracked) de chaque stash, une ligne par stash
# dans l'ordre de la liste. Une seule commande git pour tous les stashes.
# $1 = sortie de git stash list --format='%gd%x09%H%x09%P...'
_stash_file_counts() {
  local raw="$1" input="" owners="" i=0 ref sha parents rest p1 p3
  while IFS=$'\t' read -r ref sha parents rest; do
    [[ -n "$sha" ]] || continue
    read -r p1 _ p3 <<< "$parents"
    # "<commit> <parent>": diff du stash contre sa base. Le 3e parent (stash -u)
    # porte les fichiers untracked, comparé à l'arbre vide grâce à --root.
    input+="$sha $p1"$'\n'
    owners+="$i "
    if [[ -n "$p3" ]]; then
      input+="${p3%% *}"$'\n'
      owners+="$i "
    fi
    i=$((i + 1))
  done <<< "$raw"

  printf '%s' "$input" | \
    git diff-tree --stdin -r --root --always --name-only --format='%x01' 2>/dev/null | \
    awk -v owners="$owners" -v n="$i" '
      BEGIN { split(owners, o, " ") }
      index($0, "\001") == 1 { g++; next }
      NF { c[o[g]]++ }
      END { for (j = 0; j < n; j++) print c[j] + 0 }'
}

# Génère la liste formatée des stashes: "<affichage><TAB><sha>"
_format_stash_list() {
  local raw now
  raw=$(git stash list --format='%gd%x09%H%x09%P%x09%ct%x09%gs' 2>/dev/null)
  [[ -n "$raw" ]] || return 0
  now=$(date +%s)

  local -a counts=()
  local c
  while IFS= read -r c; do
    counts+=("$c")
  done <<< "$(_stash_file_counts "$raw")"

  local i=0 ref sha parents ct subj branch message
  while IFS=$'\t' read -r ref sha parents ct subj; do
    [[ -n "$sha" ]] || continue
    _stash_split_subject "$subj"
    _stash_age "$ct" "$now"
    branch="$_STASH_BRANCH"
    message="${_STASH_MSG//$'\t'/ }"

    # Tronquer la branche et le message si trop longs
    [[ ${#branch} -gt 12 ]] && branch="${branch:0:9}..."
    [[ ${#message} -gt 40 ]] && message="${message:0:37}..."

    # Format: stash@{0} │   3d │    5f │ main         │ message<TAB>sha
    printf '%-11s │ %4s │ %4sf │ %-12s │ %s\t%s\n' \
      "$ref" "$_STASH_AGE" "${counts[$i]:-?}" "$branch" "$message" "$sha"
    i=$((i + 1))
  done <<< "$raw"
}

# Conflits prévisibles avant d'appliquer un stash, une ligne par fichier:
#   blocked<TAB>fichier   git refusera l'apply: modif locale non stagée sur un
#                         fichier du stash, fichier untracked du stash déjà
#                         présent, ou conflit non résolu dans l'index
#   conflict<TAB>fichier  modifié par le stash ET depuis sa base (commits ou
#                         index): conflit probable à l'apply
_stash_conflicts() {
  local sha="$1" top base untracked f
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  base=$(git rev-parse -q --verify "${sha}^1" 2>/dev/null) || return 0

  local stash_files local_files moved unmerged blocked
  stash_files=$(git -C "$top" -c core.quotePath=false diff --no-renames --name-only "$base" "$sha" 2>/dev/null)
  local_files=$(git -C "$top" -c core.quotePath=false diff --no-renames --name-only 2>/dev/null)
  moved=$(git -C "$top" -c core.quotePath=false diff --no-renames --cached --name-only "$base" 2>/dev/null)
  unmerged=$(git -C "$top" -c core.quotePath=false diff --name-only --diff-filter=U 2>/dev/null)

  blocked=$(_stash_common_lines "$local_files" "$stash_files")
  # Un conflit non résolu bloque tout apply, même hors des fichiers du stash
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case $'\n'"$blocked"$'\n' in
      *$'\n'"$f"$'\n'*) ;;
      *) blocked+="${blocked:+$'\n'}$f" ;;
    esac
  done <<< "$unmerged"

  untracked=$(git rev-parse -q --verify "${sha}^3" 2>/dev/null)
  if [[ -n "$untracked" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      [[ -e "$top/$f" || -L "$top/$f" ]] && blocked+="${blocked:+$'\n'}$f"
    done <<< "$(git -C "$top" -c core.quotePath=false ls-tree -r --name-only "$untracked" 2>/dev/null)"
  fi

  while IFS= read -r f; do
    [[ -n "$f" ]] && printf 'blocked\t%s\n' "$f"
  done <<< "$blocked"

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case $'\n'"$blocked"$'\n' in
      *$'\n'"$f"$'\n'*) continue ;;
    esac
    printf 'conflict\t%s\n' "$f"
  done <<< "$(_stash_common_lines "$moved" "$stash_files")"
}

# Fichiers d'un type ("blocked" ou "conflict") dans la sortie de _stash_conflicts
_stash_conflict_files() {
  local kind="$1" k f
  while IFS=$'\t' read -r k f; do
    [[ "$k" == "$kind" ]] && printf '%s\n' "$f"
  done <<< "$2"
}

# Patch complet d'un stash (fichiers suivis + untracked) sur stdout.
# Les options restantes sont passées à git diff (--color, --binary...).
_stash_patch() {
  local sha="$1"
  shift
  local base untracked
  base=$(git rev-parse -q --verify "${sha}^1" 2>/dev/null) || return 1
  git diff "$@" "$base" "$sha" || return 1
  untracked=$(git rev-parse -q --verify "${sha}^3" 2>/dev/null)
  if [[ -n "$untracked" ]]; then
    git diff-tree -p -r --root --no-commit-id "$@" "$untracked" || return 1
  fi
}

# Dossier d'export des patchs: hors du working tree, pour qu'un patch ne soit
# ni vu comme untracked ni avalé par le prochain stash -u
_stash_export_dir() {
  if [[ -d "$HOME/Downloads" && -w "$HOME/Downloads" ]]; then
    printf '%s\n' "$HOME/Downloads"
  else
    local tmp="${TMPDIR:-/tmp}"
    printf '%s\n' "${tmp%/}"
  fi
}

# Preview d'un stash dans la liste (lancée par fzf via re-source de ce fichier)
_stash_preview() {
  local sha="$1"
  [[ -n "$sha" ]] || return 0
  if ! _stash_lookup "$sha"; then
    echo "Stash not found (the stash list changed?)"
    return 0
  fi
  local top base untracked date base_info
  top=$(git rev-parse --show-toplevel 2>/dev/null)
  base=$(git rev-parse -q --verify "${sha}^1" 2>/dev/null)
  untracked=$(git rev-parse -q --verify "${sha}^3" 2>/dev/null)
  date=$(git log -1 --format='%ci' "$sha" 2>/dev/null)
  base_info=$(git log -1 --format='%h %s' "$base" 2>/dev/null)
  _stash_split_subject "$_STASH_SUBJ"
  _stash_age "$_STASH_CT"

  local tracked_stat untracked_stat
  tracked_stat=$(git -C "$top" -c core.quotePath=false diff --numstat "$base" "$sha" 2>/dev/null)
  if [[ -n "$untracked" ]]; then
    untracked_stat=$(git -C "$top" -c core.quotePath=false diff-tree -r --root --numstat --no-commit-id "$untracked" 2>/dev/null)
  fi

  local files=0 nu=0 ins=0 del=0 added removed file
  while IFS=$'\t' read -r added removed file; do
    [[ -n "$file" ]] || continue
    files=$((files + 1))
    [[ "$added" =~ ^[0-9]+$ ]] && ins=$((ins + added))
    [[ "$removed" =~ ^[0-9]+$ ]] && del=$((del + removed))
  done <<< "$tracked_stat"
  while IFS=$'\t' read -r added removed file; do
    [[ -n "$file" ]] || continue
    nu=$((nu + 1))
    [[ "$added" =~ ^[0-9]+$ ]] && ins=$((ins + added))
  done <<< "$untracked_stat"

  local bar="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$bar"
  echo "  STASH INFO"
  echo "$bar"
  echo ""
  echo "  Ref     : $_STASH_REF"
  echo "  Date    : ${date:0:16} ($_STASH_AGE ago)"
  echo "  Branch  : ${_STASH_BRANCH:--}"
  echo "  Message : $_STASH_MSG"
  echo "  Base    : $base_info"
  if [[ $nu -gt 0 ]]; then
    echo "  Stats   : $((files + nu)) files ($nu untracked) | +$ins -$del lines"
  else
    echo "  Stats   : $files files | +$ins -$del lines"
  fi
  echo ""

  local conflicts blocked likely
  conflicts=$(_stash_conflicts "$sha")
  blocked=$(_stash_conflict_files blocked "$conflicts")
  likely=$(_stash_conflict_files conflict "$conflicts")
  if [[ -n "$blocked" ]]; then
    echo "$bar"
    echo "  ⚠ APPLY BLOCKED BY LOCAL CHANGES"
    echo "$bar"
    echo ""
    _stash_print_files "$blocked"
    echo ""
    echo "  Commit or stash these changes first."
    echo ""
  fi
  if [[ -n "$likely" ]]; then
    echo "$bar"
    echo "  ⚠ POSSIBLE CONFLICTS (changed since the stash)"
    echo "$bar"
    echo ""
    _stash_print_files "$likely"
    echo ""
  fi

  echo "$bar"
  echo "  FILES CHANGED"
  echo "$bar"
  echo ""
  while IFS=$'\t' read -r added removed file; do
    [[ -n "$file" ]] || continue
    if [[ "$added" == "-" ]]; then
      added="bin"
      removed="bin"
    fi
    printf "  %5s %5s  %s\n" "+$added" "-$removed" "$file"
  done <<< "$tracked_stat"
  while IFS=$'\t' read -r added removed file; do
    [[ -n "$file" ]] || continue
    [[ "$added" == "-" ]] && added="bin"
    printf "  %5s %5s  %s (untracked)\n" "+$added" "new" "$file"
  done <<< "$untracked_stat"
}

# Description d'une action du sous-menu (preview)
_stash_action_info() {
  local action="$1" sha="$2"
  case "$action" in
    apply)
      echo "Apply the stash changes to your working directory."
      echo "The stash will remain in the stash list."
      echo ""
      echo "Equivalent to: git stash apply"
      ;;
    pop)
      echo "Apply the stash changes and remove it from the list."
      echo "Use this when you are done with the stash."
      echo "On conflicts, git keeps the stash."
      echo ""
      echo "Equivalent to: git stash pop"
      ;;
    claude)
      echo "Apply the stash, then launch Claude on the"
      echo "conflicted files to fix the conflict markers."
      local conflicts likely
      conflicts=$(_stash_conflicts "$sha")
      likely=$(_stash_conflict_files conflict "$conflicts")
      if [[ -n "$likely" ]]; then
        echo ""
        echo "Possible conflicts (changed since the stash):"
        _stash_print_files "$likely"
      fi
      echo ""
      echo "Requires: claude CLI installed"
      ;;
    worktree)
      echo "Create a new worktree with this stash applied."
      echo ""
      echo "- Creates a new branch at the stash base commit:"
      echo "  $(git log -1 --format='%h %s' "${sha}^1" 2>/dev/null)"
      echo "  so the stash applies without conflicts"
      echo "- Creates the worktree as ${_WT_STASH_WTBASE:-<worktree dir>/<repo>-}<branch>"
      echo "- Copies the .env files of the main worktree"
      echo "- Optionally drops the stash after"
      echo ""
      echo "Perfect for isolating WIP work!"
      ;;
    drop)
      echo "Permanently delete this stash."
      echo "This action cannot be undone!"
      echo ""
      echo "Equivalent to: git stash drop"
      ;;
    branch)
      echo "Create a new branch from this stash, in the"
      echo "current worktree: checks out the stash base"
      echo "commit, applies the stash and drops it."
      echo ""
      echo "Equivalent to: git stash branch <name>"
      ;;
    export)
      echo "Export the stash as a .patch file, untracked"
      echo "and binary files included, into:"
      echo "  $(_stash_export_dir)"
      echo ""
      echo "Restore it with: git apply <file>"
      ;;
    show)
      echo "View the complete diff of this stash,"
      echo "untracked files included, in less."
      echo ""
      echo "Equivalent to: git stash show -p --include-untracked"
      ;;
    rename)
      echo "Change the message of this stash."
      echo "The stash content and your working tree are"
      echo "left untouched. The renamed stash moves to"
      echo "the top of the list (stash@{0})."
      ;;
    *)
      echo "Return to stash list"
      ;;
  esac
}

# =============================================================================
# Stash Management - Actions
# =============================================================================

# Créer un stash de tous les changements (untracked inclus)
_stash_create_all() {
  local stash_msg before after rc
  # Esc / Ctrl+C sur le message = annuler
  stash_msg=$(ui_input "Stash message:" "optional") || return 0
  before=$(git rev-parse -q --verify refs/stash 2>/dev/null)
  local -a args=(stash push -q -u)
  [[ -n "$stash_msg" ]] && args+=(-m "$stash_msg")
  git "${args[@]}" >&2
  rc=$?
  after=$(git rev-parse -q --verify refs/stash 2>/dev/null)
  if [[ -n "$after" && "$after" != "$before" ]]; then
    msg_success "Stash created"
  elif [[ $rc -eq 0 ]]; then
    msg_warn "No local changes to save"
  else
    msg_error "Error creating stash"
  fi
}

# Créer un stash partiel (sélection de fichiers)
_stash_partial() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1

  # Tous les chemins relatifs à la racine, quel que soit le dossier courant
  local all_files
  all_files=$( {
    git -C "$top" -c core.quotePath=false diff --name-only
    git -C "$top" -c core.quotePath=false diff --cached --name-only
    git -C "$top" -c core.quotePath=false ls-files --others --exclude-standard
  } 2>/dev/null | sort -u | grep -v '^$')

  if [[ -z "$all_files" ]]; then
    msg "No changes to stash"
    return 1
  fi

  local partial_header="${C_BOLD}Partial stash${C_RESET}"
  local partial_footer="Space select · ^A all · Enter confirm"

  local selected
  # shellcheck disable=SC2016 # expanded by the preview shell
  selected=$(printf '%s\n' "$all_files" | \
    _WT_STASH_TOP="$top" wt_fzf --height=60% \
        --layout=reverse \
        --border \
        --ansi \
        --multi \
        --marker='+ ' \
        --bind 'space:toggle+down' \
        --bind 'ctrl-a:select-all' \
        --header="$partial_header" \
        --footer="$partial_footer" \
        --preview='cd "$_WT_STASH_TOP" || exit 0
          if git --literal-pathspecs ls-files --error-unmatch -- {} >/dev/null 2>&1; then
            git --literal-pathspecs diff --color=always HEAD -- {}
          else
            git diff --color=always --no-index -- /dev/null {}
          fi' \
        --preview-window=right:50%)

  if [[ -z "$selected" ]]; then
    return 1
  fi

  local stash_msg
  stash_msg=$(ui_input "Stash message:" "optional") || return 1

  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done <<< "$selected"

  # -u avec pathspec stashe aussi les untracked sélectionnés, sans git add
  local before after rc
  before=$(git rev-parse -q --verify refs/stash 2>/dev/null)
  local -a args=(stash push -q -u)
  [[ -n "$stash_msg" ]] && args+=(-m "$stash_msg")
  git -C "$top" --literal-pathspecs "${args[@]}" -- "${files[@]}" >&2
  rc=$?
  after=$(git rev-parse -q --verify refs/stash 2>/dev/null)
  if [[ -n "$after" && "$after" != "$before" ]]; then
    msg_success "Partial stash created (${#files[@]} file(s))"
  elif [[ $rc -eq 0 ]]; then
    msg_warn "No local changes to save"
  else
    msg_error "Error creating stash"
  fi
}

# Applique un stash: _stash_apply apply|pop <sha>
# Retour: 0 = appliqué, 2 = appliqué avec conflits, 1 = erreur
_stash_apply() {
  local cmd="$1" sha="$2" ref top blocked
  ref=$(_stash_ref_of "$sha") || return 1
  top=$(git rev-parse --show-toplevel 2>/dev/null)

  # git refuserait l'apply, mais après avoir parfois déjà restauré une partie
  # des fichiers: on refuse avant de toucher au working tree
  blocked=$(_stash_conflict_files blocked "$(_stash_conflicts "$sha")")
  if [[ -n "$blocked" ]]; then
    msg_error "Cannot apply $ref, local changes would be overwritten: $(_stash_join "$blocked")"
    msg "Commit or stash these changes first"
    return 1
  fi

  local done_word="applied"
  [[ "$cmd" == "pop" ]] && done_word="popped"
  if git stash "$cmd" "$ref" >&2; then
    msg_success "Stash $ref $done_word"
    return 0
  fi

  local conflicted
  conflicted=$(git -C "$top" -c core.quotePath=false diff --name-only --diff-filter=U 2>/dev/null)
  if [[ -n "$conflicted" ]]; then
    msg_warn "Stash $ref applied with conflicts in: $(_stash_join "$conflicted")"
    [[ "$cmd" == "pop" ]] && msg "The stash was kept, drop it once the conflicts are resolved"
    return 2
  fi
  msg_error "Error applying stash $ref"
  return 1
}

# Apply + résolution des conflits par Claude
_stash_resolve_with_claude() {
  local sha="$1" ref rc
  ref=$(_stash_ref_of "$sha") || return 1
  _stash_apply apply "$sha"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    msg "No conflicts, nothing to resolve"
    return 0
  fi
  [[ $rc -eq 2 ]] || return 1

  local top files_list
  top=$(git rev-parse --show-toplevel 2>/dev/null)
  files_list=$(_stash_join "$(git -C "$top" -c core.quotePath=false diff --name-only --diff-filter=U 2>/dev/null)")

  if ! has_claude; then
    msg_warn "Claude not found. Resolve the conflicts in: $files_list"
    return 1
  fi

  local n="${ref#stash@\{}"
  n="${n%\}}"
  local mode
  mode=$(select_claude_mode "stash" "$n")
  if [[ -z "$mode" ]]; then
    msg "Claude not launched. Conflicts left in: $files_list"
    return 0
  fi

  local -a flags=()
  case "$mode" in
    forced) flags=(--dangerously-skip-permissions) ;;
    plan)   flags=(--permission-mode=plan) ;;
  esac

  local prompt="Resolve the merge conflicts in these files: $files_list. The conflicts come from applying git stash $ref. Please fix all conflict markers (<<<<<<<, =======, >>>>>>>) and keep the best version of the code. Do not commit."
  local tty="${_WT_STASH_TTY:-/dev/tty}"
  msg_info "Launching Claude to resolve the conflicts..."
  (
    cd "$top" || exit 1
    # Caches de cette session wt, inutiles à Claude
    unset _WT_FZF_FOOTER _WT_PLATFORM _WT_DEFAULT_BRANCH _WT_CACHE_REPO
    claude ${flags[@]+"${flags[@]}"} "$prompt" <"$tty" >"$tty" 2>"$tty"
  )
}

# Créer un worktree depuis un stash, comme les autres créations de wt.
# Seul stdout: le chemin du worktree.
_stash_worktree() {
  local sha="$1" ref
  ref=$(_stash_ref_of "$sha") || return 1

  local input_name
  input_name=$(ui_input "Worktree/branch name:" "feature/...") || return 0
  [[ -n "$input_name" ]] || return 0
  if ! git check-ref-format --branch "$input_name" >/dev/null 2>&1; then
    msg_error "Invalid branch name: $input_name"
    return 1
  fi

  # Incrémenter si la branche existe déjà
  local branch_name="$input_name" counter=2
  while git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null || \
        git show-ref --verify --quiet "refs/remotes/origin/$branch_name" 2>/dev/null; do
    branch_name="${input_name}-${counter}"
    counter=$((counter + 1))
  done

  # Même emplacement que les autres créations (WT_WORKTREE_DIR relatif pris
  # depuis le repo principal, suffixe -2 si le dossier est déjà pris)
  local wt_path
  wt_path=$(_wt_new_worktree_path "${REPO_NAME}-${branch_name//\//-}")

  # Base = commit parent du stash: l'apply est toujours propre
  msg "Creating worktree with new branch '$branch_name' from the stash base..."
  _wt_add_worktree --no-track -b "$branch_name" "$wt_path" "${sha}^1" || return 1
  copy_env_to_worktree "$wt_path"

  if git -C "$wt_path" stash apply "$sha" >&2; then
    msg_success "Worktree created at $wt_path with $ref applied"
    if ui_confirm "Drop $ref?"; then
      local cur
      if cur=$(_stash_ref_of "$sha") && git stash drop -q "$cur" >&2; then
        msg_success "Stash dropped"
      else
        msg_error "Error dropping stash"
      fi
    fi
  else
    msg_warn "Worktree created at $wt_path but the stash apply failed"
  fi
  printf '%s\n' "$wt_path"
}

# Créer une branche depuis un stash (dans le worktree courant)
# Retour 3 = quitter le menu stash
_stash_branch() {
  local sha="$1" ref branch_name
  ref=$(_stash_ref_of "$sha") || return 1
  branch_name=$(ui_input "Branch name:" "feature/...") || return 0
  [[ -n "$branch_name" ]] || return 0
  if git stash branch "$branch_name" "$ref" >&2; then
    msg_success "Branch '$branch_name' created from $ref"
    return 3
  fi
  msg_error "Error creating branch '$branch_name'"
  return 1
}

# Supprimer un ou plusieurs stashes (par sha, la ref est résolue à chaque drop)
_stash_drop() {
  local count=$# prompt ref sha ok=0 ko=0
  [[ $count -gt 0 ]] || return 0
  if [[ $count -eq 1 ]]; then
    ref=$(_stash_ref_of "$1") || return 1
    prompt="Delete $ref?"
  else
    prompt="Delete $count stashes?"
  fi
  ui_confirm "$prompt" || return 0

  for sha in "$@"; do
    if ref=$(_stash_ref_of "$sha") && git stash drop -q "$ref" >&2; then
      ok=$((ok + 1))
    else
      ko=$((ko + 1))
    fi
  done
  if [[ $count -eq 1 && $ok -eq 1 ]]; then
    msg_success "Stash $ref dropped"
  elif [[ $ok -gt 0 ]]; then
    msg_success "$ok stash(es) dropped"
  fi
  if [[ $ko -gt 0 ]]; then
    msg_error "$ko stash(es) could not be dropped"
    return 1
  fi
}

# Afficher le diff complet dans less, sur le terminal
_stash_show() {
  local sha="$1" tty="${_WT_STASH_TTY:-/dev/tty}"
  _stash_ref_of "$sha" >/dev/null || return 1
  _stash_patch "$sha" --color=always --no-ext-diff | less -R -+F >"$tty"
}

# Exporter un stash en .patch (untracked et binaires inclus)
_stash_export() {
  local sha="$1" ref dir short name file
  ref=$(_stash_ref_of "$sha") || return 1
  dir=$(_stash_export_dir)
  short=$(git rev-parse --short "$sha" 2>/dev/null)
  name="${REPO_NAME:-}"
  [[ -n "$name" ]] || name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
  file="$dir/${name}-stash-${short}-$(date +%Y%m%d-%H%M%S).patch"

  if _stash_patch "$sha" --binary --no-ext-diff --no-textconv \
       --src-prefix=a/ --dst-prefix=b/ > "$file" && [[ -s "$file" ]]; then
    msg_success "Exported $ref to $file"
    msg "Apply it with: git apply \"$file\""
  else
    rm -f "$file"
    msg_error "Export failed: $file"
    return 1
  fi
}

# Renommer un stash sans toucher au working tree: git stash store du même
# commit avec le nouveau message, puis drop de l'ancienne entrée
_stash_rename() {
  local sha="$1" new_msg
  _stash_ref_of "$sha" >/dev/null || return 1
  _stash_split_subject "$_STASH_SUBJ"
  local old_msg="$_STASH_MSG" prefix=""
  new_msg=$(ui_input "New stash message:" "$old_msg") || return 0
  [[ -n "$new_msg" ]] || return 0
  # Garder "On <branche>: " pour la colonne branch
  [[ -n "$_STASH_BRANCH" ]] && prefix="On ${_STASH_BRANCH}: "

  local ref="$_STASH_REF" n
  n="${ref#stash@\{}"
  n="${n%\}}"
  if [[ "$n" == "0" ]]; then
    # store n'ajoute pas d'entrée si refs/stash pointe déjà sur ce commit
    if ! git stash drop -q "$ref" >&2; then
      msg_error "Error renaming stash"
      return 1
    fi
    if git stash store -m "${prefix}${new_msg}" "$sha" >&2; then
      msg_success "Stash renamed"
    else
      msg_error "Error renaming stash, restore it with: git stash store $sha"
      return 1
    fi
    return 0
  fi

  if ! git stash store -m "${prefix}${new_msg}" "$sha" >&2; then
    msg_error "Error renaming stash"
    return 1
  fi
  # L'ancienne entrée est décalée d'un cran par le store
  local old="stash@{$((n + 1))}"
  if [[ "$(git rev-parse -q --verify "$old" 2>/dev/null)" == "$sha" ]] && \
     git stash drop -q "$old" >&2; then
    msg_success "Stash renamed (now stash@{0})"
  else
    msg_warn "Renamed copy created as stash@{0}, the old entry was kept"
  fi
}

# Exécute une action du menu stash: _stash_run <action> [sha...]
# stdout: uniquement le chemin d'un worktree à ouvrir. Retour 3 = quitter le menu.
_stash_run() {
  local action="$1"
  shift
  case "$action" in
    new)      _stash_create_all ;;
    partial)  _stash_partial ;;
    *)
      [[ -n "${1:-}" ]] || return 0
      case "$action" in
        apply)    _stash_apply apply "$1" ;;
        pop)      _stash_apply pop "$1" ;;
        claude)   _stash_resolve_with_claude "$1" ;;
        worktree) _stash_worktree "$1" ;;
        branch)   _stash_branch "$1" ;;
        drop)     _stash_drop "$@" ;;
        show)     _stash_show "$1" ;;
        export)   _stash_export "$1" ;;
        rename)   _stash_rename "$1" ;;
      esac
      ;;
  esac
}

# Sous-menu d'actions pour un stash -> action choisie sur stdout
_stash_action_menu() {
  local sha="$1"
  _stash_lookup "$sha" || return 1
  local ref="$_STASH_REF"
  _stash_split_subject "$_STASH_SUBJ"

  local conflicts blocked likely
  conflicts=$(_stash_conflicts "$sha")
  blocked=$(_stash_conflict_files blocked "$conflicts")
  likely=$(_stash_conflict_files conflict "$conflicts")

  # Construire le menu depuis la table des raccourcis
  local menu_options="" line key hint action scope section short label
  while IFS='|' read -r key hint action scope section short label; do
    [[ "$scope" == "stash" ]] || continue
    # L'option Claude seulement si de vrais conflits sont possibles
    if [[ "$action" == "claude" ]] && [[ -z "$likely" || -n "$blocked" ]]; then
      continue
    fi
    printf -v line '%s\t%-38s %s' "$action" "$label" "$hint"
    menu_options+="$line"$'\n'
  done <<< "$_STASH_KEYMAP"
  menu_options+="back"$'\t'"Back"

  local stash_header="${C_BOLD}$ref${C_RESET} ${C_DIM}│${C_RESET} $_STASH_MSG"
  if [[ -n "$blocked" ]]; then
    stash_header+=$'\n'"${C_YELLOW}⚠ Apply blocked by local changes:${C_RESET} $(_stash_join "$blocked")"
  elif [[ -n "$likely" ]]; then
    stash_header+=$'\n'"${C_YELLOW}⚠ Possible conflicts:${C_RESET} $(_stash_join "$likely")"
  fi
  local stash_footer="Enter select · Esc back"

  local action_result
  # shellcheck disable=SC2016 # expanded by the preview shell
  action_result=$(printf '%s\n' "$menu_options" | \
    _WT_STASH_LIB="$_WT_STASH_LIB" _WT_STASH_SHA="$sha" \
    _WT_STASH_WTBASE="$(get_worktree_base_dir)/${REPO_NAME}-" \
    wt_fzf --height=40% \
        --layout=reverse \
        --border \
        --ansi \
        --delimiter=$'\t' \
        --with-nth=2 \
        --header="$stash_header" \
        --footer="$stash_footer" \
        --expect="$(_stash_keys stash)" \
        --preview='source "$_WT_STASH_LIB" && _stash_action_info {1} "$_WT_STASH_SHA"' \
        --preview-window=right:50%)

  local action_key choice
  action_key=$(printf '%s\n' "$action_result" | head -1)
  choice=$(printf '%s\n' "$action_result" | sed -n '2p')
  if [[ -n "$action_key" ]]; then
    _stash_key_action "$action_key"
  elif [[ -n "$choice" ]]; then
    printf '%s\n' "${choice%%$'\t'*}"
  fi
}

# =============================================================================
# Stash Management - Main menu
# =============================================================================

menu_stash() {
  local help_text
  help_text=$(_stash_help)

  while true; do
    local formatted_list action="" out rc
    local -a shas=()
    formatted_list=$(_format_stash_list)

    if [[ -z "$formatted_list" ]]; then
      # Proposer de créer un stash
      local empty_header="${C_BOLD}No stashes${C_RESET}"
      local empty_footer
      empty_footer=$(_stash_footer new partial)
      local empty_result
      empty_result=$(printf "%s\n" \
        "Create stash (all changes)" \
        "Create partial stash (select files)" \
        "Back" | \
        wt_fzf --height=30% \
            --layout=reverse \
            --border \
            --ansi \
            --header="$empty_header" \
            --footer="$empty_footer" \
            --expect="$(_stash_keys global)")

      local empty_key choice
      empty_key=$(printf '%s\n' "$empty_result" | head -1)
      choice=$(printf '%s\n' "$empty_result" | sed -n '2p')

      case "$empty_key" in
        ctrl-n) choice="Create stash (all changes)" ;;
        ctrl-e) choice="Create partial stash (select files)" ;;
      esac

      case "$choice" in
        "Create stash (all"*) action="new" ;;
        "Create partial"*)    action="partial" ;;
        *)                    return 1 ;;
      esac
    else
      # Header avec titre stylé
      local header="${C_BOLD}Stashes${C_RESET}
ref         │ age  │ files │ branch       │ message
────────────┴──────┴───────┴──────────────┴─────────────────────────────"
      local footer="Enter actions · Space select · ? help"

      # Afficher les stashes avec actions. Champ 2 (caché) = sha du stash.
      local result
      # shellcheck disable=SC2016 # expanded by the preview shell
      result=$(printf '%s\n' "$formatted_list" | \
        _WT_STASH_LIB="$_WT_STASH_LIB" _WT_STASH_HELP="$help_text" \
        wt_fzf --height=80% \
            --layout=reverse \
            --border \
            --ansi \
            --multi \
            --marker='> ' \
            --delimiter=$'\t' \
            --with-nth=1 \
            --bind 'space:toggle+down' \
            --bind '?:preview(printf "%s\n" "$_WT_STASH_HELP"; source "$_WT_STASH_LIB" && _stash_preview {2})' \
            --header="$header" \
            --footer="$footer" \
            --preview='source "$_WT_STASH_LIB" && _stash_preview {2}' \
            --preview-window=right:50% \
            --expect="$(_stash_keys all)")

      local key line
      key=$(printf '%s\n' "$result" | head -1)
      while IFS= read -r line; do
        [[ "$line" == *$'\t'* ]] && shas+=("${line##*$'\t'}")
      done <<< "$(printf '%s\n' "$result" | sed '1d')"

      if [[ -n "$key" ]]; then
        action=$(_stash_key_action "$key")
      else
        # Esc ou aucune sélection
        [[ ${#shas[@]} -gt 0 ]] || return 1
        # Enter: menu d'actions pour le premier stash sélectionné
        action=$(_stash_action_menu "${shas[0]}")
        shas=("${shas[0]}")
      fi
      [[ -z "$action" || "$action" == "back" ]] && continue
    fi

    out=$(_stash_run "$action" ${shas[@]+"${shas[@]}"})
    rc=$?
    # Seul un chemin de worktree existant peut sortir sur stdout
    out="${out##*$'\n'}"
    if [[ -n "$out" && -d "$out" ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    [[ $rc -eq 3 ]] && return 0
  done
}
