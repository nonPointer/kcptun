#!/usr/bin/env bash
#
# kcptun one-shot downloader
#
# Downloads the latest (or a specified) kcptun release archive from GitHub,
# verifies its SHA1 checksum when possible, and optionally extracts it.
#
# Environment overrides:
#   REPO        GitHub "owner/repo" (default: nonPointer/kcptun)
#   VERSION     Release tag without leading 'v' (default: latest)
#   INSTALL_DIR Where to place the archive / extracted binaries (default: .)
#   EXTRACT     If set to 1, extract the archive after download (default: 0)
#   GITHUB_TOKEN  Optional, used to raise GitHub API rate limit
#
# Exit codes:
#   0 success
#   1 unsupported OS/arch
#   2 network / API error
#   3 checksum mismatch

set -euo pipefail

REPO="${REPO:-nonPointer/kcptun}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)}"
EXTRACT="${EXTRACT:-0}"

log()  { printf '\033[1;34m[kcptun]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[kcptun]\033[0m %s\n' "$*" >&2; }
die()  { err "$1"; exit "${2:-1}"; }

command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
command -v tar  >/dev/null 2>&1 || die "tar is required but not installed."

# --- Detect OS -------------------------------------------------------------
OS_RAW=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS_RAW" in
    linux)                 OS="linux"   ;;
    darwin)                OS="darwin"  ;;
    freebsd)               OS="freebsd" ;;
    mingw*|msys*|cygwin*)  OS="windows" ;;
    *) die "Unsupported OS: $OS_RAW" 1 ;;
esac

# --- Detect ARCH -----------------------------------------------------------
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64|amd64)                ARCH="amd64"   ;;
    i386|i686)                   ARCH="386"     ;;
    aarch64|arm64)               ARCH="arm64"   ;;
    armv5*)                      ARCH="arm5"    ;;
    armv6*)                      ARCH="arm6"    ;;
    armv7*|armv8l)               ARCH="arm7"    ;;
    loongarch64|loong64)         ARCH="loong64" ;;
    mips)                        ARCH="mips"    ;;
    mipsel|mipsle)               ARCH="mipsle"  ;;
    *) die "Unsupported architecture: $ARCH_RAW" 1 ;;
esac

# --- Resolve version -------------------------------------------------------
API_HEADERS=(-H "Accept: application/vnd.github+json")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    API_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

if [[ -z "${VERSION:-}" ]]; then
    log "Querying latest release from ${REPO}..."
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
    TAG=$(curl -fsSL "${API_HEADERS[@]}" "$API_URL" \
          | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
          | head -n1)
    [[ -n "$TAG" ]] || die "Failed to resolve latest release tag from $API_URL" 2
    VERSION="${TAG#v}"
else
    TAG="v${VERSION#v}"
    VERSION="${VERSION#v}"
fi
log "Resolved version: ${TAG}"

# --- Build download URL ----------------------------------------------------
FILENAME="kcptun-${OS}-${ARCH}-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${FILENAME}"
CHECKSUM_URL="https://github.com/${REPO}/releases/download/${TAG}/SHA1SUMS"

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

log "Downloading ${FILENAME}"
log "  from ${DOWNLOAD_URL}"
if ! curl -fL --retry 3 --retry-delay 2 -o "${FILENAME}" "${DOWNLOAD_URL}"; then
    die "Download failed. Check that ${OS}/${ARCH} is published in ${TAG}." 2
fi

# --- Verify SHA1 checksum if available -------------------------------------
if curl -fsSL --retry 3 -o SHA1SUMS.tmp "${CHECKSUM_URL}" 2>/dev/null; then
    log "Verifying SHA1 checksum..."
    EXPECTED=$(awk -v f="${FILENAME}" '$2==f || $2=="*"f {print $1; exit}' SHA1SUMS.tmp)
    if [[ -z "$EXPECTED" ]]; then
        log "  (no entry for ${FILENAME} in SHA1SUMS, skipping verification)"
    else
        if command -v sha1sum >/dev/null 2>&1; then
            ACTUAL=$(sha1sum "${FILENAME}" | awk '{print $1}')
        elif command -v shasum   >/dev/null 2>&1; then
            ACTUAL=$(shasum -a 1 "${FILENAME}" | awk '{print $1}')
        else
            log "  (no sha1sum/shasum tool found, skipping verification)"
            ACTUAL="$EXPECTED"
        fi
        if [[ "$ACTUAL" != "$EXPECTED" ]]; then
            rm -f SHA1SUMS.tmp
            die "Checksum mismatch: expected $EXPECTED, got $ACTUAL" 3
        fi
        log "  OK (${ACTUAL})"
    fi
    rm -f SHA1SUMS.tmp
else
    log "SHA1SUMS not published for ${TAG}, skipping verification."
fi

log "Saved: ${INSTALL_DIR}/${FILENAME}"

# --- Optional extraction ---------------------------------------------------
if [[ "${EXTRACT}" == "1" ]]; then
    log "Extracting archive..."
    tar -xzf "${FILENAME}"
    log "Extraction complete. Files in ${INSTALL_DIR}/"
fi
