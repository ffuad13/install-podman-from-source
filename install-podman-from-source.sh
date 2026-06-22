#!/usr/bin/env bash
set -euo pipefail

#######################################
# Config (override via env or flags)
#######################################
PODMAN_VERSION_DEFAULT="v5.8.3"
GO_VERSION_DEFAULT="1.26.4"

PODMAN_VERSION="${PODMAN_VERSION:-$PODMAN_VERSION_DEFAULT}"
GO_VERSION="${GO_VERSION:-$GO_VERSION_DEFAULT}"
WORKDIR="${WORKDIR:-$HOME/src/podman-from-source}"

DRY_RUN=0
NONINTERACTIVE=0
RESET_STATE=0
CLEAN_WORKDIR=0
CLEAN_AFTER=0
CLEAN_ONLY=0
KEEP_GO=0
KEEP_RUST=0

STATE_DIR="" # set after WORKDIR is ensured

#######################################
# Logging / helpers
#######################################
log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [DRY RUN]'
    printf ' %q' "$@"
    printf '\n'
  else
    printf '  [RUN]'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  fi
}

trap 'die "command failed at line $LINENO: $BASH_COMMAND"' ERR

#######################################
# Step caching helpers
#######################################
step_done() {
  local name="$1"
  [ -n "${STATE_DIR:-}" ] && [ -f "${STATE_DIR}/${name}.done" ]
}

mark_step_done() {
  local name="$1"
  [ "$DRY_RUN" -eq 1 ] && return
  [ -z "${STATE_DIR:-}" ] && return
  mkdir -p "$STATE_DIR"
  : >"${STATE_DIR}/${name}.done"
}

#######################################
# Argument parsing
#######################################
usage() {
  cat >&2 <<EOF
Usage: $0 [options]

Options:
  --dry-run, -n          Print what would be done, but do not execute
  --yes, -y              Non-interactive; assume "yes" to prompts
  --podman-version=VAL   Podman git tag (default: ${PODMAN_VERSION_DEFAULT})
  --go-version=VAL       Go version for installer (default: ${GO_VERSION_DEFAULT})
  --no-cache, --force    Ignore cached step state and re-run all steps
  --clean-workdir        Remove the entire WORKDIR before running (except in dry-run)
  --cleanup-after       Run cleanup of build deps/toolchains after successful build
  --cleanup-only        Only run cleanup (no build steps)
  --keep-go             Keep Go toolchain and Go env config during cleanup
  --keep-rust           Keep Rust toolchain and Rust env config during cleanup
  -h, --help             Show this help

Environment overrides:
  PODMAN_VERSION   Podman git tag
  GO_VERSION       Go version
  WORKDIR          Workspace directory (default: \$HOME/src/podman-from-source)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --dry-run | -n)
    DRY_RUN=1
    shift
    ;;
  --yes | -y | --non-interactive)
    NONINTERACTIVE=1
    shift
    ;;
  --podman-version=*)
    PODMAN_VERSION="${1#*=}"
    shift
    ;;
  --go-version=*)
    GO_VERSION="${1#*=}"
    shift
    ;;
  --no-cache | --force)
    RESET_STATE=1
    shift
    ;;
  --clean-workdir)
    CLEAN_WORKDIR=1
    shift
    ;;
  --cleanup-after)
    CLEAN_AFTER=1
    shift
    ;;
  --cleanup-only)
    CLEAN_ONLY=1
    shift
    ;;
  --keep-go)
    KEEP_GO=1
    shift
    ;;
  --keep-rust)
    KEEP_RUST=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "Unknown argument: $1"
    ;;
  esac
done

#######################################
# Environment checks
#######################################
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ] || { [ "${VERSION_ID:-}" != "22.04" ] && [ "${VERSION_ID:-}" != "24.04" ]; }; then
    die "This script is intended for Ubuntu 22.04 or 24.04; detected ${ID:-unknown} ${VERSION_ID:-unknown}"
  fi
else
  die "/etc/os-release not found; cannot verify OS"
fi

if ! command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  die "'sudo' is required when not running as root"
fi

if ! command -v curl >/dev/null 2>&1; then
  log "'curl' not found; it will be installed via apt"
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

