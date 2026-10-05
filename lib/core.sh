#!/usr/bin/env bash
# lib/core.sh - Foundation: colors, config, messages, platform detection
# Extracted from wt.sh. Every other module sources this file.

# =============================================================================
# Colors & Style
# =============================================================================

# Colors (only if terminal supports it)
if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
  C_ORANGE=$'\033[1;38;5;208m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN=''
  C_YELLOW='' C_MAGENTA='' C_CYAN='' C_ORANGE=''
fi

# Default fzf theme for wt, only used if the user has no fzf config of their own
# (FZF_DEFAULT_OPTS or FZF_DEFAULT_OPTS_FILE). Not exported: wt_fzf hands it to
# fzf only, so editors or Claude started from wt never inherit it.
_WT_FZF_THEME=""
if [[ -z "${FZF_DEFAULT_OPTS:-}" && -z "${FZF_DEFAULT_OPTS_FILE:-}" ]]; then
  _WT_FZF_THEME="
    --color=bg:-1,fg:#908e8e,hl:#e8a030
    --color=bg+:#1e1e1e,fg+:#ffffff,hl+:#f0b040
    --color=border:#333333,header:#e8a030,info:#555555
    --color=prompt:#e8a030,pointer:#e8a030,marker:#f0b040
    --color=spinner:#e8a030
  "
fi

# Passed before each menu's own options (so an explicit --multi or --preview
# still wins): they cancel FZF_DEFAULT_OPTS settings that would change what fzf
# prints or skip the menu (--print-query, --multi, --select-1, --read0...).
_WT_FZF_BASE_OPTS=(--no-multi --no-print-query --no-select-1 --no-exit-0 --no-read0 --no-print0 --no-preview)

# Detect whether fzf understands --footer (added in fzf 0.63). The result is
# exported so nested wt-core processes don't probe again.
_wt_fzf_detect() {
  [[ -n "${_WT_FZF_FOOTER:-}" ]] && return 0
  ( unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE
    command fzf --footer=x --filter=x </dev/null >/dev/null 2>&1 )
  if [[ $? -eq 2 ]]; then
    _WT_FZF_FOOTER=0
  else
    _WT_FZF_FOOTER=1
  fi
  export _WT_FZF_FOOTER
}

