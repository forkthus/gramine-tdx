#!/usr/bin/env bash
set -euo pipefail

# Script lives in <repo>/gramine-tdx/vsock.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAMINE_TDX_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd -- "$GRAMINE_TDX_DIR/.." && pwd)"
STATE_DIR="${STATE_DIR:-"$SCRIPT_DIR/.vsock_vm_state"}"

SSH_USER="${SSH_USER:-ubuntu}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"

VM_CID="${VM_CID:-5}"
VM_MEM_MB="${VM_MEM_MB:-2048}"
VM_SMP="${VM_SMP:-2}"

VM_SEED_ISO="${VM_SEED_ISO:-"$WORKSPACE_DIR/seed.iso"}"
VM_IMAGE="${VM_IMAGE:-"$WORKSPACE_DIR/vm.qcow2"}"

REMOTE_ROOT="${REMOTE_ROOT:-"$WORKSPACE_DIR"}"
REMOTE_RUN_DIR="${REMOTE_RUN_DIR:-"$REMOTE_ROOT/run"}"
REMOTE_BIN_DIR="${REMOTE_BIN_DIR:-"$REMOTE_ROOT/bin"}"
REMOTE_VSOCK_DIR="${REMOTE_VSOCK_DIR:-"$REMOTE_ROOT/gramine-tdx/vsock"}"

FORWARDER_PY="${FORWARDER_PY:-"$SCRIPT_DIR/vsock_forwarder.py"}"
ROUTES_JSON="${ROUTES_JSON:-"$SCRIPT_DIR/routes.json"}"

GRAMINE_TDX_BIN="${GRAMINE_TDX_BIN:-"$GRAMINE_TDX_DIR/built-debug/bin/gramine-tdx"}"

# Path to the already-built virtiofsd binary inside the parent VM.
VIRTIOFSD_VM_BIN="${VIRTIOFSD_VM_BIN:-/home/ubuntu/virtiofsd/target/release/virtiofsd}"
VIRTIOFSD_VSOCK_PORT="${VIRTIOFSD_VSOCK_PORT:-31337}"
VCONSOLE_BASE_PORT="${VCONSOLE_BASE_PORT:-33222}"

# HTTPS ping helper (TD -> host forwarder -> parent VM).
HTTPS_PING_VSOCK_PORT="${HTTPS_PING_VSOCK_PORT:-34443}"
ENABLE_HTTPS_PING="${ENABLE_HTTPS_PING:-0}"
HTTPS_PING_VM_SCRIPT="${HTTPS_PING_VM_SCRIPT:-"$SCRIPT_DIR/vsock_https_ping_vm.py"}"

# HTTP tunnel helper (TD -> host forwarder -> parent VM socat -> remote HTTP).
HTTP_TUNNEL_VSOCK_PORT="${HTTP_TUNNEL_VSOCK_PORT:-34080}"
ENABLE_HTTP_TUNNEL="${ENABLE_HTTP_TUNNEL:-1}"
HTTP_TUNNEL_TARGET_HOST="${HTTP_TUNNEL_TARGET_HOST:-www.google.com}"
HTTP_TUNNEL_TARGET_PORT="${HTTP_TUNNEL_TARGET_PORT:-80}"

# Whether to stream the guest console output (from the parent VM vconsole) into this terminal.
STREAM_CONSOLE="${STREAM_CONSOLE:-1}"

# Whether to stop services after the Gramine program exits.
AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-1}"

QEMU_PIDFILE="$STATE_DIR/parent_vm.pid"
QEMU_SERIAL_LOG="$STATE_DIR/parent_vm.serial.log"

FWD_PIDFILE="$STATE_DIR/forwarder.pid"
FWD_LOG="$STATE_DIR/forwarder.log"

