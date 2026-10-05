#!/usr/bin/env bash
# lib/ui.sh - UI functions using gum (Charmbracelet)
# Requires: gum in PATH, core.sh sourced first (for C_* color vars)

ui_warn() {
  gum log --level warn "$@" >&2
}

ui_error() {
  gum log --level error "$@" >&2
}

# Run a bash function (not an external command) in the background behind a
# gum spinner, and return its stdout.
ui_spin_fn() {
  local title="$1"; shift
  local _tmpfile
  _tmpfile=$(mktemp)
  "$@" > "$_tmpfile" &
  local _pid=$!
  gum spin --spinner dot --title "$title" -- bash -c "while kill -0 $_pid 2>/dev/null; do sleep 0.1; done" >&2
  wait "$_pid"
  local _ret=$?
  cat "$_tmpfile"
  rm -f "$_tmpfile"
  return $_ret
}

ui_confirm() {
  gum confirm \
    --selected.background 208 \
    --selected.foreground 0 \
    --unselected.background "" \
    --unselected.foreground 208 \
    "$@"
}

# ui_input <prompt> [placeholder] [initial value]
ui_input() {
  local prompt="${1:-}"
  local placeholder="${2:-}"
  local value="${3:-}"
  local args=()
  [[ -n "$prompt" ]] && args+=(--prompt "$prompt ")
  [[ -n "$placeholder" ]] && args+=(--placeholder "$placeholder")
  [[ -n "$value" ]] && args+=(--value "$value")
  gum input ${args[@]+"${args[@]}"}
}

ui_box() {
  gum style --border rounded --padding "0 1" "$@" >&2
}

# Print the logo - responsive: full / medium / small depending on terminal width
print_logo() {
  local assets_dir="$SCRIPT_DIR/assets"
  # Homebrew / Nix: assets/ lives in <prefix>/assets/worktigre, next to bin/
  if [[ ! -d "$assets_dir" ]] || [[ ! -f "$assets_dir/logo.ansi" ]]; then
    assets_dir="$(dirname "$SCRIPT_DIR")/assets/worktigre"
  fi

  if [[ ! -f "$assets_dir/logo.ansi" ]] || [[ ! -t 2 ]] || [[ "${TERM:-}" == "dumb" ]]; then
    echo -e "\033[1;38;5;208m  worktigre\033[0m" >&2
    return
  fi

  local cols
  cols=$(stty size </dev/tty 2>/dev/null | cut -d' ' -f2)
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  local logo_file
  if (( cols >= 125 )); then
    logo_file="$assets_dir/logo.ansi"
  elif (( cols >= 54 )); then
    logo_file="$assets_dir/logo-medium.ansi"
  else
    logo_file="$assets_dir/logo-small.ansi"
  fi

  while IFS= read -r line; do
    echo -e "${line}" >&2
  done < "$logo_file"
}
