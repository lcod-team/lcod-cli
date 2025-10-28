#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

LCOD_STATE_DIR="${LCOD_STATE_DIR:-${HOME}/.lcod}"
LCOD_BIN_DIR="${LCOD_BIN_DIR:-${LCOD_STATE_DIR}/bin}"
LCOD_CACHE_DIR="${LCOD_CACHE_DIR:-${LCOD_STATE_DIR}/cache}"
LCOD_CONFIG="${LCOD_CONFIG:-${LCOD_STATE_DIR}/config.json}"
LCOD_UPDATE_STAMP="${LCOD_STATE_DIR}/last-update"
LCOD_VERSION_CACHE="${LCOD_STATE_DIR}/latest-version.json"

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

require_command() {
  local cmd="$1"
  local help_msg="${2:-Install the missing command and retry.}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "'${cmd}' is required. ${help_msg}"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "${LCOD_STATE_DIR}" "${LCOD_BIN_DIR}" "${LCOD_CACHE_DIR}"
}

ensure_config() {
  if [[ ! -f "${LCOD_CONFIG}" ]]; then
    cat <<'JSON' > "${LCOD_CONFIG}"
{
  "defaultKernel": null,
  "installedKernels": [],
  "lastUpdateCheck": null
}
JSON
  fi
}

ensure_environment() {
  require_command jq "Install jq to parse LCOD configuration files."
  ensure_dirs
  ensure_config
}

fetch_latest_version() {
  local release_repo="${1:-lcod-dev/lcod-release}"
  local version_url="https://raw.githubusercontent.com/${release_repo}/main/VERSION"
  curl -fsSL "${version_url}" 2>/dev/null
}

detect_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)

  case "${os}" in
    linux)
      case "${arch}" in
        x86_64|amd64) echo "linux-x86_64" ;;
        aarch64|arm64) echo "linux-arm64" ;;
        *) log_error "Unsupported Linux architecture: ${arch}"; return 1 ;;
      esac
      ;;
    darwin)
      case "${arch}" in
        x86_64|amd64) echo "macos-x86_64" ;;
        arm64) echo "macos-arm64" ;;
        *) log_error "Unsupported macOS architecture: ${arch}"; return 1 ;;
      esac
      ;;
    msys*|mingw*|cygwin*)
      case "${arch}" in
        x86_64|amd64) echo "windows-x86_64" ;;
        arm64) echo "windows-arm64" ;;
        *) log_error "Unsupported Windows architecture: ${arch}"; return 1 ;;
      esac
      ;;
    *)
      log_error "Unsupported operating system: ${os}"
      return 1
      ;;
  esac
}

make_release_asset_url() {
  local repo="${1:?repo required}"
  local version="${2:?version required}"
  local platform="${3:?platform required}"
  local extension
  extension=$(release_asset_extension "${platform}") || return 1
  local base="https://github.com/${repo}/releases/download"
  printf "%s/lcod-run-v%s/lcod-run-%s.%s" "${base}" "${version}" "${platform}" "${extension}"
}

release_asset_extension() {
  local platform="${1:?platform required}"
  case "${platform}" in
    windows-*) echo "zip" ;;
    *) echo "tar.gz" ;;
  esac
}

download_file() {
  require_command curl "Install curl to download LCOD assets."
  local url="${1:?url required}"
  local output="${2:?output path required}"
  curl -fL --progress-bar "${url}" -o "${output}"
}

extract_archive() {
  local archive="${1:?archive required}"
  local destination="${2:?destination required}"
  local extension
  extension="${archive##*.}"
  mkdir -p "${destination}"
  case "${extension}" in
    zip)
      require_command unzip "Install unzip to extract Windows archives."
      unzip -o "${archive}" -d "${destination}" >/dev/null
      ;;
    gz)
      require_command tar "Install tar to extract LCOD archives."
      tar -xzf "${archive}" -C "${destination}"
      ;;
    *)
      log_error "Unsupported archive format: ${archive}"
      return 1
      ;;
  esac
}

update_version_cache() {
  ensure_environment
  local release_repo="${1:-lcod-dev/lcod-release}"
  local version
  if ! version=$(fetch_latest_version "${release_repo}"); then
    return 1
  fi
  local iso
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat <<JSON > "${LCOD_VERSION_CACHE}"
{
  "version": "${version}",
  "source": "${release_repo}",
  "fetchedAt": "${iso}"
}
JSON
  touch_update_stamp
  printf '%s' "${version}"
}

