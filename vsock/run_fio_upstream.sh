#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIO_DIR="${FIO_DIR:-"$SCRIPT_DIR/fio"}"
FIO_BUILD_SCRIPT="${FIO_BUILD_SCRIPT:-"$FIO_DIR/build_fio.sh"}"

usage() {
  cat <<'EOF'
Usage:
  ./run_fio_upstream.sh [--] [fio-args...]

What this does:
  1) Ensure fio artifacts in vsock/fio:
     - run ./build_fio.sh only if fio binary/lib are missing
     - always run make clean && make SGX=1
  2) For SGX manifest generation, mount current host directory
  3) Resolve fio filename under current host directory ($PWD)
  4) Run upstream gramine-tdx directly

Options:
  -h, --help        Show help

Examples:
  ./run_fio_upstream.sh -- --version
  ./run_fio_upstream.sh -- --name=randrw --filename=fio.dat --size=1G --rw=randrw
EOF
}

log() {
  printf '[fio-upstream] %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

fio_artifacts_present() {
  [[ -x "$FIO_DIR/fio" ]] || return 1
  [[ -d "$FIO_DIR/lib" ]] || return 1
  return 0
}

prepare_fio() {
  local fio_host_dir="$1"

  [[ -d "$FIO_DIR" ]] || die "fio dir not found: $FIO_DIR"
  [[ -x "$FIO_BUILD_SCRIPT" ]] || die "build script not found or not executable: $FIO_BUILD_SCRIPT"

  if ! fio_artifacts_present; then
    log "fio binary/lib missing; running ./build_fio.sh"
    "$FIO_BUILD_SCRIPT"
  fi

  log "refreshing fio SGX artifacts (make clean && make SGX=1, FIO_HOST_DIR=$fio_host_dir)"
  (
    cd "$FIO_DIR"
    make clean
    FIO_HOST_DIR="$fio_host_dir" make SGX=1
  )
}

rewrite_filename_args() {
  local base_dir="$1"
  shift

  local -a rewritten=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --filename=*)
        local raw="${1#--filename=}"
        [[ -n "$raw" ]] || die "--filename requires a non-empty value"
        rewritten+=("--filename=$base_dir/${raw##*/}")
        shift
        ;;
      --filename)
        die "use --filename=<name> (space-separated --filename <name> is not supported)"
        ;;
      *)
        rewritten+=("$1")
        shift
        ;;
    esac
  done

  fio_args=("${rewritten[@]}")
}

fio_host_dir="$(pwd -P)"
fio_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      fio_args=("$@")
      break
      ;;
    *)
      fio_args+=("$1")
      shift
      ;;
  esac
done

rewrite_filename_args "$fio_host_dir" "${fio_args[@]}"

need_cmd make
need_cmd gramine-tdx
need_cmd gramine-manifest
need_cmd gramine-manifest-check
need_cmd gramine-sgx-sign

prepare_fio "$fio_host_dir"

log "running upstream gramine-tdx fio (mounted dir: $fio_host_dir)"
(
  cd "$FIO_DIR"
  gramine-tdx fio "${fio_args[@]}"
)
