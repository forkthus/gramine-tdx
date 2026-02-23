# iperf3

Run from the parent directory:

```sh
cd ../
```

## CoVM path (via parent VM)

```sh
./run_iperf3_CoVM.sh
```

Pass client args after `--`:

```sh
./run_iperf3_CoVM.sh -- -t 10 -P 4
```

What the wrapper does:
- Starts host `iperf3` server (`tcp/5201` by default).
- Starts parent-VM tunnel from VSOCK to host TCP.
- Runs Gramine-TDX `iperf3` client through `./vsock_vm.sh`.

## Upstream path (direct gramine-tdx)

```sh
./run_iperf3_upstream.sh
```

Pass client args after `--`:

```sh
./run_iperf3_upstream.sh -- -t 10 -P 4
```

What the wrapper does:
- Starts host `iperf3` server (`tcp/5201` by default).
- Starts host `socat` VSOCK bridge (`vsock/5201` by default).
- Runs upstream Gramine `iperf3` client directly.

## Useful options

CoVM wrapper:
- `--host-port N`
- `--vsock-port N`
- `--vm-gateway IP`
- `--td-host IP`

Upstream wrapper:
- `--host-port N`
- `--vsock-port N`
- `--port N` (sets both host and vsock ports)
- `--td-host IP`
