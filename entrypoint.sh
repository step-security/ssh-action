#!/usr/bin/env bash

set -euo pipefail

export GITHUB="true"

GITHUB_ACTION_PATH="${GITHUB_ACTION_PATH%/}"
DRONE_SSH_RELEASE_URL="${DRONE_SSH_RELEASE_URL:-https://github.com/appleboy/drone-ssh/releases/download}"
DRONE_SSH_VERSION="${DRONE_SSH_VERSION:-1.8.2}"

# Error codes
readonly ERR_UNKNOWN_PLATFORM=2
readonly ERR_UNKNOWN_ARCH=3
readonly ERR_DOWNLOAD_FAILED=4
readonly ERR_INVALID_BINARY=5
readonly ERR_VERSION_CHECK_FAILED=6
readonly ERR_CHECKSUM_DOWNLOAD_FAILED=7
readonly ERR_CHECKSUM_NOT_FOUND=8
readonly ERR_CHECKSUM_MISMATCH=9

function log_error() {
  echo "$1" >&2
  exit "$2"
}

function sha256_file() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    log_error "No SHA256 utility found (sha256sum or shasum required)." "${ERR_INVALID_BINARY}"
  fi
}

function verify_checksum() {
  local binary="$1"
  local binary_name="$2"
  local checksums_url="$3"
  local checksums_file="${binary}.checksums"

  if ! curl -fsSL --retry 5 --keepalive-time 2 --location \
    "${checksums_url}" -o "${checksums_file}"; then
    rm -f "${binary}"
    log_error "Failed to download checksums.txt from ${checksums_url}." "${ERR_CHECKSUM_DOWNLOAD_FAILED}"
  fi

  local expected
  expected=$(grep -E "^[a-f0-9]+  ${binary_name}$" "${checksums_file}" | awk '{print $1}')
  rm -f "${checksums_file}"

  if [[ -z "${expected}" ]]; then
    rm -f "${binary}"
    log_error "Binary ${binary_name} not found in checksums.txt." "${ERR_CHECKSUM_NOT_FOUND}"
  fi

  local actual
  actual=$(sha256_file "${binary}")

  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${binary}"
    log_error "Checksum mismatch for ${binary_name}. Expected: ${expected}, Got: ${actual}" "${ERR_CHECKSUM_MISMATCH}"
  fi

  echo "Checksum verified: ${binary_name}"
}

function detect_client_info() {
  CLIENT_PLATFORM="${SSH_CLIENT_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
  CLIENT_ARCH="${SSH_CLIENT_ARCH:-$(uname -m)}"

  case "${CLIENT_PLATFORM}" in
  darwin | linux | windows) ;;
  *) log_error "Unknown or unsupported platform: ${CLIENT_PLATFORM}. Supported platforms are Linux, Darwin, and Windows." "${ERR_UNKNOWN_PLATFORM}" ;;
  esac

  case "${CLIENT_ARCH}" in
  x86_64* | i?86_64* | amd64*) CLIENT_ARCH="amd64" ;;
  aarch64* | arm64*) CLIENT_ARCH="arm64" ;;
  *) log_error "Unknown or unsupported architecture: ${CLIENT_ARCH}. Supported architectures are x86_64, i686, and arm64." "${ERR_UNKNOWN_ARCH}" ;;
  esac
}

detect_client_info
DOWNLOAD_URL_PREFIX="${DRONE_SSH_RELEASE_URL}/v${DRONE_SSH_VERSION}"
CLIENT_BINARY="drone-ssh-${DRONE_SSH_VERSION}-${CLIENT_PLATFORM}-${CLIENT_ARCH}"
TARGET="${GITHUB_ACTION_PATH}/${CLIENT_BINARY}"

INSECURE_OPTION=""
if [[ "${INPUT_CURL_INSECURE}" == 'true' ]]; then
  INSECURE_OPTION="--insecure"
fi

# Check if binary already exists and is executable (caching)
if [[ -f "${TARGET}" ]] && [[ -x "${TARGET}" ]]; then
  echo "Binary ${CLIENT_BINARY} already exists, skipping download"
else
  echo "Downloading ${CLIENT_BINARY} from ${DOWNLOAD_URL_PREFIX}"

  # Download with better error handling
  if ! curl -fsSL --retry 5 --keepalive-time 2 --location ${INSECURE_OPTION} \
    "${DOWNLOAD_URL_PREFIX}/${CLIENT_BINARY}" -o "${TARGET}"; then
    log_error "Failed to download ${CLIENT_BINARY} from ${DOWNLOAD_URL_PREFIX}. Please check the URL and your network connection." "${ERR_DOWNLOAD_FAILED}"
  fi

  # Validate downloaded file
  if [[ ! -f "${TARGET}" ]] || [[ ! -s "${TARGET}" ]]; then
    log_error "Downloaded file is missing or empty: ${TARGET}" "${ERR_INVALID_BINARY}"
  fi

  verify_checksum "${TARGET}" "${CLIENT_BINARY}" "${DOWNLOAD_URL_PREFIX}/checksums.txt"

  chmod +x "${TARGET}"
fi

echo "======= CLI Version Information ======="
if ! "${TARGET}" --version; then
  log_error "Failed to execute ${TARGET} --version. The binary may be corrupted." "${ERR_VERSION_CHECK_FAILED}"
fi
echo "======================================="
if [[ "${INPUT_CAPTURE_STDOUT}" == 'true' ]]; then
  echo 'stdout<<EOF' >> "${GITHUB_OUTPUT}"
  "${TARGET}" "$@" | tee -a "${GITHUB_OUTPUT}"
  echo 'EOF' >> "${GITHUB_OUTPUT}"
else
  "${TARGET}" "$@"
fi
