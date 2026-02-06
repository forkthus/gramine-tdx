#!/usr/bin/env python3
import json
import socket
import threading
import sys
from typing import Dict, Tuple

def pipe(src: socket.socket, dst: socket.socket, label: str):
    logged = False
    try:
        while True:
            data = src.recv(65536)
            if not data:
                return
            if not logged:
                print(f"[host] forwarding {label} ...", flush=True)
                logged = True
            dst.sendall(data)
    except OSError as e:
        print(f"[host] pipe error {label}: {e}", file=sys.stderr, flush=True)
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass


def pump(a: socket.socket, b: socket.socket):
    t1 = threading.Thread(target=pipe, args=(a, b, "client->dst"), daemon=True)
    t2 = threading.Thread(target=pipe, args=(b, a, "dst->client"), daemon=True)
    t1.start()
    t2.start()

def serve_one(listen_port: int, dst: Tuple[int, int]):
    ls = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        ls.bind((socket.VMADDR_CID_ANY, listen_port))
    except OSError as e:
        print(
            f"[host] bind failed on vsock port {listen_port}: {e}.",
            file=sys.stderr,
            flush=True,
        )
        try:
            ls.close()
        except Exception:
            pass
        return
    ls.listen()
    dst_cid, dst_port = dst
    print(f"[host] listen :{listen_port}  ->  cid={dst_cid} port={dst_port}", flush=True)

    while True:
        conn = None
        out = None
        try:
            conn, (rcid, rport) = ls.accept()
            out = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            out.connect((dst_cid, dst_port))
            print(
                f"[host] conn from cid={rcid} port={rport} -> cid={dst_cid} port={dst_port} (via {listen_port})",
                flush=True,
            )
            threading.Thread(target=pump, args=(conn, out), daemon=True).start()
        except Exception as e:
            print(f"[host] forward error on listen {listen_port}: {e}", file=sys.stderr, flush=True)
            try:
                if conn:
                    conn.close()
            except Exception:
                pass
            try:
                if out:
                    out.close()
            except Exception:
                pass

def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <config.json>", file=sys.stderr)
        sys.exit(2)

    cfg_path = sys.argv[1]
    with open(cfg_path, "r") as f:
        cfg = json.load(f)

    # config format: { "20000": [4, 12345], "20001": [3, 23456] }
    mapping: Dict[int, Tuple[int, int]] = {}
    for k, v in cfg.items():
        lp = int(k)
        mapping[lp] = (int(v[0]), int(v[1]))

    for lp, dst in mapping.items():
        threading.Thread(target=serve_one, args=(lp, dst), daemon=True).start()

    # keep main alive
    threading.Event().wait()

if __name__ == "__main__":
    main()
