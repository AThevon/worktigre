#compdef wt wt-core
# worktigre - zsh completion for wt / wt-core
#
# Installed as _wt in an fpath directory (Homebrew, Nix), compinit loads it on
# its own. It can also be sourced after compinit: it then registers itself.
#
# Completes the public flags, `-` (previous worktree), `.` (main worktree) and
# the worktrees of the current repository, by branch or by directory name.
# It only reads `git worktree list`, wt-core itself is never started.

_wt() {
  local -a flags specials worktrees lines
  local line wt_path wt_branch ret=1

  # wt takes a single argument
  (( CURRENT == 2 )) || return 1

  flags=(
    '--help:show the help'
    '-h:show the help'
    '--version:show the version'
    '-v:show the version'
    '--setup:add wt to your shell config'
    '--wizard:run the preferences wizard again'
    '--update:update to the latest release'
    '--dev:use wt.sh from the current worktree'
    '--release:use wt-core from PATH again'
  )
  specials=('-:previous worktree')

  if git rev-parse --git-dir >/dev/null 2>&1; then
    specials+=('.:main worktree')
    lines=("${(@f)$(git worktree list --porcelain 2>/dev/null)}")
    for line in "${lines[@]}" ''; do
      case "$line" in
        'worktree '*)
          wt_path="${line#worktree }"
          wt_branch=""
          ;;
        'branch refs/heads/'*)
          wt_branch="${line#branch refs/heads/}"
          ;;
        '')
          # End of a block: one entry per branch, one per directory name
          if [[ -n "$wt_path" ]]; then
            if [[ -n "$wt_branch" ]]; then
              worktrees+=("${wt_branch//:/\\:}:${(D)wt_path}")
            fi
            if [[ "${wt_path:t}" != "$wt_branch" ]]; then
              worktrees+=("${${wt_path:t}//:/\\:}:${wt_branch:-detached}")
            fi
          fi
          wt_path=""
          wt_branch=""
          ;;
      esac
    done
  fi

  if [[ "$PREFIX" == -* ]]; then
    _describe -t options 'option' flags && ret=0
    _describe -t special 'shortcut' specials && ret=0
  else
    _describe -t special 'shortcut' specials && ret=0
    if (( ${#worktrees} )); then
      _describe -t worktrees 'worktree' worktrees && ret=0
    fi
  fi
  return ret
}

# compinit autoloads this file as the body of _wt: run the completion.
# Sourced by hand: register it.
if [[ "${funcstack[1]}" == "_wt" ]]; then
  _wt "$@"
elif (( $+functions[compdef] )); then
  compdef _wt wt wt-core
fi