usage() {
  cat <<'EOF'
Usage:
  ./vsock_vm.sh run <program_name|program_path> [program args...]
  ./vsock_vm.sh console

Notes:
  - `run` starts the parent VM (if needed), scp-copies required artifacts into the VM,
    starts virtiofsd/vconsole/forwarder, then runs Gramine-TDX.
  - Programs are assumed to be laid out as:
      <repo>/gramine-tdx/vsock/<program_name>/<program_name>
    Alternatively, you can pass a path to the program binary, e.g.:
      gramine-tdx/vsock/vsock_readme_menu/vsock_readme_menu
  - The script always copies:
      <repo>/gramine-tdx/built-debug
      <repo>/gramine-tdx/vsock/vsock_vm_console.py
      <repo>/gramine-tdx/vsock/<program_name>
  - The parent VM ssh is assumed to be on 127.0.0.1:2222 as user ubuntu (override via SSH_PORT/SSH_USER).
  - By default, `run` also streams the Gramine guest stdout/stderr into this terminal.
    Disable with: STREAM_CONSOLE=0
  - By default, `run` shuts down the parent VM and host services it started when the program exits.
    Disable with: AUTO_SHUTDOWN=0

Environment overrides (common):
  SSH_PORT, SSH_USER, VM_CID, VM_MEM_MB, VM_SMP
  REMOTE_ROOT (must match this repo's absolute path in the VM)
  STATE_DIR (pidfiles/logs for qemu/forwarder on the host)
  ENABLE_HTTPS_PING=1 (start https ping helper in parent VM)
  HTTPS_PING_VSOCK_PORT (vsock port used for the helper)
  ENABLE_HTTP_TUNNEL=1 (start http tunnel in parent VM)
  HTTP_TUNNEL_VSOCK_PORT (vsock port used for the tunnel)
  HTTP_TUNNEL_TARGET_HOST (default: www.google.com)
  HTTP_TUNNEL_TARGET_PORT (default: 80)
EOF
}

log() {
  printf '[vsock-vm] %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

mkdir_state_dir() {
  mkdir -p "$STATE_DIR"
}

ssh_base_opts=(
  -p "$SSH_PORT"
  -o BatchMode=yes
  -o LogLevel=QUIET
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=2
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

ssh_cmd() {
  ssh "${ssh_base_opts[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
}

ssh_cmd_tty() {
  ssh -tt "${ssh_base_opts[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
}

vm_ssh_ready() {
  ssh_cmd true >/dev/null 2>&1
}

wait_for_vm_ssh() {
  local timeout_s="${1:-120}"
  local deadline
  deadline="$((SECONDS + timeout_s))"
  while (( SECONDS < deadline )); do
    if vm_ssh_ready; then
      return 0
    fi
    sleep 1
  done
  return 1
}

qemu_pid_running() {
  [[ -f "$QEMU_PIDFILE" ]] || return 1
  local pid
  pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

STARTED_PARENT_VM=0
STARTED_FORWARDER=0
STARTED_VIRTIOFSD=0
STARTED_VCONSOLE=0

ensure_parent_vm_running() {
  mkdir_state_dir

  if vm_ssh_ready; then
    log "parent VM already reachable via ssh (port ${SSH_PORT})."
    return 0
  fi

  if qemu_pid_running; then
    log "qemu pidfile exists but ssh not ready yet; waiting for ssh..."
    if wait_for_vm_ssh 120; then
      return 0
    fi
    die "ssh never became ready; check ${QEMU_SERIAL_LOG}"
  fi

  log "starting parent VM (cid=${VM_CID}, ssh port=${SSH_PORT})..."
  STARTED_PARENT_VM=1
  rm -f "$QEMU_PIDFILE"
  qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host -smp "$VM_SMP" -m "$VM_MEM_MB" \
    -drive file="$VM_IMAGE",if=virtio,format=qcow2 \
    -drive file="$VM_SEED_ISO",media=cdrom,readonly=on \
    -netdev user,id=n1,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
    -device virtio-net-pci,netdev=n1 \
    -device vhost-vsock-pci,guest-cid="$VM_CID" \
    -display none \
    -serial "file:${QEMU_SERIAL_LOG}" \
    -daemonize -pidfile "$QEMU_PIDFILE"

  if ! wait_for_vm_ssh 120; then
    die "parent VM did not come up (ssh timeout); check ${QEMU_SERIAL_LOG}"
  fi
  log "parent VM is up."
}

ensure_vm_layout() {
  log "ensuring ${REMOTE_ROOT} exists in the parent VM..."
  ssh_cmd "sudo install -d -o '$SSH_USER' -g '$SSH_USER' '$REMOTE_ROOT' '$REMOTE_RUN_DIR' '$REMOTE_BIN_DIR' '$(dirname "$REMOTE_VSOCK_DIR")' '$REMOTE_VSOCK_DIR'"
}

vm_vsock_listening() {
  local port="$1"
  ssh_cmd "ss -H -l --vsock \"sport = :$port\" 2>/dev/null | grep -q LISTEN" >/dev/null 2>&1
}

vm_tmux_has_session() {
  local name="$1"
  ssh_cmd "tmux has-session -t '$name' 2>/dev/null" >/dev/null 2>&1
}

scp_path() {
  local src_path="$1"
  [[ "$src_path" = /* ]] || die "copy paths must be absolute: $src_path"
  [[ -e "$src_path" ]] || die "path not found: $src_path"

  local dst_parent
  dst_parent="$(dirname "$src_path")"

  ssh_cmd "mkdir -p '$dst_parent'"

  local pretty="$src_path"
  if [[ "$src_path" == "$WORKSPACE_DIR/"* ]]; then
    pretty="${src_path#"$WORKSPACE_DIR"/}"
  fi

  if [[ -d "$src_path" ]]; then
    log "copying to VM: $pretty/"
    scp -q -r -P "$SSH_PORT" \
      -o BatchMode=yes -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$src_path" "${SSH_USER}@${SSH_HOST}:$dst_parent/"
  else
    log "copying to VM: $pretty"
    scp -q -P "$SSH_PORT" \
      -o BatchMode=yes -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$src_path" "${SSH_USER}@${SSH_HOST}:$dst_parent/"
  fi
}

scp_program_dir() {
  local src_path="$1"
  [[ "$src_path" = /* ]] || die "copy paths must be absolute: $src_path"
  [[ -d "$src_path" ]] || die "program dir not found: $src_path"

  local dst_parent dir_name pretty
  dst_parent="$(dirname "$src_path")"
  dir_name="$(basename "$src_path")"

  ssh_cmd "mkdir -p '$dst_parent'"
  ssh_cmd "if [[ -d '$src_path' ]]; then sudo chown -R '$SSH_USER':'$SSH_USER' '$src_path' >/dev/null 2>&1 || true; fi"

  pretty="$src_path"
  if [[ "$src_path" == "$WORKSPACE_DIR/"* ]]; then
    pretty="${src_path#"$WORKSPACE_DIR"/}"
  fi

  log "copying to VM: $pretty/ (excluding vcs metadata and *-src trees)"
  tar -C "$dst_parent" --exclude-vcs --exclude='*-src' -cf - "$dir_name" \
    | ssh "${ssh_base_opts[@]}" "${SSH_USER}@${SSH_HOST}" "tar -xf - -C '$dst_parent'"
}

ensure_vm_virtiofsd_bin() {
  if ssh_cmd "test -x '$VIRTIOFSD_VM_BIN'" >/dev/null 2>&1; then
    return 0
  fi

  die "virtiofsd not found or not executable in VM at '$VIRTIOFSD_VM_BIN' (set VIRTIOFSD_VM_BIN)"
}

start_vm_virtiofsd() {
  ensure_vm_virtiofsd_bin

  local log_path="${REMOTE_RUN_DIR}/virtiofsd-vsock.log"
  local pid_path="${REMOTE_RUN_DIR}/virtiofsd-vsock.pid"

  log "starting virtiofsd in parent VM (port ${VIRTIOFSD_VSOCK_PORT})..."
  ssh_cmd "set -euo pipefail
    if ss -H -l --vsock \"sport = :${VIRTIOFSD_VSOCK_PORT}\" 2>/dev/null | grep -q LISTEN; then
      pid=\"\$(ss -H -l --vsock -p \"sport = :${VIRTIOFSD_VSOCK_PORT}\" 2>/dev/null | sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)\"
      if [[ -n \"\$pid\" ]]; then
        echo \"\$pid\" >'${pid_path}'
        echo \"[vm] virtiofsd already listening (pid \$pid)\" >&2
      else
        rm -f '${pid_path}' 2>/dev/null || true
        echo '[vm] virtiofsd already listening' >&2
      fi
      exit 0
    fi
    nohup '${VIRTIOFSD_VM_BIN}' --shared-dir / --sandbox none --no-announce-submounts --log-level debug --vsock '${VIRTIOFSD_VSOCK_PORT}' >'${log_path}' 2>&1 &
    echo \$! >'${pid_path}'
    disown || true
    for _ in \$(seq 1 50); do
      if ss -H -l --vsock \"sport = :${VIRTIOFSD_VSOCK_PORT}\" 2>/dev/null | grep -q LISTEN; then
        exit 0
      fi
      sleep 0.1
    done
    echo '[vm] virtiofsd did not start listening in time' >&2
    tail -n 50 '${log_path}' >&2 || true
    exit 1
  "
}

start_vm_vconsole_tmux() {
  local log_path="${REMOTE_RUN_DIR}/vconsole.log"
  log "starting vconsole in a tmux session in parent VM (base port ${VCONSOLE_BASE_PORT})..."
  ssh_cmd "set -euo pipefail
    : > '$log_path'
    if ! command -v tmux >/dev/null 2>&1; then
      echo '[vm] tmux not installed; install it (recommended): sudo apt-get update && sudo apt-get install -y tmux' >&2
      exit 0
    fi
    if tmux has-session -t gramine-vconsole 2>/dev/null; then
      echo '[vm] tmux session gramine-vconsole already running' >&2
    else
      cd '$REMOTE_VSOCK_DIR'
      tmux new-session -d -s gramine-vconsole \"PYTHONUNBUFFERED=1 python3 vsock_vm_console.py --base-port '${VCONSOLE_BASE_PORT}'\"
    fi
    # Reset any previous pipe and then start piping into the log.
    tmux pipe-pane -t gramine-vconsole:0.0 >/dev/null 2>&1 || true
    tmux pipe-pane -t gramine-vconsole:0.0 \"cat >> '$log_path'\"
  "
}

vsock_port_listening() {
  local port="$1"
  ss -H -l --vsock "sport = :$port" 2>/dev/null | grep -q "LISTEN"
}

listen_pids_for_vsock_port() {
  local port="$1"
  ss -H -l --vsock -p "sport = :$port" 2>/dev/null \
    | sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' \
    | sort -u
}

routes_listen_ports() {
  [[ -f "$ROUTES_JSON" ]] || die "routes config not found: $ROUTES_JSON"
  python3 - "$ROUTES_JSON" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)
for k in cfg.keys():
    print(int(k))
PY
}

start_host_forwarder() {
  mkdir_state_dir

  local ports=()
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    ports+=("$port")
  done < <(routes_listen_ports)

  local pidfile_pid=""
  if [[ -f "$FWD_PIDFILE" ]]; then
    pidfile_pid="$(cat "$FWD_PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pidfile_pid" ]] && ! kill -0 "$pidfile_pid" >/dev/null 2>&1; then
      pidfile_pid=""
      rm -f "$FWD_PIDFILE" 2>/dev/null || true
    fi
  fi

  local seen_pids=()
  local any_listening=0
  local any_missing=0
  for port in "${ports[@]}"; do
    if ! vsock_port_listening "$port"; then
      any_missing=1
      continue
    fi
    any_listening=1
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      seen_pids+=("$pid")
    done < <(listen_pids_for_vsock_port "$port")
  done
  if [[ "$any_listening" == "1" ]]; then
    local skip_reuse=0
    if [[ "${#seen_pids[@]}" -eq 0 ]]; then
      # Fallback: if `ss -p` cannot retrieve process info (e.g., restricted /proc),
      # reuse/restart the forwarder based on our pidfile.
      if [[ -n "$pidfile_pid" ]]; then
        local cmdline=""
        cmdline="$(ps -p "$pidfile_pid" -o args= 2>/dev/null || true)"
        if [[ "$cmdline" == *"vsock_forwarder.py"* ]]; then
          if [[ "$any_missing" == "0" ]]; then
            log "host forwarder already running (pid $pidfile_pid; inferred from pidfile)."
            echo "$pidfile_pid" >"$FWD_PIDFILE"
            return 0
          fi

          log "host forwarder seems running but missing some ports; restarting (pid $pidfile_pid; inferred from pidfile)."
          kill -TERM "$pidfile_pid" >/dev/null 2>&1 || true
          for _ in $(seq 1 20); do
            if ! kill -0 "$pidfile_pid" >/dev/null 2>&1; then
              break
            fi
            sleep 0.1
          done
          kill -KILL "$pidfile_pid" >/dev/null 2>&1 || true
          rm -f "$FWD_PIDFILE" 2>/dev/null || true
          pidfile_pid=""
          skip_reuse=1
        fi
      fi

      if [[ "$skip_reuse" == "0" ]]; then
        die "vsock ports are already listening but process info is unavailable; cannot reuse."
      fi
    fi
    if [[ "$skip_reuse" == "0" ]]; then
      local unique_pids
      unique_pids="$(printf '%s\n' "${seen_pids[@]}" | sort -u)"
      local pid_count
      pid_count="$(printf '%s\n' "$unique_pids" | wc -l | tr -d ' ')"
      if [[ "$pid_count" != "1" ]]; then
        die "vsock ports are already in use by multiple processes; cannot start forwarder."
      fi
      local pid
      pid="$(printf '%s\n' "$unique_pids" | head -n 1)"
      local cmdline
      cmdline="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$cmdline" != *"vsock_forwarder.py"* ]]; then
        die "vsock ports are already listening (pid $pid: $cmdline); cannot start forwarder."
      fi
      if [[ "$any_missing" == "0" ]]; then
        log "host forwarder already running (pid $pid)."
        echo "$pid" >"$FWD_PIDFILE"
        return 0
      fi

      log "host forwarder already running but missing some ports; restarting (pid $pid)."
      kill -TERM "$pid" >/dev/null 2>&1 || true
      for _ in $(seq 1 20); do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
          break
        fi
        sleep 0.1
      done
      kill -KILL "$pid" >/dev/null 2>&1 || true
      rm -f "$FWD_PIDFILE" 2>/dev/null || true
    fi
  elif [[ -n "$pidfile_pid" ]]; then
    local cmdline=""
    cmdline="$(ps -p "$pidfile_pid" -o args= 2>/dev/null || true)"
    if [[ "$cmdline" == *"vsock_forwarder.py"* ]]; then
      log "stale host forwarder pidfile found; restarting (pid $pidfile_pid)."
      kill -TERM "$pidfile_pid" >/dev/null 2>&1 || true
      for _ in $(seq 1 20); do
        if ! kill -0 "$pidfile_pid" >/dev/null 2>&1; then
          break
        fi
        sleep 0.1
      done
      kill -KILL "$pidfile_pid" >/dev/null 2>&1 || true
      rm -f "$FWD_PIDFILE" 2>/dev/null || true
    fi
  fi

  [[ -f "$FORWARDER_PY" ]] || die "forwarder not found: $FORWARDER_PY"
  [[ -f "$ROUTES_JSON" ]] || die "routes config not found: $ROUTES_JSON"

  log "starting host forwarder: $FORWARDER_PY $ROUTES_JSON"
  STARTED_FORWARDER=1
  rm -f "$FWD_PIDFILE"
  nohup python3 "$FORWARDER_PY" "$ROUTES_JSON" >"$FWD_LOG" 2>&1 &
  echo $! >"$FWD_PIDFILE"
}

start_vm_https_ping_helper() {
  local port="$HTTPS_PING_VSOCK_PORT"

  local log_path="${REMOTE_RUN_DIR}/https-ping.log"
  local pid_path="${REMOTE_RUN_DIR}/https-ping.pid"

  log "starting https ping helper in parent VM (vsock :${port})..."
  ssh_cmd "set -euo pipefail
    if ss -H -l --vsock \"sport = :${port}\" 2>/dev/null | grep -q LISTEN; then
      pid=\"\$(ss -H -l --vsock -p \"sport = :${port}\" 2>/dev/null | sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)\"
      if [[ -n \"\$pid\" ]]; then
        echo \"\$pid\" >'${pid_path}'
        echo \"[vm] https ping helper already listening (pid \$pid)\" >&2
      else
        rm -f '${pid_path}' 2>/dev/null || true
        echo '[vm] https ping helper already listening' >&2
      fi
      exit 0
    fi

    if ! command -v socat >/dev/null 2>&1; then
      echo '[vm] socat not installed; install it: sudo apt-get update && sudo apt-get install -y socat' >&2
      exit 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo '[vm] python3 not installed' >&2
      exit 0
    fi

    nohup socat -d -d \"VSOCK-LISTEN:${port},fork,reuseaddr\" \"EXEC:'python3 -u ${REMOTE_VSOCK_DIR}/vsock_https_ping_vm.py',stderr\" >'${log_path}' 2>&1 &
    echo \$! >'${pid_path}'
    disown || true

    for _ in \$(seq 1 50); do
      if ss -H -l --vsock \"sport = :${port}\" 2>/dev/null | grep -q LISTEN; then
        exit 0
      fi
      sleep 0.1
    done
    echo '[vm] https ping helper did not start listening in time' >&2
    tail -n 50 '${log_path}' >&2 || true
    exit 1
  "
}

start_vm_http_tunnel() {
  local port="$HTTP_TUNNEL_VSOCK_PORT"
  local dst_host="$HTTP_TUNNEL_TARGET_HOST"
  local dst_port="$HTTP_TUNNEL_TARGET_PORT"

  local log_path="${REMOTE_RUN_DIR}/http-tunnel.log"
  local pid_path="${REMOTE_RUN_DIR}/http-tunnel.pid"

  log "starting http tunnel in parent VM (vsock :${port} -> tcp ${dst_host}:${dst_port})..."
  ssh_cmd "set -euo pipefail
    if ss -H -l --vsock \"sport = :${port}\" 2>/dev/null | grep -q LISTEN; then
      pid=\"\$(ss -H -l --vsock -p \"sport = :${port}\" 2>/dev/null | sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)\"
      if [[ -n \"\$pid\" ]]; then
        echo \"\$pid\" >'${pid_path}'
        echo \"[vm] http tunnel already listening (pid \$pid)\" >&2
      else
        rm -f '${pid_path}' 2>/dev/null || true
        echo '[vm] http tunnel already listening' >&2
      fi
      exit 0
    fi

    if ! command -v socat >/dev/null 2>&1; then
      echo '[vm] socat not installed; install it: sudo apt-get update && sudo apt-get install -y socat' >&2
      exit 0
    fi

    nohup socat -d -d \"VSOCK-LISTEN:${port},fork,reuseaddr\" \"TCP:${dst_host}:${dst_port}\" >'${log_path}' 2>&1 &
    echo \$! >'${pid_path}'
    disown || true

    for _ in \$(seq 1 50); do
      if ss -H -l --vsock \"sport = :${port}\" 2>/dev/null | grep -q LISTEN; then
        exit 0
      fi
      sleep 0.1
    done
    echo '[vm] http tunnel did not start listening in time' >&2
    tail -n 50 '${log_path}' >&2 || true
    exit 1
  "
}

ensure_gramine_env() {
  [[ -x "$GRAMINE_TDX_BIN" ]] || die "gramine-tdx not found: $GRAMINE_TDX_BIN"

  local py_site
  py_site="$(echo "$GRAMINE_TDX_DIR"/built-debug/lib/python*/site-packages | awk '{print $1}')"
  if [[ ! -d "$py_site" ]]; then
    die "could not find gramine python site-packages under gramine-tdx/built-debug/lib/python*/site-packages"
  fi

  export PATH="$GRAMINE_TDX_DIR/built-debug/bin:$PATH"
  export PYTHONPATH="$py_site:${PYTHONPATH:-}"
  export PKG_CONFIG_PATH="$GRAMINE_TDX_DIR/built-debug/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
}

do_setup() {
  local program_name="$1"
  local program_dir="$2"

  STARTED_PARENT_VM=0
  STARTED_FORWARDER=0
  STARTED_VIRTIOFSD=0
  STARTED_VCONSOLE=0

  ensure_parent_vm_running
  ensure_vm_layout

  scp_path "$GRAMINE_TDX_DIR/built-debug"
  scp_path "$SCRIPT_DIR/vsock_vm_console.py"
  scp_path "$HTTPS_PING_VM_SCRIPT"
  scp_program_dir "$program_dir"

  if ! vm_vsock_listening "$VIRTIOFSD_VSOCK_PORT"; then
    STARTED_VIRTIOFSD=1
  fi
  start_vm_virtiofsd

  if ! vm_tmux_has_session "gramine-vconsole"; then
    STARTED_VCONSOLE=1
  fi
  start_vm_vconsole_tmux

  if [[ "$ENABLE_HTTPS_PING" == "1" ]]; then
    start_vm_https_ping_helper
  fi

  if [[ "$ENABLE_HTTP_TUNNEL" == "1" ]]; then
    start_vm_http_tunnel
  fi

  start_host_forwarder

  log "ready."
  log "attach VM vconsole: ./vsock_vm.sh console"
}

shutdown_services() {
  set +e

  if [[ "$AUTO_SHUTDOWN" != "1" ]]; then
    set -e
    return 0
  fi

  log "shutting down services..."

  # Parent-VM services: always stop those owned by this workflow (fixed names/pidfiles).
  ssh_cmd "tmux kill-session -t gramine-vconsole >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

  ssh_cmd "set -euo pipefail
    pid_file='${REMOTE_RUN_DIR}/virtiofsd-vsock.pid'
    if [[ -f \"\$pid_file\" ]]; then
      pid=\"\$(cat \"\$pid_file\" 2>/dev/null || true)\"
      if [[ -n \"\$pid\" ]]; then
        kill -TERM \"\$pid\" >/dev/null 2>&1 || true
      fi
      rm -f \"\$pid_file\"
    fi
  " >/dev/null 2>&1 || true

  ssh_cmd "set -euo pipefail
    pid_file='${REMOTE_RUN_DIR}/https-ping.pid'
    if [[ -f \"\$pid_file\" ]]; then
      pid=\"\$(cat \"\$pid_file\" 2>/dev/null || true)\"
      if [[ -n \"\$pid\" ]]; then
        kill -TERM \"\$pid\" >/dev/null 2>&1 || true
      fi
      rm -f \"\$pid_file\"
    fi
  " >/dev/null 2>&1 || true

  ssh_cmd "set -euo pipefail
    pid_file='${REMOTE_RUN_DIR}/http-tunnel.pid'
    if [[ -f \"\$pid_file\" ]]; then
      pid=\"\$(cat \"\$pid_file\" 2>/dev/null || true)\"
      if [[ -n \"\$pid\" ]]; then
        kill -TERM \"\$pid\" >/dev/null 2>&1 || true
      fi
      rm -f \"\$pid_file\"
    fi
  " >/dev/null 2>&1 || true

  # Host forwarder: stop if we have a pidfile (we create it when starting or reusing).
  if [[ -f "$FWD_PIDFILE" ]]; then
    local pid=""
    pid="$(cat "$FWD_PIDFILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      local cmdline=""
      cmdline="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$cmdline" == *"vsock_forwarder.py"* ]]; then
        kill -TERM "$pid" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$FWD_PIDFILE"
  fi

  # Parent VM: stop if we have a qemu pidfile (we create it when starting).
  if [[ -f "$QEMU_PIDFILE" ]]; then
    ssh_cmd "sudo poweroff" >/dev/null 2>&1 || true
    # Wait briefly for ssh to go away; fall back to killing qemu.
    for _ in $(seq 1 40); do
      if ! vm_ssh_ready; then
        break
      fi
      sleep 0.25
    done
    if qemu_pid_running; then
      local pid=""
      pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
      if [[ -n "${pid:-}" ]]; then
        kill -TERM "$pid" >/dev/null 2>&1 || true
        for _ in $(seq 1 40); do
          if ! kill -0 "$pid" >/dev/null 2>&1; then
            break
          fi
          sleep 0.25
        done
        kill -KILL "$pid" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$QEMU_PIDFILE"
  fi

  set -e
}

cmd_run() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  [[ $# -gt 0 ]] || die "run requires <program_name|program_path> [program args...]"

  local program_spec="$1"
  shift

  local program_name=""
  local program_dir=""
  local program_bin=""
  local program_manifest=""

  if [[ "$program_spec" == /* || "$program_spec" == *"/"* ]]; then
    if [[ -d "$program_spec" ]]; then
      program_dir="$(realpath "$program_spec")"
      program_name="$(basename "$program_dir")"
      program_bin="$program_dir/$program_name"
      program_manifest="$program_dir/$program_name.manifest"
    else
      [[ -f "$program_spec" ]] || die "program not found: $program_spec"
      program_bin="$(realpath "$program_spec")"
      program_dir="$(dirname "$program_bin")"
      program_name="$(basename "$program_bin")"
      program_manifest="$program_dir/$program_name.manifest"
    fi
  else
    program_name="$program_spec"
    program_dir="$SCRIPT_DIR/$program_name"
    program_bin="$program_dir/$program_name"
    program_manifest="$program_dir/$program_name.manifest"
  fi

  [[ -d "$program_dir" ]] || die "program dir not found: $program_dir"
  [[ -f "$program_bin" ]] || die "program binary not found: $program_bin"
  [[ -f "$program_manifest" ]] || die "manifest not found: $program_manifest"

  do_setup "$program_name" "$program_dir"

  local stream_pid=""
  if [[ "$STREAM_CONSOLE" == "1" ]]; then
    log "streaming guest console output (disable with STREAM_CONSOLE=0)..."
    (
      ssh_cmd "tail -n 0 -F '$REMOTE_RUN_DIR/vconsole.log'" \
        | awk '{ print "[gramine-tdx] " $0; fflush(); }'
    ) &
    stream_pid="$!"
  fi

  cleanup_on_exit() {
    local exit_code="$?"
    trap - EXIT INT TERM
    if [[ -n "${stream_pid:-}" ]]; then
      kill "$stream_pid" >/dev/null 2>&1 || true
    fi
    shutdown_services
    exit "$exit_code"
  }
  trap cleanup_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ensure_gramine_env
  cd "$program_dir"
  log "starting gramine-tdx: $program_name $*"
  "$GRAMINE_TDX_BIN" "$program_name" "$@"
}

cmd_console() {
  if ! vm_ssh_ready; then
    die "parent VM not reachable via ssh; run: ./vsock_vm.sh run <program_name> [program args...]"
  fi
  ssh_cmd_tty "tmux attach -t gramine-vconsole || (cd '$REMOTE_VSOCK_DIR' && tmux new-session -s gramine-vconsole \"PYTHONUNBUFFERED=1 python3 vsock_vm_console.py --base-port '${VCONSOLE_BASE_PORT}'\")"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    run) cmd_run "$@" ;;
    console) cmd_console "$@" ;;
    -h|--help|"") usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
