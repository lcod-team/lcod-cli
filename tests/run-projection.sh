#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: run-projection.sh [--cli <path>] [--label <name>] [--compose <id>]

Environment:
  LCOD_TEST_KERNEL_PATH  Path to the kernel binary to exercise (default: ~/.lcod/bin/rs).
  LCOD_TEST_SPEC_PATH    Optional override for the spec repository location.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_CLI="${ROOT_DIR}/scripts/lcod"
CLI_PATH="${DEFAULT_CLI}"
LABEL="scripts/lcod"
COMPOSE_ID="lcod://tooling/json/decode_object@0.1.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli)
      CLI_PATH="${2:-}"
      shift 2 || usage
      ;;
    --label)
      LABEL="${2:-}"
      shift 2 || usage
      ;;
    --compose)
      COMPOSE_ID="${2:-}"
      shift 2 || usage
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${CLI_PATH}" || ! -x "${CLI_PATH}" ]]; then
  echo "[skip] ${LABEL}: CLI entrypoint not executable (${CLI_PATH})."
  exit 0
fi

KERNEL_PATH="${LCOD_TEST_KERNEL_PATH:-${HOME}/.lcod/bin/rs}"
export KERNEL_PATH
if [[ ! -x "${KERNEL_PATH}" ]]; then
  echo "[skip] ${LABEL}: kernel binary not found at ${KERNEL_PATH}."
  exit 0
fi

SPEC_PATH="${LCOD_TEST_SPEC_PATH:-}"
if [[ -z "${SPEC_PATH}" ]]; then
  if [[ -d "${ROOT_DIR}/../lcod-spec" ]]; then
    SPEC_PATH="$(cd "${ROOT_DIR}/../lcod-spec" && pwd)"
  fi
fi

STATE_DIR="$(mktemp -d)"

export LCOD_STATE_DIR="${STATE_DIR}"
export LCOD_BIN_DIR="${STATE_DIR}/bin"
export LCOD_CACHE_DIR="${STATE_DIR}/cache"
export LCOD_AUTO_UPDATE_INTERVAL=31536000
mkdir -p "${LCOD_BIN_DIR}" "${LCOD_CACHE_DIR}"

if [[ -n "${SPEC_PATH}" ]]; then
  if [[ -z "${SPEC_REPO_PATH:-}" ]]; then
    export SPEC_REPO_PATH="${SPEC_PATH}"
  fi
  if [[ -z "${LCOD_HOME:-}" ]]; then
    export LCOD_HOME="${SPEC_PATH}"
  fi
  if [[ -z "${LCOD_RESOLVER_PATH:-}" ]]; then
    export LCOD_RESOLVER_PATH="${SPEC_PATH}/resolver"
  fi
fi

CONFIG_PATH="${STATE_DIR}/config.json"
export CONFIG_PATH
python3 <<'PY'
import json
import os

config_path = os.environ["CONFIG_PATH"]
kernel_path = os.environ["KERNEL_PATH"]

with open(config_path, "w", encoding="utf-8") as fh:
    json.dump(
        {
            "defaultKernel": "test-rs",
            "installedKernels": [
                {
                    "id": "test-rs",
                    "version": "dev-local",
                    "path": kernel_path,
                }
            ],
            "lastUpdateCheck": None,
        },
        fh,
        indent=2,
    )
    fh.write("\n")
PY
export CONFIG_PATH KERNEL_PATH
export LCOD_CONFIG="${CONFIG_PATH}"

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"

cleanup() {
  rm -rf "${STATE_DIR}"
  rm -f "${stdout_file}" "${stderr_file}"
}
if [[ "${LCOD_TEST_KEEP_TMP:-0}" != "1" ]]; then
  trap cleanup EXIT
else
  echo "[debug] STATE_DIR=${STATE_DIR}" >&2
  echo "[debug] STDOUT_FILE=${stdout_file}" >&2
  echo "[debug] STDERR_FILE=${stderr_file}" >&2
fi

inline_arg='text={"success":true}'
set +e
"${CLI_PATH}" run "${COMPOSE_ID}" "${inline_arg}" >"${stdout_file}" 2>"${stderr_file}"
status=$?
set -e

if [[ "${status}" -ne 0 ]]; then
  echo "[stdout file: ${stdout_file}]" >&2
  cat "${stdout_file}" >&2 || true
  echo "[stderr file: ${stderr_file}]" >&2
  cat "${stderr_file}" >&2 || true
  echo "[fail] ${LABEL}: lcod run exited with status ${status}." >&2
  exit "${status}"
fi

output="$(cat "${stdout_file}")"

if ! echo "${output}" | jq -e . >/dev/null 2>&1; then
  echo "[fail] ${LABEL}: output is not valid JSON." >&2
  echo "${output}" >&2
  exit 1
fi

expected_keys='["error","value","warnings"]'
actual_keys="$(echo "${output}" | jq -c 'keys | sort')"
if [[ "${actual_keys}" != "${expected_keys}" ]]; then
  echo "[fail] ${LABEL}: unexpected JSON keys ${actual_keys} (expected ${expected_keys})." >&2
  echo "${output}" >&2
  exit 1
fi

if ! echo "${output}" | jq -e '.error == null' >/dev/null; then
  echo "[fail] ${LABEL}: error field is not null." >&2
  echo "${output}" >&2
  exit 1
fi

if ! echo "${output}" | jq -e '.value.success == true' >/dev/null; then
  echo "[fail] ${LABEL}: value.success != true." >&2
  echo "${output}" >&2
  exit 1
fi

if ! echo "${output}" | jq -e '.warnings | type == "array" and length == 0' >/dev/null; then
  echo "[fail] ${LABEL}: warnings array not empty." >&2
  echo "${output}" >&2
  exit 1
fi

if echo "${output}" | jq -e 'has("text")' >/dev/null; then
  echo "[fail] ${LABEL}: detected unexpected \"text\" field in output." >&2
  echo "${output}" >&2
  exit 1
fi

if [[ -s "${stderr_file}" && -n "$(tr -d '[:space:]' < "${stderr_file}")" ]]; then
  echo "[info] ${LABEL}: stderr output during run:" >&2
  cat "${stderr_file}" >&2
fi

echo "[pass] ${LABEL}: output projection verified."
