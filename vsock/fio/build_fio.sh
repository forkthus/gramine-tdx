#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/axboe/fio.git"
MODE="${1:-build}"
if [[ "$MODE" == "clean" ]]; then
    shift || true
else
    MODE="build"
fi
REPO_DIR="${1:-$SCRIPT_DIR/fio-src}"

usage() {
    cat <<EOF
usage:
  $0 [path-to-fio-source]
  $0 clean [path-to-fio-source]
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

if [[ "$MODE" == "clean" ]]; then
    rm -f "$SCRIPT_DIR/fio"
    rm -rf "$SCRIPT_DIR/lib"
    (
        cd "$SCRIPT_DIR"
        make clean >/dev/null 2>&1 || true
    )
    rm -rf "$REPO_DIR"
    echo "Cleaned fio artifacts and source repo from: $SCRIPT_DIR"
    exit 0
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
    mkdir -p "$(dirname -- "$REPO_DIR")"
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
else
    echo "Using existing fio source repo: $REPO_DIR"
fi

if [[ ! -x "$REPO_DIR/configure" ]]; then
    echo "error: fio source repo not found at: $REPO_DIR" >&2
    usage >&2
    exit 1
fi

cd "$REPO_DIR"
make clean >/dev/null 2>&1 || true

./configure \
    --build-static \
    --disable-rdma \
    --disable-rados \
    --disable-rbd \
    --disable-http \
    --disable-gfapi \
    --disable-pmem \
    --disable-libnfs \
    --disable-xnvme \
    --disable-libblkio \
    --disable-libzbc \
    --disable-dfs \
    --disable-numa \
    --disable-lex \
    --disable-shm

# Gramine-TDX path does not support timerfd_create reliably; force fallback path in fio.
sed -i '/^#define CONFIG_HAVE_TIMERFD_CREATE$/d' config-host.h

# Gramine does not support nice(0); avoid failing default jobs that don't request a custom nice value.
if ! rg -q 'if \(o->nice != 0\)' backend.c; then
    perl -0pi -e 's@errno = 0;\n\s*if \(nice\(o->nice\) == -1 && errno != 0\) {\n\s*td_verror\(td, errno, "nice"\);\n\s*goto err;\n\s*}\n@if (o->nice != 0) {\n\t\terrno = 0;\n\t\tif (nice(o->nice) == -1 && errno != 0) {\n\t\t\ttd_verror(td, errno, "nice");\n\t\t\tgoto err;\n\t\t}\n\t}\n@s' backend.c
fi

make -j"$(nproc)" fio
"$REPO_DIR/fio" --version

install -m 0755 "$REPO_DIR/fio" "$SCRIPT_DIR/fio"
rm -rf "$SCRIPT_DIR/lib"
mkdir -p "$SCRIPT_DIR/lib"

if file "$SCRIPT_DIR/fio" | grep -qi "statically linked"; then
    echo "Static fio build detected; no extra shared libraries needed."
else
    echo "Dynamic fio build detected; staging shared libraries in $SCRIPT_DIR/lib."
    ldd "$SCRIPT_DIR/fio" | awk '
        /=>/ { for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }
        $1 ~ /^\// { print $1 }
    ' | sort -u | while read -r lib; do
        base="$(basename -- "$lib")"
        case "$base" in
            ld-linux-*.so.*|libc.so.*|libm.so.*|libmvec.so.*|libpthread.so.*|librt.so.*|libdl.so.*|libresolv.so.*|libutil.so.*)
                continue
                ;;
        esac
        cp -L "$lib" "$SCRIPT_DIR/lib/"
    done
fi

cd "$SCRIPT_DIR"
make clean
make SGX=1

echo "Built and packaged fio at: $SCRIPT_DIR/fio"
