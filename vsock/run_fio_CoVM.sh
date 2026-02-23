#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIO_DIR="${FIO_DIR:-"$SCRIPT_DIR/fio"}"
FIO_BUILD_SCRIPT="${FIO_BUILD_SCRIPT:-"$FIO_DIR/build_fio.sh"}"
FIO_TDX_HOST_DIR="/home/ubuntu/fio-data"

usage() {
  cat <<'EOF'
Usage:
  ./run_fio_CoVM.sh [--] [fio-args...]

What this does:
  1) Ensure fio artifacts in vsock/fio:
     - run ./build_fio.sh only if fio binary/lib are missing
     - always run make clean && make SGX=1 (with FIO_HOST_DIR=/home/ubuntu/fio-data)
  2) Resolve fio filename under /home/ubuntu/fio-data
  3) Run Gramine-TDX fio via ./vsock_vm.sh

Options:
  -h, --help   Show help

Examples:
  ./run_fio_CoVM.sh -- --version
  ./run_fio_CoVM.sh -- --name=seqread --filename=test.dat --size=128M --rw=read
EOF
}

log() {
  printf '[fio-covm] %s\n' "$*" >&2
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
  [[ -d "$FIO_DIR" ]] || die "fio dir not found: $FIO_DIR"
  [[ -x "$FIO_BUILD_SCRIPT" ]] || die "build script not found or not executable: $FIO_BUILD_SCRIPT"

  if ! fio_artifacts_present; then
    log "fio binary/lib missing; running ./build_fio.sh"
    "$FIO_BUILD_SCRIPT"
  fi

  log "refreshing fio SGX artifacts (make clean && make SGX=1)"
  (
    cd "$FIO_DIR"
    make clean
    FIO_HOST_DIR="$FIO_TDX_HOST_DIR" make SGX=1
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

rewrite_filename_args "$FIO_TDX_HOST_DIR" "${fio_args[@]}"

need_cmd make
need_cmd gramine-manifest
need_cmd gramine-manifest-check
need_cmd gramine-sgx-sign
[[ -x "$SCRIPT_DIR/vsock_vm.sh" ]] || die "vsock_vm.sh not found or not executable: $SCRIPT_DIR/vsock_vm.sh"

prepare_fio

log "running Gramine-TDX fio via vsock_vm.sh"
"$SCRIPT_DIR/vsock_vm.sh" run fio "${fio_args[@]}"