get_cached_remote_version() {
  if [[ -f "${LCOD_VERSION_CACHE}" ]]; then
    jq -r '.version // empty' "${LCOD_VERSION_CACHE}" 2>/dev/null || true
  fi
}

get_cached_version_timestamp() {
  if [[ -f "${LCOD_VERSION_CACHE}" ]]; then
    jq -r '.fetchedAt // empty' "${LCOD_VERSION_CACHE}" 2>/dev/null || true
  fi
}

needs_update() {
  local period_days="${1:-1}"
  if [[ ! -f "${LCOD_UPDATE_STAMP}" ]]; then
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 <<PY
import os, time, sys
stamp = os.path.getmtime("${LCOD_UPDATE_STAMP}")
threshold = time.time() - (${period_days} * 86400)
sys.exit(0 if stamp < threshold else 1)
PY
    return $?
  fi

  local now stamp threshold
  now=$(date +%s)
  stamp=$(date -r "${LCOD_UPDATE_STAMP}" +%s 2>/dev/null || echo 0)
  threshold=$(( now - period_days * 86400 ))
  [[ "${stamp}" -lt "${threshold}" ]]
}

touch_update_stamp() {
  ensure_environment
  local iso
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s\n' "${iso}" > "${LCOD_UPDATE_STAMP}"
  local tmp
  tmp=$(mktemp)
  jq --arg ts "${iso}" '.lastUpdateCheck = $ts' "${LCOD_CONFIG}" > "${tmp}"
  mv "${tmp}" "${LCOD_CONFIG}"
}

config_get_default_kernel() {
  jq -r '.defaultKernel // ""' "${LCOD_CONFIG}"
}

config_set_default_kernel() {
  ensure_environment
  local kernel_id="${1:-}"
  local tmp
  tmp=$(mktemp)
  if [[ -z "${kernel_id}" ]]; then
    jq '.defaultKernel = null' "${LCOD_CONFIG}" > "${tmp}"
  else
    jq --arg id "${kernel_id}" '.defaultKernel = $id' "${LCOD_CONFIG}" > "${tmp}"
  fi
  mv "${tmp}" "${LCOD_CONFIG}"
}

config_kernel_exists() {
  local kernel_id="${1:-}"
  jq -e --arg id "${kernel_id}" '.installedKernels[]? | select(.id == $id)' "${LCOD_CONFIG}" >/dev/null 2>&1
}

clear_quarantine_if_needed() {
  local target="${1:-}"
  if [[ -z "${target}" || ! -e "${target}" ]]; then
    return
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v xattr >/dev/null 2>&1; then
      if ! xattr -cr "${target}" 2>/dev/null; then
        log_warn "Failed to clear quarantine attributes on ${target}"
      fi
    fi
  fi
}

config_add_or_update_kernel() {
  ensure_environment
  local kernel_id="${1:?kernel id required}"
  local kernel_version="${2:-}"
  local kernel_path="${3:?kernel path required}"

  local tmp
  tmp=$(mktemp)
  jq \
    --arg id "${kernel_id}" \
    --arg version "${kernel_version}" \
    --arg path "${kernel_path}" \
    '
      .installedKernels =
        ([.installedKernels[]? | select(.id != $id)] + [{
          id: $id,
          version: (if $version == "" then null else $version end),
          path: $path
        }])
      | (if (.defaultKernel == null or .defaultKernel == "") then (.defaultKernel = $id) else . end)
    ' "${LCOD_CONFIG}" > "${tmp}"
  mv "${tmp}" "${LCOD_CONFIG}"
}

config_remove_kernel() {
  ensure_environment
  local kernel_id="${1:?kernel id required}"
  local tmp
  tmp=$(mktemp)
  jq --arg id "${kernel_id}" '
    .installedKernels = [.installedKernels[]? | select(.id != $id)] |
    (if .defaultKernel == $id then
      (if (.installedKernels | length) > 0 then
         (.defaultKernel = (.installedKernels[0].id))
       else
         (.defaultKernel = null)
       end)
     else . end)
  ' "${LCOD_CONFIG}" > "${tmp}"
  mv "${tmp}" "${LCOD_CONFIG}"
}

config_list_kernels() {
  jq '.' "${LCOD_CONFIG}"
}

config_get_kernel_path() {
  local kernel_id="${1:?kernel id required}"
  jq -r --arg id "${kernel_id}" '
    (.installedKernels[]? | select(.id == $id) | .path) // empty
  ' "${LCOD_CONFIG}"
}
