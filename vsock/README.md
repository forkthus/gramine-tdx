# Gramine-TDX <-> VM over vsock

## Layout
- `vsock_readme_menu`: Sample program for testing the console and virtio-fs over vsock.
- `vsock_forwarder.py`: Program that runs on the host to forward requests between Gramine-TDX and the parent VM.
- `vsock_vm_console.py`: Program that runs on the parent VM and acts as a remote console for Gramine-TDX.
- `routes.json`: Config used by `vsock_forwarder.py` for port mapping between Gramine-TDX and the parent VM.

## Default ports
- `31337`: virtio-fs over vsock (for `virtiofsd` on the parent VM).
- `33222`: vconsole stdout/stderr base port.
- `33223`: vconsole stdin (base port + 1).

## Setup: Gramine-TDX ↔ parent VM
1. Update `routes.json` to include the ports above. In the current `routes.json`:
   - `31337` is used for virtio-fs over vsock.
   - `33222` is used for vconsole stdout/stderr.
   - `33223` is used for vconsole stdin.

2. Copy artifacts (LibOS and app) from the host to the parent VM.
   Keep the same absolute path on the parent VM.

   Example: if the artifacts are on the host at:
   - `/home/user/vsock_vm/gramine-tdx/built-debug`
   - `/home/user/vsock_vm/gramine-tdx/vsock/vsock_readme_menu/`

   Copy them to the parent VM at the exact same path:
   - `/home/user/vsock_vm/gramine-tdx/built-debug`
   - `/home/user/vsock_vm/gramine-tdx/vsock/vsock_readme_menu/`

3. On the parent VM, run the following command to start `virtiofsd`:

   ```sh
   ./virtiofsd --shared-dir / --sandbox none --no-announce-submounts --log-level debug --vsock 31337 &
   ```

   `31337` is the port that `virtiofsd` listens on in the parent VM to accept virtio-fs requests from Gramine-TDX (forwarded from the host). It is currently fixed in the `gramine-tdx` codebase.

4. On the parent VM, run the following command to start the console:

   ```sh
   python3 vsock_vm_console.py --base-port 33222
   ```

   `33222` is the base port for the vconsole and is currently fixed in the `gramine-tdx` codebase.
   stdout/stderr use the base port, and stdin uses base port + 1.

5. On the host, run the following command to start the forwarder:

   ```sh
   python3 vsock_forwarder.py routes.json
   ```

6. On the host, run the following command to start the sample program:

   ```sh
   gramine-tdx vsock_readme_menu
   ```

7. Use the parent VM console to control the program.
