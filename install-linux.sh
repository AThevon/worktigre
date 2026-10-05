#!/bin/bash

# Redirect to the universal installer, kept so old links keep working.
# It always downloads install.sh and never runs a local file: with
# `curl .../install-linux.sh | bash` the current directory is unrelated.

set -eo pipefail

INSTALLER_URL="https://raw.githubusercontent.com/AThevon/worktigre/main/install.sh"

echo "Downloading installer..." >&2
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$INSTALLER_URL" | bash
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "$INSTALLER_URL" | bash
else
  echo "Neither curl nor wget found - cannot download $INSTALLER_URL" >&2
  exit 1
fi
