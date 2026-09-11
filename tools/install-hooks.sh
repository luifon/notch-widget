#!/usr/bin/env bash
# Install the git pre-commit secret guard into this clone's .git/hooks.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cp "$ROOT/tools/hooks/pre-commit" "$ROOT/.git/hooks/pre-commit"
chmod +x "$ROOT/.git/hooks/pre-commit"
echo "installed .git/hooks/pre-commit"