#######################################
# Plan / confirmation
#######################################
cat >&2 <<EOF
Planned actions:

  - Install build-time dependencies via apt
  - Install Go ${GO_VERSION} (via helper script)
  - Clone/build (with caching per step):
      * passt/pasta
      * conmon
      * podman (${PODMAN_VERSION})
      * netavark
      * aardvark-dns
  - Install container config into /etc/containers
  - Install Rust toolchain (rustup) for netavark/aardvark-dns builds
  - Place binaries under:
      * /usr (Podman)
      * /usr/local/libexec/podman (conmon, netavark, aardvark-dns)
  - Workspace directory: ${WORKDIR}
  - State/caching directory: ${WORKDIR}/.state

Dry run:         ${DRY_RUN}
Non-interactive: ${NONINTERACTIVE}
Force (no cache): ${RESET_STATE}
Clean workdir:   ${CLEAN_WORKDIR}
EOF

if [ ! -t 0 ]; then
  NONINTERACTIVE=1
fi

if [ "$NONINTERACTIVE" -ne 1 ]; then
  read -r -p "Proceed with these actions? [y/N] " ans
  case "$ans" in
  y | Y | yes | YES) ;;
  *)
    log "Aborted by user."
    exit 1
    ;;
  esac
fi

# Prepare WORKDIR and state
if [ "$DRY_RUN" -ne 1 ]; then
  if [ "$CLEAN_WORKDIR" -eq 1 ]; then
    log "Cleaning workdir: ${WORKDIR}"
    rm -rf "$WORKDIR"
  fi
  mkdir -p "$WORKDIR"
  STATE_DIR="${WORKDIR}/.state"
  if [ "$RESET_STATE" -eq 1 ]; then
    log "Resetting cached step state in ${STATE_DIR}"
    rm -rf "$STATE_DIR"
  fi
else
  STATE_DIR="${WORKDIR}/.state"
fi

log "Using workspace: ${WORKDIR}"

cleanup_build_env() {
  log "Starting cleanup of build toolchain, env config, and workspace"

  # 4.1 Remove build-time apt packages
  run $SUDO apt-get remove --purge -y \
    gcc make git go-md2man pkg-config protobuf-compiler \
    libassuan-dev libbtrfs-dev libc6-dev libdevmapper-dev \
    libglib2.0-dev libgpgme-dev libgpg-error-dev libprotobuf-dev \
    libprotobuf-c-dev libseccomp-dev libselinux1-dev libsystemd-dev \
    libapparmor-dev || true

  run $SUDO apt-get autoremove -y || true

  # 4.2 Clean Go and Rust env lines from shell rc files
  local rc
  local go_line1='export GOROOT=/home/ubuntu/.go'
  local go_line2='export PATH=$GOROOT/bin:$PATH'
  local go_line3='export GOPATH=/home/ubuntu/go'
  local go_line4='export PATH=$GOPATH/bin:$PATH'
  local cargo_line='. "$HOME/.cargo/env"'

  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue

    if [ "$KEEP_GO" -eq 0 ]; then
      run sed -i "\|^${go_line1}\$|d" "$rc"
      run sed -i "\|^${go_line2}\$|d" "$rc"
      run sed -i "\|^${go_line3}\$|d" "$rc"
      run sed -i "\|^${go_line4}\$|d" "$rc"
    fi

    if [ "$KEEP_RUST" -eq 0 ]; then
      run sed -i "\|^${cargo_line}\$|d" "$rc"
    fi
  done

  # 4.3 Remove Go toolchain and caches (unless kept)
  if [ "$KEEP_GO" -eq 0 ]; then
    run $SUDO rm -rf /usr/local/go
    run rm -rf "${GOPATH:-$HOME/go}"
    run rm -rf "${GOROOT:-$HOME/.go}"
  fi

  # 4.4 Remove Rust toolchain and caches (unless kept)
  if [ "$KEEP_RUST" -eq 0 ]; then
    run rm -rf "$HOME/.rustup" "$HOME/.cargo"
  fi

  # 4.5 Remove build workspace (but keep STATE_DIR if you want cache; here we wipe all)
  run rm -rf "$WORKDIR"

  log "Cleanup finished"
}

