#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_TEST="${ROOT_DIR}/tests/run-projection.sh"

if [[ ! -x "${BASH_TEST}" ]]; then
  echo "[skip] CLI projection tests not available."
  exit 0
fi

CLI_BASH="${ROOT_DIR}/scripts/lcod"
"${BASH_TEST}" --cli "${CLI_BASH}" --label "bash scripts/lcod"

CLI_DIST="${ROOT_DIR}/dist/lcod"
if [[ -x "${CLI_DIST}" ]]; then
  "${BASH_TEST}" --cli "${CLI_DIST}" --label "bash dist/lcod"
else
  echo "[skip] dist/lcod: bundle not present."
fi

if command -v pwsh >/dev/null 2>&1; then
  LCOD_TEST_KERNEL_PATH="${LCOD_TEST_KERNEL_PATH:-${HOME}/.lcod/bin/rs}" pwsh -NoLogo -File "${ROOT_DIR}/tests/run-projection.ps1"
elif command -v powershell >/dev/null 2>&1; then
  LCOD_TEST_KERNEL_PATH="${LCOD_TEST_KERNEL_PATH:-${HOME}/.lcod/bin/rs}" powershell -NoLogo -File "${ROOT_DIR}/tests/run-projection.ps1"
else
  echo "[skip] PowerShell projection test (pwsh not available)."
fi
