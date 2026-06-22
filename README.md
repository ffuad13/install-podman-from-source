# Podman From Source Installer

This repository provides a Bash script to build and install a recent Podman release from source on Ubuntu 22.04 or 24.04, along with its networking stack (netavark + aardvark-dns) and supporting tools.

The script is designed for repeatable server setups where you want a newer Podman than the Ubuntu archive provides, but still want a lean runtime environment afterward.

## Features

- Builds Podman from source on Ubuntu 22.04 or 24.04 with configurable version (default: `v5.8.3`).
- Builds and installs:
  - `conmon` (container monitor)
  - `passt` / `pasta` (for user-mode networking)
  - `netavark` (container network stack)
  - `aardvark-dns` (DNS server for container A/AAAA records)
- Step-level caching with `.state` files so reruns resume from the last successful step instead of starting over.
- `--dry-run` mode to preview all actions without making changes.
- Optional cleanup of build-time dependencies, toolchains, and workspace after a successful build.
- Flags to keep Go and/or Rust toolchains if you also use them for development on the host.
- Interactive or fully non-interactive modes for CI and automation.

## Requirements

- Ubuntu 22.04 (Jammy) or 24.04 (Noble) host.
- `sudo` access for installing packages and placing binaries under `/usr` and `/usr/local/libexec/podman`.
- Network access to fetch sources from GitHub and install toolchains.

## Script overview

The main script (for example `install-podman-from-source.sh`) performs these steps:

1. Verifies the OS is Ubuntu 22.04 or 24.04.
2. Installs build dependencies via `apt-get` (compiler, headers, dev libraries, etc.).
3. Installs Go (configurable version) using a helper installer script.
4. Clones and builds:
   - `passt`
   - `conmon`
   - `podman` at the requested tag
   - `netavark`
   - `aardvark-dns`
5. Installs Podman under `/usr`, and networking helpers under `/usr/local/libexec/podman`.
6. Installs `/etc/containers/registries.conf` and `/etc/containers/policy.json`.
7. Installs the Rust toolchain via `rustup` and sets `stable` as the default toolchain (for `netavark` and `aardvark-dns` builds).
8. Optionally cleans up build deps, toolchains, and the workspace.

Each major step writes a `.done` marker under `${WORKDIR}/.state` only on success, so rerunning the script will skip completed steps unless you explicitly disable caching.

## Installation

```bash
curl -fsSL https://bit.ly/podman-install | bash
```

Or clone this repository and make the script executable:

```bash
git clone https://github.com/your-user/your-repo.git
cd your-repo
chmod +x ./install-podman-from-source.sh
```

## Usage

### Basic install

Run interactively:

```bash
./install-podman-from-source.sh
```

The script will show a plan and ask for confirmation before proceeding.

Run non-interactively:

```bash
./install-podman-from-source.sh -y
```

### Dry run

Preview everything without making changes:

```bash
./install-podman-from-source.sh --dry-run
```

### Override versions and workspace

```bash
PODMAN_VERSION=v5.9.0 \
GO_VERSION=1.22.4 \
WORKDIR="$HOME/src/podman-src" \
  ./install-podman-from-source.sh -y
```

### Cleanup options

You can use the built-in cleanup logic to remove build-time dependencies, toolchains, and the working directory once Podman is installed.

- Run a full build and then clean up:

```bash
./install-podman-from-source.sh -y --cleanup-after
```

- Only run cleanup (no build steps):

```bash
./install-podman-from-source.sh --cleanup-only
```

#### Keeping Go or Rust

By default, cleanup will remove:

- Build-time `apt` packages.
- Go toolchain and caches (`/usr/local/go`, `~/.go`, `$GOPATH`).
- Rust toolchain and caches (`~/.rustup`, `~/.cargo`).
- Go / Rust environment entries in `~/.bashrc` and `~/.zshrc`:
  - `export GOROOT=/home/ubuntu/.go`
  - `export PATH=$GOROOT/bin:$PATH`
  - `export GOPATH=/home/ubuntu/go`
  - `export PATH=$GOPATH/bin:$PATH`
  - `. "$HOME/.cargo/env"`

Use these flags to keep one or both toolchains and their shell configuration:

- Keep Go only:

```bash
./install-podman-from-source.sh --cleanup-only --keep-go
```

- Keep Rust only:

```bash
./install-podman-from-source.sh --cleanup-only --keep-rust
```

- Keep both Go and Rust:

```bash
./install-podman-from-source.sh --cleanup-only --keep-go --keep-rust
```

### Caching and rebuilds

- To resume after a failed step, just rerun:

```bash
./install-podman-from-source.sh -y
```

- To force all steps to re-run but reuse cloned repos:

```bash
./install-podman-from-source.sh -y --no-cache
```

- To completely reset the workspace before running:

```bash
./install-podman-from-source.sh -y --clean-workdir
```

## Script options summary

Run `./install-podman-from-source.sh --help` to see the latest usage, but the key options are:

- `--dry-run, -n`  
  Print what would be done, but do not execute.

- `--yes, -y`  
  Non-interactive; assume "yes" to prompts.

- `--podman-version=VAL`  
  Podman git tag to build (default: `v5.8.3`).

- `--go-version=VAL`  
  Go version for the helper installer (default: `1.26.4`).

- `--no-cache, --force`  
  Ignore cached step state and re-run all steps.

- `--clean-workdir`  
  Remove the entire `WORKDIR` before running.

- `--cleanup-after`  
  Run cleanup of build deps/toolchains after a successful build.

- `--cleanup-only`  
  Only run cleanup (no build or install steps).

- `--keep-go`  
  Keep Go toolchain and Go env config during cleanup.

- `--keep-rust`  
  Keep Rust toolchain and Rust env config during cleanup.

## Caveats

- This script specifically targets Ubuntu 22.04 or 24.04; use on other distributions or releases is not supported.
- It makes system-wide changes (`apt-get`, `/usr`, `/usr/local/libexec`, `/etc/containers`), so you should review it before running in production.
- Podman, netavark, and aardvark-dns are actively developed; you may need to adjust default versions or build flags over time.

## License

This project is licensed under the MIT License. See the [`LICENSE`](LICENSE) file for details.
