#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -x "$DIR/bats/bin/bats" ]]; then
  echo "BATS is missing, run: git submodule update --init --recursive" >&2
  exit 1
fi

# ./tests/run.sh [file.bats...]: the given files, or every .bats in tests/
# and test_helper/ (submodule dirs excluded), in name order
if [[ $# -gt 0 ]]; then
  exec "$DIR/bats/bin/bats" "$@"
fi
bats_files=()
while IFS= read -r f; do
  bats_files+=("$f")
done < <(find "$DIR" -maxdepth 2 -name "*.bats" ! -path "*/bats/*" ! -path "*/bats-support/*" ! -path "*/bats-assert/*" | sort)
if [[ ${#bats_files[@]} -eq 0 ]]; then
  echo "0 tests, 0 failures"
  exit 0
fi
exec "$DIR/bats/bin/bats" "${bats_files[@]}"
