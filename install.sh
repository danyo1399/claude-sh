#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# install.sh
# Copies all non-draft scripts into ~/.local/bin so they are available
# on the user's PATH.
#
# Usage:
#   ./install.sh
# -------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"

mkdir -p "$INSTALL_DIR"

installed=0

while IFS= read -r -d '' script; do
  name="$(basename "$script")"
  cp "$script" "${INSTALL_DIR}/${name}"
  chmod +x "${INSTALL_DIR}/${name}"
  echo "  installed: ${name}"
  ((installed++))
done < <(find "$SCRIPT_DIR" -name '*.sh' -not -path '*/draft/*' -not -name 'install.sh' -print0)

echo ""
echo "── ${installed} script(s) installed to ${INSTALL_DIR} ──"