# Every fzf call goes through this wrapper:
# - previews and bindings are written in bash, but fzf runs them with $SHELL
#   (often zsh or fish), so force the running bash for them
# - on fzf < 0.63, --footer is turned into an extra header line
# - the wt theme and _WT_FZF_BASE_OPTS are applied
wt_fzf() {
  _wt_fzf_detect
  local fzf_shell="${BASH:-bash}"
  local args=("${_WT_FZF_BASE_OPTS[@]}")

  if [[ "$_WT_FZF_FOOTER" == "1" ]]; then
    args+=("$@")
  else
    local footer="" arg i first=${#args[@]}
    for arg in "$@"; do
      case "$arg" in
        --footer=*) footer="${arg#--footer=}" ;;
        *) args+=("$arg") ;;
      esac
    done
    if [[ -n "$footer" ]]; then
      for (( i = first; i < ${#args[@]}; i++ )); do
        if [[ "${args[$i]}" == --header=* ]]; then
          args[$i]="${args[$i]}"$'\n'"$footer"
          footer=""
          break
        fi
      done
      [[ -n "$footer" ]] && args+=("--header=$footer")
    fi
  fi

  if [[ -n "$_WT_FZF_THEME" ]]; then
    FZF_DEFAULT_OPTS="$_WT_FZF_THEME" SHELL="$fzf_shell" command fzf "${args[@]}"
  else
    SHELL="$fzf_shell" command fzf "${args[@]}"
  fi
}

# =============================================================================
# Config
# =============================================================================

WT_CONFIG_FILE="${WT_CONFIG_FILE:-${HOME}/.config/wt/config}"

# Keys read from the config file
_WT_CONFIG_KEYS="WT_EDITOR WT_PLATFORM WT_WORKTREE_DIR WT_AUTO_CD WT_FEATURE_PREFIX WT_AUTO_FETCH WT_CLAUDE_MODE WT_LIST_LIMIT"

# Keys already set in the environment when wt starts win over the config file
# (e.g. `WT_PLATFORM=gitlab wt`). The snapshot is taken once, so reloading the
# config later (after Settings or a reset) still picks up the file values.
_WT_ENV_KEYS=" "
for _wt_key in $_WT_CONFIG_KEYS; do
  [[ -n "${!_wt_key+x}" ]] && _WT_ENV_KEYS+="$_wt_key "
done
unset _wt_key

# Parse one config line without executing it. Accepts KEY="value" (written by
# save_config_value), KEY='value', and the older unquoted KEY=value form, with
# an optional leading "export". A leading ~ or $HOME is expanded.
# Sets _WT_CFG_KEY/_WT_CFG_VALUE. Returns 1 for comments, blanks, unknown keys.
_wt_config_parse_line() {
  local line="$1" key raw value="" c n i=0

  line="${line#"${line%%[![:space:]]*}"}"
  if [[ "$line" == export[[:space:]]* ]]; then
    line="${line#export}"
    line="${line#"${line%%[![:space:]]*}"}"
  fi
  [[ "$line" == *=* ]] || return 1
  key="${line%%=*}"
  case " $_WT_CONFIG_KEYS " in
    *" $key "*) ;;
    *) return 1 ;;
  esac
  raw="${line#*=}"

  case "$raw" in
    \"*)
      raw="${raw#\"}"
      while (( i < ${#raw} )); do
        c="${raw:i:1}"
        if [[ "$c" == '\' ]]; then
          n="${raw:i+1:1}"
          case "$n" in
            '\'|'"'|'$'|'`') value+="$n"; i=$((i + 2)); continue ;;
          esac
        elif [[ "$c" == '"' ]]; then
          break
        fi
        value+="$c"
        i=$((i + 1))
      done
      ;;
    \'*)
      raw="${raw#\'}"
      value="${raw%%\'*}"
      ;;
    *)
      value="${raw%%[[:space:]]#*}"
      value="${value%"${value##*[![:space:]]}"}"
      ;;
  esac

  case "$value" in
    "~"|'$HOME'|'${HOME}') value="$HOME" ;;
    "~/"*) value="$HOME/${value#\~/}" ;;
    '$HOME/'*) value="$HOME/${value#\$HOME/}" ;;
    '${HOME}/'*) value="$HOME/${value#\$\{HOME\}/}" ;;
  esac

  _WT_CFG_KEY="$key"
  _WT_CFG_VALUE="$value"
}

load_config() {
  local key line
  # Start from a clean slate so a reloaded file (after a reset) drops old values
  for key in $_WT_CONFIG_KEYS; do
    [[ "$_WT_ENV_KEYS" == *" $key "* ]] || unset "$key"
  done
  [[ -f "$WT_CONFIG_FILE" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    _wt_config_parse_line "$line" || continue
    [[ "$_WT_ENV_KEYS" == *" $_WT_CFG_KEY "* ]] && continue
    printf -v "$_WT_CFG_KEY" '%s' "$_WT_CFG_VALUE"
  done < "$WT_CONFIG_FILE"
}

# Write KEY="value" (\ " $ and ` escaped), replacing any previous definition
save_config_value() {
  local key="$1"
  local value="$2"
  local config_dir
  config_dir=$(dirname "$WT_CONFIG_FILE")

  mkdir -p "$config_dir" || return 1

  if [[ ! -f "$WT_CONFIG_FILE" ]]; then
    printf '%s\n' "# worktigre - user configuration" \
      "# Edit manually or via: wt > Settings" > "$WT_CONFIG_FILE" || return 1
  fi

  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[\\"$`]/\\&/g')

  # awk reads the line through ENVIRON (awk -v would eat the backslashes).
  # The file is rewritten in place, so a symlinked config keeps its link.
  local tmp_file="${WT_CONFIG_FILE}.tmp.$$"
  WT_CFG_KEY="$key" WT_CFG_LINE="${key}=\"${escaped}\"" awk '
    BEGIN { k = ENVIRON["WT_CFG_KEY"] "="; l = ENVIRON["WT_CFG_LINE"]; done = 0 }
    {
      s = $0
      sub(/^[ \t]*/, "", s)
      sub(/^export[ \t]+/, "", s)
      if (index(s, k) == 1) {
        if (!done) { print l; done = 1 }
        next
      }
      print
    }
    END { if (!done) print l }
  ' "$WT_CONFIG_FILE" > "$tmp_file" &&
    cat "$tmp_file" > "$WT_CONFIG_FILE"
  local ret=$?
  rm -f "$tmp_file"
  return $ret
}

# Value of a config key with the same rules as load_config (environment first,
# then the last definition in the file), or the given default
get_config_value() {
  local key="$1"
  local default="$2"
  local value="" line
  if [[ "$_WT_ENV_KEYS" == *" $key "* ]]; then
    value="${!key}"
  elif [[ -f "$WT_CONFIG_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      _wt_config_parse_line "$line" || continue
      [[ "$_WT_CFG_KEY" == "$key" ]] && value="$_WT_CFG_VALUE"
    done < "$WT_CONFIG_FILE"
  fi
  echo "${value:-$default}"
}

get_worktree_base_dir() {
  if [[ -n "${WT_WORKTREE_DIR:-}" ]]; then
    # Expand ~ if present. A relative path is taken from the parent of the
    # main worktree, never from the current folder.
    local dir="${WT_WORKTREE_DIR/#\~/$HOME}"
    if [[ "$dir" != /* ]]; then
      dir="${dir#./}"
      [[ "$dir" == "." ]] && dir=""
      dir="$(dirname "$MAIN_REPO")${dir:+/$dir}"
    fi
    echo "$dir"
  else
    echo "$(dirname "$MAIN_REPO")"
  fi
}

has_fzf() {
  command -v fzf &> /dev/null
}

has_claude() {
  command -v claude &> /dev/null
}

get_editor() {
  # Config takes priority
  local configured="${WT_EDITOR:-}"
  if [[ -n "$configured" ]]; then
    echo "$configured"
    return
  fi
  # Auto-detect
  if command -v cursor &>/dev/null; then echo "cursor"
  elif command -v code &>/dev/null; then echo "code"
  elif [[ -n "$EDITOR" ]]; then echo "$EDITOR"
  else echo "vim"
  fi
}

# Open a path in the editor (WT_EDITOR may carry arguments, e.g. "code -n").
# Terminal editors run in the foreground on the tty. GUI editors are started
# detached with stdin/stdout/stderr on /dev/null, so a $(...) caller never
# waits for them and nothing they print reaches wt's stdout.
open_in_editor() {
  local target="$1"
  local editor
  editor=$(get_editor)
  local cmd=()
  read -r -a cmd <<< "$editor"

  if [[ ${#cmd[@]} -eq 0 ]]; then
    msg_error "No editor configured (wt > Settings > IDE)"
    return 1
  fi
  if ! command -v "${cmd[0]}" &>/dev/null; then
    msg_error "Editor not found: ${cmd[0]} (wt > Settings > IDE)"
    return 1
  fi

  local in_terminal=false arg
  case "${cmd[0]##*/}" in
    vi|vim|nvim|nano|emacs|hx|helix|micro|kak|joe|ne|mg) in_terminal=true ;;
  esac
  # emacsclient -t / -nw and friends also need the terminal
  for arg in "${cmd[@]:1}"; do
    case "$arg" in
      -t|-nw|--tty) in_terminal=true ;;
    esac
  done

  if [[ "$in_terminal" == "true" ]]; then
    "${cmd[@]}" "$target" </dev/tty >/dev/tty 2>/dev/tty
  else
    (
      unset _WT_FZF_FOOTER _WT_PLATFORM _WT_DEFAULT_BRANCH _WT_CACHE_REPO
      exec "${cmd[@]}" "$target"
    ) </dev/null >/dev/null 2>&1 &
  fi
}

# =============================================================================
# Messages (stderr uniquement)
# =============================================================================

msg() {
  echo -e "$@" >&2
}

msg_success() {
  echo -e "${C_GREEN}✓${C_RESET} $*" >&2
}

msg_error() {
  echo -e "${C_RED}✗${C_RESET} $*" >&2
}

msg_info() {
  echo -e "${C_CYAN}→${C_RESET} $*" >&2
}

msg_warn() {
  echo -e "${C_YELLOW}!${C_RESET} $*" >&2
}

# =============================================================================
# Platform Detection (GitHub / GitLab)
# =============================================================================

# Cache filled once by the entry point (and inherited by nested wt-core
# processes through the environment). detect_platform called inside $(...)
# cannot fill it, hence the explicit init in wt.sh.
_WT_PLATFORM="${_WT_PLATFORM:-}"

# Host of the origin remote, lowercased: handles git@host:path,
# scheme://[user@]host[:port]/path, and prints nothing for local paths
_wt_remote_host() {
  local url auth
  url=$(git -C "${MAIN_REPO:-.}" remote get-url origin 2>/dev/null) || return 0
  case "$url" in
    *://*) auth="${url#*://}"; auth="${auth%%/*}" ;;
    *:*)   auth="${url%%:*}" ;;
    *)     return 0 ;;
  esac
  auth="${auth##*@}"
  auth="${auth%%:*}"
  printf '%s\n' "$auth" | tr '[:upper:]' '[:lower:]'
}

detect_platform() {
  if [[ -n "$_WT_PLATFORM" ]]; then
    echo "$_WT_PLATFORM"
    return
  fi

  # Override via environment variable or config
  case "${WT_PLATFORM:-}" in
    github|gitlab)
      _WT_PLATFORM="$WT_PLATFORM"
      echo "$_WT_PLATFORM"
      return
      ;;
  esac

  # Auto-detect from the remote host (not the whole URL: an owner or repo
  # named "gitlab-something" on GitHub stays GitHub)
  case "$(_wt_remote_host)" in
    *gitlab*) _WT_PLATFORM="gitlab" ;;
    *)        _WT_PLATFORM="github" ;;
  esac

  echo "$_WT_PLATFORM"
}

