#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/esnet/iperf.git"
MODE="${1:-build}"
if [[ "$MODE" == "clean" ]]; then
    shift || true
else
    MODE="build"
fi
REPO_DIR="${1:-$SCRIPT_DIR/iperf-src}"

usage() {
    cat <<EOF
usage:
  $0 [path-to-iperf-source]
  $0 clean [path-to-iperf-source]
EOF
}

if [[ $# -gt 1 ]]; then
    usage
    exit 1
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: missing required command: $1" >&2
        exit 1
    }
}

need_cmd git
need_cmd make
need_cmd ldd
need_cmd awk
need_cmd grep
need_cmd perl
need_cmd gcc

if [[ "$MODE" == "clean" ]]; then
    rm -f "$SCRIPT_DIR/iperf3"
    rm -rf "$SCRIPT_DIR/lib"
    (
        cd "$SCRIPT_DIR"
        make clean >/dev/null 2>&1 || true
    )
    rm -rf "$REPO_DIR"
    echo "Cleaned iperf3 artifacts and source repo from: $SCRIPT_DIR"
    exit 0
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
    mkdir -p "$(dirname -- "$REPO_DIR")"
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
else
    echo "Using existing iperf source repo: $REPO_DIR"
fi

cd "$REPO_DIR"
make distclean >/dev/null 2>&1 || make clean >/dev/null 2>&1 || true

# Force configure to behave as if TCP_CONGESTION sockopt is unavailable.
iperf3_cv_header_tcp_congestion=no ./configure

if grep -Eq '^[[:space:]]*#define[[:space:]]+HAVE_TCP_CONGESTION[[:space:]]+1' src/iperf_config.h; then
    echo "error: HAVE_TCP_CONGESTION is still enabled in src/iperf_config.h" >&2
    exit 1
fi

# # Upstream currently guards `saved_errno` with HAVE_TCP_CONGESTION, but it is also
# # used in a HAVE_TCP_USER_TIMEOUT block. Make the declaration unconditional.
if grep -Eq '^[[:space:]]*#if defined\(HAVE_TCP_CONGESTION\)' src/iperf_server_api.c; then
    perl -0pi -e '
        s/#if defined\(HAVE_TCP_CONGESTION\)\n[ \t]*int saved_errno;\n#endif \/\* HAVE_TCP_CONGESTION \*\//    int saved_errno;/s
    ' src/iperf_server_api.c
fi

# Gramine may return ENOSYS from pthread_cancel/pthread_kill paths; don't fail teardown on it.
perl -0pi -e '
    s/rc != 0 && rc != ESRCH/rc != 0 && rc != ESRCH && rc != ENOSYS/g
' src/iperf_client_api.c src/iperf_server_api.c

make -j"$(nproc)"

BIN_SRC="$REPO_DIR/src/.libs/iperf3"
LIB_SRC_DIR="$REPO_DIR/src/.libs"
LIB_MAIN="$LIB_SRC_DIR/libiperf.so.0.0.0"

if [[ ! -x "$BIN_SRC" ]]; then
    echo "error: built iperf3 binary not found at: $BIN_SRC" >&2
    exit 1
fi
if [[ ! -f "$LIB_MAIN" ]]; then
    echo "error: built libiperf shared library not found at: $LIB_MAIN" >&2
    exit 1
fi

install -m 0755 "$BIN_SRC" "$SCRIPT_DIR/iperf3"
rm -rf "$SCRIPT_DIR/lib"
mkdir -p "$SCRIPT_DIR/lib"

# Stage libiperf symlink chain produced by libtool.
cp -a "$LIB_SRC_DIR"/libiperf.so* "$SCRIPT_DIR/lib/"

# Stage extra non-glibc shared libraries required by the built artifacts.
{
    ldd "$BIN_SRC"
    ldd "$LIB_MAIN"
} | awk '
    /=>/ { for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }
    $1 ~ /^\// { print $1 }
' | sort -u | while read -r lib; do
    [[ -n "$lib" ]] || continue
    base="$(basename -- "$lib")"
    case "$base" in
        libiperf.so*|ld-linux-*.so.*|libc.so.*|libm.so.*|libmvec.so.*|libpthread.so.*|librt.so.*|libdl.so.*|libresolv.so.*|libutil.so.*)
            continue
            ;;
    esac
    cp -L "$lib" "$SCRIPT_DIR/lib/"
done

# glibc loads libgcc_s lazily for pthread cancellation paths, so it may not show up in ldd output.
libgcc_s="$(gcc -print-file-name=libgcc_s.so.1 2>/dev/null || true)"
if [[ -n "$libgcc_s" && "$libgcc_s" != "libgcc_s.so.1" && -f "$libgcc_s" ]]; then
    cp -L "$libgcc_s" "$SCRIPT_DIR/lib/"
else
    echo "warning: failed to locate libgcc_s.so.1; pthread_cancel may fail at runtime" >&2
fi

cd "$SCRIPT_DIR"
make clean
make SGX=1

echo "Built and packaged iperf3 at: $SCRIPT_DIR/iperf3"