#######################################
# Repo helper (shallow clones)
#######################################
clone_or_update_repo() {
  local url="$1"
  local dest="$2"
  local ref="${3:-}" # optional branch/tag for shallow clone

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -d "$dest/.git" ]; then
      log "[DRY RUN] Would update git repo in $dest"
    else
      log "[DRY RUN] Would shallow clone $url into $dest (ref: ${ref:-default})"
    fi
    return
  fi

  if [ -d "$dest/.git" ]; then
    log "Updating existing repo at $dest"
    git -C "$dest" fetch --all --tags --prune
    git -C "$dest" pull --ff-only || true
  else
    log "Cloning $url into $dest (shallow)"
    if [ -n "$ref" ]; then
      git clone --depth 1 --branch "$ref" "$url" "$dest"
    else
      git clone --depth 1 "$url" "$dest"
    fi
  fi
}

#######################################
# Step helpers
#######################################
install_apt_deps() {
  local step="apt_deps"
  if step_done "$step"; then
    log "Skipping apt dependency installation (cached)"
    return
  fi

  log "Installing apt build dependencies"
  run "$SUDO" apt-get update
  run "$SUDO" apt-get install -y \
    btrfs-progs \
    gcc \
    git \
    go-md2man \
    iptables \
    libassuan-dev \
    libbtrfs-dev \
    libc6-dev \
    libdevmapper-dev \
    libglib2.0-dev \
    libgpgme-dev \
    libgpg-error-dev \
    libprotobuf-dev \
    libprotobuf-c-dev \
    libseccomp-dev \
    libselinux1-dev \
    libsystemd-dev \
    make \
    pkg-config \
    runc \
    uidmap \
    libapparmor-dev \
    fuse-overlayfs \
    protobuf-compiler

  mark_step_done "$step"
}

install_go() {
  local step="go_install"
  if step_done "$step"; then
    log "Skipping Go installation (cached)"
    return
  fi

  log "Ensuring Go ${GO_VERSION} is installed"
  if command -v go >/dev/null 2>&1; then
    local current_ver
    current_ver="$(go version | awk '{print $3}' | sed 's/^go//')"
    if [ "$current_ver" = "$GO_VERSION" ]; then
      log "Go ${GO_VERSION} already installed; caching step"
      mark_step_done "$step"
      return
    else
      log "Existing Go version ${current_ver} found; will install ${GO_VERSION} over it"
    fi
  fi

  export GOPATH="${GOPATH:-$HOME/go}"
  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$GOPATH"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY RUN] Would install Go ${GO_VERSION} using https://git.io/vQhTU helper"
    return
  fi

  curl -fsSL https://git.io/vQhTU | bash -s -- --version "${GO_VERSION}"
  export PATH="$GOPATH/bin:$PATH"
  log "Go installation complete: $(go version)"

  mark_step_done "$step"
}

build_passt() {
  local step="passt_build"
  if step_done "$step"; then
    log "Skipping passt/pasta build (cached)"
    return
  fi

  log "Building passt/pasta"
  local dest="${WORKDIR}/passt"
  clone_or_update_repo "https://passt.top/passt" "$dest"

  [ "$DRY_RUN" -eq 1 ] && return

  pushd "$dest" >/dev/null
  run make
  popd >/dev/null

  mark_step_done "$step"
}

build_conmon() {
  local step="conmon_build"
  if step_done "$step"; then
    log "Skipping conmon build (cached)"
    return
  fi

  log "Building conmon"
  local dest="${WORKDIR}/conmon"
  clone_or_update_repo "https://github.com/containers/conmon" "$dest"

  [ "$DRY_RUN" -eq 1 ] && return

  pushd "$dest" >/dev/null
  local gocache
  gocache="$(mktemp -d)"
  export GOCACHE="$gocache"
  run make
  run "$SUDO" make podman
  # cleanup per-step cache
  rm -rf "$gocache" || true
  popd >/dev/null

  mark_step_done "$step"
}

