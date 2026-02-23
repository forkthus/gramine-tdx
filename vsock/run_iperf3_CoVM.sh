#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-"$SCRIPT_DIR/.vsock_vm_state"}"
ROUTES_JSON="${ROUTES_JSON:-"$SCRIPT_DIR/routes.json"}"
IPERF3_DIR="${IPERF3_DIR:-"$SCRIPT_DIR/iperf3"}"
IPERF3_BUILD_SCRIPT="${IPERF3_BUILD_SCRIPT:-"$IPERF3_DIR/build_iperf3.sh"}"

DEFAULT_HOST_PORT=5201
DEFAULT_VSOCK_PORT=34080
DEFAULT_VM_GATEWAY=10.0.2.2
DEFAULT_TD_HOST=127.0.0.1

usage() {
  cat <<'EOF'
Usage:
  ./run_iperf3_CoVM.sh [options] [--] [iperf3-client-args...]

What this does:
  1) Host: start iperf3 server on --host-port (default: 5201)
  2) Parent VM: start tunnel VSOCK --vsock-port -> TCP --vm-gateway:--host-port
  3) Host: run Gramine-TDX iperf3 client through ./vsock_vm.sh

Options:
  --host-port N     Host iperf3 server port (default: 5201)
  --vsock-port N    Vsock tunnel/client port (default: 34080)
  --vm-gateway IP   Host IP as seen from parent VM (default: 10.0.2.2)
  --td-host IP      iperf3 destination inside TD (default: 127.0.0.1)
  -h, --help        Show help

Examples:
  ./run_iperf3_CoVM.sh
  ./run_iperf3_CoVM.sh --host-port 5202 --vsock-port 34081 -- -P 4 -t 15

Notes:
  - If you override --vsock-port, the port must exist in routes.json.
  - Before running, this script refreshes iperf3 SGX artifacts via: make clean && make SGX=1.
  - ./build_iperf3.sh is invoked only when iperf3 binary/lib artifacts are missing.
  - Wrapper options must come before '--'. Everything after '--' is passed to iperf3.
EOF
}

log() {
  printf '[iperf3-covm] %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

iperf3_artifacts_present() {
  [[ -x "$IPERF3_DIR/iperf3" ]] || return 1
  [[ -d "$IPERF3_DIR/lib" ]] || return 1
  [[ -n "$(ls -A "$IPERF3_DIR/lib" 2>/dev/null)" ]] || return 1
  return 0
}

prepare_iperf3() {
  [[ -d "$IPERF3_DIR" ]] || die "iperf3 dir not found: $IPERF3_DIR"

  if ! iperf3_artifacts_present; then
    [[ -x "$IPERF3_BUILD_SCRIPT" ]] || die "build script not found or not executable: $IPERF3_BUILD_SCRIPT"
    log "iperf3 binary/lib missing; running ./build_iperf3.sh"
    (
      cd "$IPERF3_DIR"
      "$IPERF3_BUILD_SCRIPT"
    )
  fi

  log "refreshing iperf3 SGX artifacts (make clean && make SGX=1)"
  (
    cd "$IPERF3_DIR"
    make clean
    make SGX=1
  )
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

route_port_exists() {
  python3 - "$ROUTES_JSON" "$1" <<'PY'
import json
import sys

cfg_path = sys.argv[1]
port = str(int(sys.argv[2]))
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
sys.exit(0 if port in cfg else 1)
PY
}

host_port="$DEFAULT_HOST_PORT"
vsock_port="$DEFAULT_VSOCK_PORT"
vm_gateway="$DEFAULT_VM_GATEWAY"
td_host="$DEFAULT_TD_HOST"
client_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-port)
      [[ $# -ge 2 ]] || die "--host-port requires a value"
      host_port="$2"
      shift 2
      ;;
    --vsock-port)
      [[ $# -ge 2 ]] || die "--vsock-port requires a value"
      vsock_port="$2"
      shift 2
      ;;
    --vm-gateway)
      [[ $# -ge 2 ]] || die "--vm-gateway requires a value"
      vm_gateway="$2"
      shift 2
      ;;
    --td-host)
      [[ $# -ge 2 ]] || die "--td-host requires a value"
      td_host="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      client_args=("$@")
      break
      ;;
    *)
      client_args+=("$1")
      shift
      ;;
  esac
done

is_valid_port "$host_port" || die "invalid host port: $host_port"
is_valid_port "$vsock_port" || die "invalid vsock port: $vsock_port"
[[ -f "$ROUTES_JSON" ]] || die "routes config not found: $ROUTES_JSON"

need_cmd iperf3
need_cmd python3
need_cmd make
need_cmd gramine-manifest
need_cmd gramine-manifest-check
need_cmd gramine-sgx-sign
[[ -x "$SCRIPT_DIR/vsock_vm.sh" ]] || die "vsock_vm.sh not found or not executable: $SCRIPT_DIR/vsock_vm.sh"

if ! route_port_exists "$vsock_port"; then
  die "routes.json does not contain vsock listen port $vsock_port (file: $ROUTES_JSON)"
fi

prepare_iperf3

mkdir -p "$STATE_DIR"
IPERF_LOG="$STATE_DIR/iperf3-server.port${host_port}.log"

iperf_pid=""
cleanup() {
  set +e
  if [[ -n "${iperf_pid:-}" ]] && kill -0 "$iperf_pid" >/dev/null 2>&1; then
    kill -TERM "$iperf_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

log "starting host iperf3 server on tcp :$host_port (log: $IPERF_LOG)"
: >"$IPERF_LOG"
iperf3 -s -p "$host_port" -1 >"$IPERF_LOG" 2>&1 &
iperf_pid="$!"

sleep 0.1
if ! kill -0 "$iperf_pid" >/dev/null 2>&1; then
  tail -n 50 "$IPERF_LOG" >&2 || true
  die "iperf3 server failed to start (tcp :$host_port)"
fi

log "running Gramine-TDX iperf3 client via vsock_vm.sh"
log "path: TD $td_host:$vsock_port -> host $vm_gateway:$host_port (through parent VM tunnel)"

ENABLE_HTTPS_PING=0 \
ENABLE_HTTP_TUNNEL=1 \
HTTP_TUNNEL_VSOCK_PORT="$vsock_port" \
HTTP_TUNNEL_TARGET_HOST="$vm_gateway" \
HTTP_TUNNEL_TARGET_PORT="$host_port" \
  "$SCRIPT_DIR/vsock_vm.sh" run iperf3 -c "$td_host" -p "$vsock_port" "${client_args[@]}"