# Is the platform CLI installed and logged in? Checked locally first
# (`gh auth token` reads the stored token, no network), then with the slower
# `auth status` for old CLI versions. `gh auth status` alone exits 1 as soon
# as any other account or host has a problem, hence not used first.
has_cli() {
  local host
  host=$(_wt_remote_host)
  if [[ "$(detect_platform)" == "gitlab" ]]; then
    command -v glab &>/dev/null || return 1
    [[ -n "${GITLAB_TOKEN:-}${GLAB_TOKEN:-}${GITLAB_ACCESS_TOKEN:-}" ]] && return 0
    if [[ -n "$host" && -n "$(glab config get token --host "$host" 2>/dev/null)" ]]; then
      return 0
    fi
    if [[ -n "$host" ]] && glab auth status --hostname "$host" &>/dev/null; then
      return 0
    fi
    glab auth status &>/dev/null
  else
    command -v gh &>/dev/null || return 1
    if [[ -n "$host" ]] && gh auth token --hostname "$host" &>/dev/null; then
      return 0
    fi
    gh auth token &>/dev/null && return 0
    gh auth status &>/dev/null
  fi
}

get_cli_name() {
  if [[ "$(detect_platform)" == "gitlab" ]]; then echo "glab"; else echo "gh"; fi
}

get_pr_term() {
  if [[ "$(detect_platform)" == "gitlab" ]]; then echo "MR"; else echo "PR"; fi
}

get_pr_term_long() {
  if [[ "$(detect_platform)" == "gitlab" ]]; then echo "Merge Request"; else echo "Pull Request"; fi
}

get_platform_name() {
  if [[ "$(detect_platform)" == "gitlab" ]]; then echo "GitLab"; else echo "GitHub"; fi
}

# =============================================================================
# Additional dependency checks
# =============================================================================

has_gum() {
  command -v gum &>/dev/null
}

has_jq() {
  command -v jq &>/dev/null
}