install_containers_config() {
  local step="containers_config"
  if step_done "$step"; then
    log "Skipping /etc/containers config install (cached)"
    return
  fi

  log "Installing /etc/containers config"
  run "$SUDO" mkdir -p /etc/containers
  run "$SUDO" curl -fsSL \
    -o /etc/containers/registries.conf \
    https://raw.githubusercontent.com/containers/image/main/registries.conf
  run "$SUDO" curl -fsSL \
    -o /etc/containers/policy.json \
    https://raw.githubusercontent.com/containers/image/main/default-policy.json

  mark_step_done "$step"
}

install_rust() {
  local step="rust_install"
  if step_done "$step"; then
    log "Skipping Rust toolchain installation (cached)"
    return
  fi

  log "Ensuring Rust toolchain is installed (for netavark/aardvark-dns)"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY RUN] Would install Rust via rustup and set default toolchain"
    return
  fi

  if command -v rustup >/dev/null 2>&1; then
    # rustup already installed: just ensure default toolchain
    rustup default stable
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
    rustup default stable
  fi

  log "Rust installed: cargo $(cargo --version), rustc $(rustc --version)"
  mark_step_done "$step"
}

build_podman() {
  local step="podman_build"
  if step_done "$step"; then
    log "Skipping Podman build (cached)"
    return
  fi

  log "Building Podman ${PODMAN_VERSION}"
  local dest="${WORKDIR}/podman"
  # Shallow clone specific tag/branch
  clone_or_update_repo "https://github.com/containers/podman.git" "$dest" "${PODMAN_VERSION}"

  [ "$DRY_RUN" -eq 1 ] && return

  pushd "$dest" >/dev/null
  # ensure correct tag checked out
  run git fetch --tags
  run git switch --detach "${PODMAN_VERSION}"
  run make BUILDTAGS="selinux seccomp" PREFIX=/usr
  run "$SUDO" env PATH="$PATH" make install PREFIX=/usr
  popd >/dev/null

  mark_step_done "$step"
}

build_netavark() {
  local step="netavark_build"
  if step_done "$step"; then
    log "Skipping netavark build (cached)"
    return
  fi

  log "Building netavark"
  local dest="${WORKDIR}/netavark"
  # main branch, shallow
  clone_or_update_repo "https://github.com/containers/netavark.git" "$dest" "main"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY RUN] Would build netavark and copy to /usr/local/libexec/podman/"
    return
  fi

  # shellcheck disable=SC1090
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
  pushd "$dest" >/dev/null
  run make
  run "$SUDO" mkdir -p /usr/local/libexec/podman
  run "$SUDO" cp ./bin/netavark /usr/local/libexec/podman/
  popd >/dev/null

  mark_step_done "$step"
}

build_aardvark_dns() {
  local step="aardvark_dns_build"
  if step_done "$step"; then
    log "Skipping aardvark-dns build (cached)"
    return
  fi

  log "Building aardvark-dns"
  local dest="${WORKDIR}/aardvark-dns"
  # main branch, shallow
  clone_or_update_repo "https://github.com/containers/aardvark-dns.git" "$dest" "main"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY RUN] Would build aardvark-dns and copy to /usr/local/libexec/podman/"
    return
  fi

  # shellcheck disable=SC1090
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
  pushd "$dest" >/dev/null
  run make
  run "$SUDO" mkdir -p /usr/local/libexec/podman
  run "$SUDO" cp ./bin/aardvark-dns /usr/local/libexec/podman/
  popd >/dev/null

  mark_step_done "$step"
}

final_info() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run complete. No changes were made."
    return
  fi

  log "Installation complete. Podman version:"
  if command -v podman >/dev/null 2>&1; then
    podman --version || true
    echo
    log "You can test networking with: podman info --debug"
  else
    log "Podman binary not found in PATH; check your install (PREFIX=/usr) and PATH."
  fi
}

#######################################
# Main
#######################################
if [ "$CLEAN_ONLY" -eq 1 ]; then
  cleanup_build_env
  exit 0
fi

install_apt_deps
install_go
build_passt
build_conmon
install_containers_config
install_rust
build_podman
build_netavark
build_aardvark_dns
final_info
final_info

if [ "$CLEAN_AFTER" -eq 1 ]; then
  cleanup_build_env
fi

log "All steps finished."
