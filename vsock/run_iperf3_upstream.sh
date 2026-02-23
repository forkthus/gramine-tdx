#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-"$SCRIPT_DIR/.vsock_vm_state"}"

IPERF3_DIR="${IPERF3_DIR:-"$SCRIPT_DIR/iperf3"}"
IPERF3_BUILD_SCRIPT="${IPERF3_BUILD_SCRIPT:-"$IPERF3_DIR/build_iperf3.sh"}"

DEFAULT_HOST_PORT=5201
DEFAULT_VSOCK_PORT=5201
DEFAULT_TD_HOST=127.0.0.1

usage() {
  cat <<'EOF'
Usage:
  ./run_iperf3_upstream.sh [options] [--] [iperf3-client-args...]

What this does:
  1) Host: start iperf3 server on --host-port (default: 5201)
  2) Host: start socat bridge VSOCK --vsock-port -> TCP 127.0.0.1:--host-port
  3) Ensure iperf3 artifacts:
     - run ./build_iperf3.sh only if binary/lib are missing
     - always run make clean && make SGX=1
  4) Host: run upstream gramine-tdx directly

Options:
  --host-port N     Host iperf3 server port (default: 5201)
  --vsock-port N    Vsock bridge/client port (default: 5201)
  --port N          Alias for setting both --host-port and --vsock-port
  --td-host IP      iperf3 destination inside TD (default: 127.0.0.1)
  -h, --help        Show help

Environment overrides:
  IPERF3_DIR               (default: ./iperf3)
  IPERF3_BUILD_SCRIPT      (default: IPERF3_DIR/build_iperf3.sh)
EOF
}

log() {
  printf '[iperf3-upstream] %s\n' "$*" >&2
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
    "$IPERF3_BUILD_SCRIPT"
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

host_port="$DEFAULT_HOST_PORT"
vsock_port="$DEFAULT_VSOCK_PORT"
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
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      host_port="$2"
      vsock_port="$2"
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

need_cmd iperf3
need_cmd socat
need_cmd ss
need_cmd make
need_cmd gramine-tdx
need_cmd gramine-manifest
need_cmd gramine-manifest-check
need_cmd gramine-sgx-sign

prepare_iperf3

mkdir -p "$STATE_DIR"
IPERF_LOG="$STATE_DIR/iperf3-upstream-server.port${host_port}.log"
SOCAT_LOG="$STATE_DIR/iperf3-upstream-socat.port${vsock_port}.log"

iperf_pid=""
socat_pid=""
cleanup() {
  set +e
  if [[ -n "${socat_pid:-}" ]] && kill -0 "$socat_pid" >/dev/null 2>&1; then
    pkill -TERM -P "$socat_pid" >/dev/null 2>&1 || true
    kill -TERM "$socat_pid" >/dev/null 2>&1 || true
  fi
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

log "starting host socat bridge vsock :$vsock_port -> tcp 127.0.0.1:$host_port (log: $SOCAT_LOG)"
: >"$SOCAT_LOG"
socat -d -d "VSOCK-LISTEN:${vsock_port},fork,reuseaddr" "TCP:127.0.0.1:${host_port}" >"$SOCAT_LOG" 2>&1 &
socat_pid="$!"

for _ in $(seq 1 50); do
  if ss -H -l --vsock "sport = :$vsock_port" 2>/dev/null | grep -q LISTEN; then
    break
  fi
  sleep 0.1
done
if ! ss -H -l --vsock "sport = :$vsock_port" 2>/dev/null | grep -q LISTEN; then
  tail -n 80 "$SOCAT_LOG" >&2 || true
  die "socat bridge did not start listening on vsock :$vsock_port"
fi

log "running upstream gramine-tdx directly: iperf3 -c $td_host -p $vsock_port ${client_args[*]:-}"
(
  cd "$IPERF3_DIR"
  gramine-tdx iperf3 -c "$td_host" -p "$vsock_port" "${client_args[@]}"
)
