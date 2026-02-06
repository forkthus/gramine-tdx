#!/usr/bin/env python3
import argparse
import socket
import sys
import threading
import os
import select
import signal


def pipe_sock_to_stdout(conn: socket.socket, stop: threading.Event, exit_on_disconnect: bool):
    try:
        conn.settimeout(1)
        while not stop.is_set():
            try:
                data = conn.recv(65536)
            except socket.timeout:
                continue
            if not data:
                return
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
    except OSError as e:
        if not stop.is_set():
            print(f"[vm-console] out pipe error: {e}", file=sys.stderr, flush=True)
    finally:
        if exit_on_disconnect:
            stop.set()
        try:
            conn.close()
        except Exception:
            pass


def pipe_stdin_to_sock(conn: socket.socket, stop: threading.Event, exit_on_disconnect: bool):
    try:
        stdin_fd = sys.stdin.fileno()
        while not stop.is_set():
            readable, _, _ = select.select([conn, stdin_fd], [], [], 1)

            if conn in readable:
                probe = conn.recv(1)
                if not probe:
                    return

            if stdin_fd in readable:
                chunk = os.read(stdin_fd, 65536)
                if not chunk:
                    return
                conn.sendall(chunk)
    except OSError as e:
        if not stop.is_set():
            print(f"[vm-console] in pipe error: {e}", file=sys.stderr, flush=True)
    finally:
        if exit_on_disconnect:
            stop.set()
        try:
            conn.shutdown(socket.SHUT_WR)
        except Exception:
            pass
        try:
            conn.close()
        except Exception:
            pass


def serve_out(port: int, stop: threading.Event):
    ls = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind((socket.VMADDR_CID_ANY, port))
    ls.listen()
    ls.settimeout(1)
    print(f"[vm-console] listen out :{port}", flush=True)
    try:
        while not stop.is_set():
            try:
                conn, (rcid, rport) = ls.accept()
            except socket.timeout:
                continue
            print(f"[vm-console] out conn from cid={rcid} port={rport}", flush=True)
            pipe_sock_to_stdout(conn, stop, True)
            stop.set()
            return
    finally:
        try:
            ls.close()
        except Exception:
            pass


def serve_in(port: int, stop: threading.Event):
    ls = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind((socket.VMADDR_CID_ANY, port))
    ls.listen()
    ls.settimeout(1)
    print(f"[vm-console] listen in :{port}", flush=True)
    try:
        while not stop.is_set():
            try:
                conn, (rcid, rport) = ls.accept()
            except socket.timeout:
                continue
            print(f"[vm-console] in conn from cid={rcid} port={rport}", flush=True)
            pipe_stdin_to_sock(conn, stop, True)
            stop.set()
            return
    finally:
        try:
            ls.close()
        except Exception:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-port", type=int, default=33222, help="Base port (default: 33222)")
    args = parser.parse_args()

    out_port = args.base_port
    in_port = args.base_port + 1

    stop = threading.Event()

    def _handle_signal(_signum, _frame):
        stop.set()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    t_out = threading.Thread(target=serve_out, args=(out_port, stop), daemon=True)
    t_in = threading.Thread(target=serve_in, args=(in_port, stop), daemon=True)
    t_out.start()
    t_in.start()

    try:
        stop.wait()
    except KeyboardInterrupt:
        stop.set()
    t_out.join()
    t_in.join()
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
