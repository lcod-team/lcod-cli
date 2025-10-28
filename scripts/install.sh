#!/usr/bin/env bash
set -euo pipefail

BASE_URL=${LCOD_BASE_URL:-https://raw.githubusercontent.com/lcod-team/lcod-cli/main}
SCRIPT_NAME=${LCOD_INSTALL_NAME:-lcod}
PS_SCRIPT_NAME=lcod.ps1
SOURCE_DIR=${LCOD_SOURCE:-}
TARGET_OVERRIDE=${LCOD_INSTALL_DIR:-}
INSTALL_POWERSHELL=${LCOD_INSTALL_POWERSHELL:-1}
STATE_DIR=${LCOD_STATE_DIR:-${HOME}/.lcod}
CLI_UPDATE_CACHE="${STATE_DIR}/cli-update.json"

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

info() {
  printf '[install] %s\n' "$*"
}

err() {
  printf '[install] %s\n' "$*" >&2
}

fetch_asset() {
  local relative="$1"
  local destination="$2"
  if [[ -n "${SOURCE_DIR}" && -f "${SOURCE_DIR}/${relative}" ]]; then
    cp "${SOURCE_DIR}/${relative}" "${destination}"
  else
    local url="${BASE_URL}/${relative}"
    curl -fsSL "${url}" -o "${destination}"
  fi
}

unique_dirs() {
  declare -A seen=()
  local dir
  for dir in "$@"; do
    [[ -z "${dir}" ]] && continue
    dir=$(printf '%s' "${dir}" | sed 's:/*$::')
    if [[ -z "${dir}" ]]; then
      continue
    fi
    if [[ -z "${seen["$dir"]+x}" ]]; then
      printf '%s\n' "$dir"
      seen["$dir"]=1
    fi
  done
}

select_target_dir() {
  local candidates=()

  if [[ -n "${TARGET_OVERRIDE}" ]]; then
    candidates+=("${TARGET_OVERRIDE}")
  fi

  local existing
  if existing=$(command -v "${SCRIPT_NAME}" 2>/dev/null); then
    candidates+=("$(dirname "${existing}")")
  fi

  candidates+=("${HOME}/.local/bin" "${HOME}/bin")

  IFS=':' read -r -a path_entries <<< "${PATH}"
  for entry in "${path_entries[@]}"; do
    [[ -z "${entry}" ]] && continue
    if [[ "${entry}" == "${HOME}"/* && -d "${entry}" ]]; then
      candidates+=("${entry}")
    fi
  done

  unique_dirs "${candidates[@]}"
}

install_script() {
  local target_dir="$1"
  mkdir -p "${target_dir}"
  if [[ ! -w "${target_dir}" ]]; then
    return 1
  fi

  local target="${target_dir}/${SCRIPT_NAME}"
  cp "${TMP_DIR}/${SCRIPT_NAME}" "${target}"
  chmod +x "${target}"
  printf '%s' "${target}"
  return 0
}

install_powershell() {
  local target_dir="$1"
  local ps_target="${target_dir}/${PS_SCRIPT_NAME}"
  fetch_asset "powershell/${PS_SCRIPT_NAME}" "${TMP_DIR}/${PS_SCRIPT_NAME}"
  cp "${TMP_DIR}/${PS_SCRIPT_NAME}" "${ps_target}"
  if command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
    cat > "${target_dir}/lcod.cmd" <<'BAT'
@echo off
pwsh -NoProfile -File "%~dp0\lcod.ps1" %*
BAT
  fi
}

main() {
  fetch_asset "scripts/${SCRIPT_NAME}" "${TMP_DIR}/${SCRIPT_NAME}"
  chmod +x "${TMP_DIR}/${SCRIPT_NAME}"

  local cli_version=""
  if [[ -n "${SOURCE_DIR}" && -f "${SOURCE_DIR}/VERSION" ]]; then
    cli_version=$(<"${SOURCE_DIR}/VERSION")
  else
    fetch_asset "VERSION" "${TMP_DIR}/VERSION"
    cli_version=$(<"${TMP_DIR}/VERSION")
  fi
  cli_version=$(printf '%s' "${cli_version}" | tr -d '\r\n')
  if [[ -z "${cli_version}" ]]; then
    cli_version="dev"
  fi

  local installed_path=""
  local dir
  while read -r dir; do
    [[ -z "${dir}" ]] && continue
    if installed_path=$(install_script "${dir}"); then
      info "Installed ${SCRIPT_NAME} to ${installed_path}"
      if [[ "${INSTALL_POWERSHELL}" == "1" ]]; then
        install_powershell "${dir}" 2>/dev/null || true
      fi
      if [[ ":${PATH}:" != *":${dir}:"* ]]; then
        info "Add ${dir} to your PATH to use 'lcod' globally."
      fi
      mkdir -p "${STATE_DIR}"
      local epoch
      epoch=$(date -u +%s)
      if command -v jq >/dev/null 2>&1; then
        jq -n --arg version "${cli_version}" --argjson lastCheck "${epoch}" '{version:$version,lastCheck:$lastCheck}' > "${CLI_UPDATE_CACHE}"
      else
        printf '{"version":"%s","lastCheck":%s}\n' "${cli_version}" "${epoch}" > "${CLI_UPDATE_CACHE}"
      fi
      return 0
    fi
  done < <(select_target_dir)

  err "Could not find a writable directory in PATH. Set LCOD_INSTALL_DIR to override."
  return 1
}

main "$@"
