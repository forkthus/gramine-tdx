#!/usr/bin/env python3

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DEFAULT_APP = ROOT / "CI-Examples" / "helloworld" / "helloworld"
QEMU_LAUNCHER = ROOT / "built-debug" / "bin" / "gramine-tdx"
CH_LAUNCHER = ROOT / "built-debug" / "bin" / "gramine-tdx-cloud-hypervisor"

EVENTS = {
    40: "tdshim_start",
    41: "tdshim_accept_start",
    42: "tdshim_accept_done",
    43: "tdshim_payload_launch",
    44: "tdshim_payload_measure_start",
    45: "tdshim_payload_measure_done",
    50: "pal_start_c",
    51: "pal_before_first_thread",
    52: "pal_start_continue",
    53: "pal_before_pal_main",
}

CH_STAGE_PATTERNS = (
    ("start_vmm_thread", r"^vmm::start_vmm_thread$"),
    ("vm_boot_request", r"^<vmm::Vmm as vmm::api::RequestHandler>::vm_boot$"),
    ("vm_new", r"^vmm::vm::Vm::new$"),
    ("create_hypervisor_vm", r"^vmm::vm::Vm::create_hypervisor_vm$"),
    (
        "kvm_create_vm",
        r"^<hypervisor::kvm::KvmHypervisor as hypervisor::hypervisor::Hypervisor>::create_vm$",
    ),
    ("memory_manager_new", r"^vmm::memory_manager::MemoryManager::new$"),
    (
        "kvm_create_mem_region",
        r"^<hypervisor::kvm::KvmVm as hypervisor::vm::Vm>::create_user_memory_region$",
    ),
    (
        "kvm_build_user_memory_region2",
        r"^hypervisor::kvm::build_tdx_user_memory_region2$",
    ),
    ("vm_new_from_memory_manager", r"^vmm::vm::Vm::new_from_memory_manager$"),
    ("create_device_manager", r"^vmm::vm::Vm::create_device_manager$"),
    ("device_manager_new", r"^vmm::device_manager::DeviceManager::new$"),
    ("hypervisor_specific_init", r"^vmm::vm::Vm::hypervisor_specific_init$"),
    ("make_virtio_devices", r"^vmm::device_manager::DeviceManager::make_virtio_devices$"),
    ("add_pci_devices", r"^vmm::device_manager::DeviceManager::add_pci_devices$"),
    ("vm_boot", r"^vmm::vm::Vm::boot$"),
    ("populate_tdx_sections", r"^vmm::vm::Vm::populate_tdx_sections$"),
    ("initialize_tdx", r"^vmm::cpu::CpuManager::initialize_tdx$"),
    ("vcpu_tdx_init", r"^<hypervisor::kvm::KvmVcpu as hypervisor::cpu::Vcpu>::tdx_init$"),
    ("init_tdx_memory", r"^vmm::vm::Vm::init_tdx_memory$"),
    (
        "kvm_vcpu_tdx_map_memory_region",
        r"^<hypervisor::kvm::KvmVcpu as hypervisor::cpu::Vcpu>::tdx_map_memory_region$",
    ),
    (
        "kvm_tdx_init_memory_region",
        r"^<hypervisor::kvm::KvmVm as hypervisor::vm::Vm>::tdx_init_memory_region$",
    ),
    ("kvm_tdx_finalize", r"^<hypervisor::kvm::KvmVm as hypervisor::vm::Vm>::tdx_finalize$"),
    ("activate_vcpus", r"^vmm::cpu::CpuManager::activate_vcpus$"),
)

KVM_IOCTL_NAMES = {
    0x4020AE46: "KVM_SET_USER_MEMORY_REGION",
    0x40A0AE49: "KVM_SET_USER_MEMORY_REGION2",
    0xC008AEBA: "KVM_MEMORY_ENCRYPT_OP",
    0x4020AED2: "KVM_SET_MEMORY_ATTRIBUTES",
    0xC040AED4: "KVM_CREATE_GUEST_MEMFD",
    0xC020AED5: "KVM_MEMORY_MAPPING",
}

KVM_IOCTL_CONDITION = " || ".join(f"args->cmd == {cmd}" for cmd in KVM_IOCTL_NAMES)


def prepend(env, key, value):
    env[key] = f"{value}:{env[key]}" if env.get(key) else value


def default_cloud_hypervisor():
    profiling_bin = ROOT.parent / "cloud-hypervisor" / "target" / "profiling" / "cloud-hypervisor"
    if profiling_bin.is_file():
        return profiling_bin
    debug_bin = ROOT.parent / "cloud-hypervisor" / "target" / "debug" / "cloud-hypervisor"
    if debug_bin.is_file():
        return debug_bin
    return ROOT.parent / "cloud-hypervisor" / "target" / "release" / "cloud-hypervisor"


def default_qemu():
    candidates = [
        ROOT.parent / "qemu-tdx-8.2.2" / "build" / "qemu-system-x86_64",
        Path("/home/whji/qemu-tdx/build/qemu-system-x86_64"),
        # Path("/home/whji/vsock_vm/qemu-tdx/build/qemu-system-x86_64"),
        Path("/usr/bin/qemu-system-x86_64"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return candidates[-1]


def parse_args():
    parser = argparse.ArgumentParser(description="Run the Gramine TDX boot benchmark.")
    parser.add_argument("-vmm", choices=["qemu", "cloud-hypervisor"], required=True)
    parser.add_argument("--app", default=str(DEFAULT_APP))
    parser.add_argument("--qemu-path", default=str(default_qemu()))
    parser.add_argument("--cloud-hypervisor-path", default=str(default_cloud_hypervisor()))
    parser.add_argument("--disable-qgs", action="store_true")
    parser.add_argument("app_args", nargs=argparse.REMAINDER)
    return parser.parse_args()


def build_env():
    env = os.environ.copy()
    prepend(env, "PATH", str(ROOT / "built-debug" / "bin"))
    prepend(env, "PKG_CONFIG_PATH", str(ROOT / "built-debug" / "lib" / "pkgconfig"))
    python_sites = sorted((ROOT / "built-debug" / "lib").glob("python*/site-packages"))
    if python_sites:
        prepend(env, "PYTHONPATH", str(python_sites[0]))
    return env


def pick_vm_id(start=10, stop=4096):
    used = set()
    patterns = (
        re.compile(r"guest-cid=(\d+)"),
        re.compile(r"\bcid=(\d+)"),
        re.compile(r"gramine_vhostfs_(\d+)"),
        re.compile(r"gramine_clh_vsock_(\d+)"),
    )

    for proc_dir in Path("/proc").iterdir():
        if not proc_dir.name.isdigit():
            continue
        try:
            cmdline = (proc_dir / "cmdline").read_bytes().replace(b"\x00", b" ").decode(
                "utf-8", errors="ignore"
            )
        except OSError:
            continue
        for pattern in patterns:
            for match in pattern.finditer(cmdline):
                used.add(int(match.group(1)))

    for vm_id in range(start, stop):
        if vm_id not in used:
            return vm_id

    raise SystemExit("Failed to find a free GRAMINE_VM_ID.")


def find_symbol(binary, pattern):
    proc = subprocess.run(
        [shutil.which("nm") or "nm", "-anC", str(binary)],
        check=True,
        text=True,
        capture_output=True,
    )
    regex = re.compile(pattern)
    for line in proc.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and regex.search(parts[2]):
            return parts[0]
    return None


def resolve_offsets(binary, vmm):
    main_offset = find_symbol(binary, r"^main$")
    if not main_offset:
        raise SystemExit(
            f"Failed to resolve main() in {binary}. "
            "This usually means the binary is stripped; pass --qemu-path/--cloud-hypervisor-path "
            "to an unstripped build."
        )
    if vmm == "qemu":
        run_offset = find_symbol(binary, r"^kvm_cpu_exec$")
    else:
        run_offset = None
        for pattern in (
            r"KvmVcpu.*::run($|::)",
            r"vmm::cpu::Vcpu::run($|::)",
            r"hypervisor::kvm::.*run($|::)",
        ):
            run_offset = find_symbol(binary, pattern)
            if run_offset:
                break
    if not run_offset:
        raise SystemExit(f"Failed to resolve first-run symbol in {binary}.")
    stage_offsets = []
    if vmm == "cloud-hypervisor":
        for name, pattern in CH_STAGE_PATTERNS:
            offset = find_symbol(binary, pattern)
            if offset:
                stage_offsets.append((name, offset))
    return main_offset, run_offset, stage_offsets


def bpftrace_program(vmm_bin, main_offset, run_offset, stage_offsets):
    stage_probes = "\n".join(
        f"""u:{vmm_bin}:0x{offset} {{ printf("%llu: CH: {name}:enter\\n", nsecs); }}
ur:{vmm_bin}:0x{offset} {{ printf("%llu: CH: {name}:exit\\n", nsecs); }}"""
        for name, offset in stage_offsets
    )
    return f"""BEGIN {{
    @seen_guest_run = 0;
    @EVENT[40] = "td-shim: start";
    @EVENT[41] = "td-shim: accept start";
    @EVENT[42] = "td-shim: accept done";
    @EVENT[43] = "td-shim: payload launch";
    @EVENT[44] = "td-shim: payload measure start";
    @EVENT[45] = "td-shim: payload measure done";
    @EVENT[50] = "pal: start_c";
    @EVENT[51] = "pal: before_first_thread";
    @EVENT[52] = "pal: start_continue";
    @EVENT[53] = "pal: before_pal_main";
}}
u:{vmm_bin}:0x{main_offset} {{ printf("%llu: VMM: main\\n", nsecs); }}
u:{vmm_bin}:0x{main_offset} {{ @vmm_pid[pid] = 1; }}
ur:{vmm_bin}:0x{main_offset} {{ printf("%llu: VMM: exit\\n", nsecs); @seen_guest_run = 0; delete(@vmm_pid[pid]); }}
u:{vmm_bin}:0x{run_offset} / @seen_guest_run == 0 / {{
    @seen_guest_run = 1;
    printf("%llu: VMM: first_guest_run\\n", nsecs);
}}
{stage_probes}
tracepoint:syscalls:sys_enter_ioctl / @vmm_pid[pid] && ({KVM_IOCTL_CONDITION}) / {{
    @ioctl_start[tid] = nsecs;
    @ioctl_cmd[tid] = args->cmd;
}}
tracepoint:syscalls:sys_exit_ioctl / @ioctl_start[tid] / {{
    printf("%llu: KVMIOCTL: 0x%x %d %llu\\n", nsecs, @ioctl_cmd[tid], args->ret, nsecs - @ioctl_start[tid]);
    delete(@ioctl_start[tid]);
    delete(@ioctl_cmd[tid]);
}}
tracepoint:kvm:kvm_pio / args->port == 0xf4 / {{
    printf("%llu: %d %s\\n", nsecs, args->val, @EVENT[args->val]);
}}
END {{ clear(@seen_guest_run); clear(@EVENT); clear(@vmm_pid); clear(@ioctl_start); clear(@ioctl_cmd); }}
"""


def parse_trace(raw_text, launcher_lines):
    events = {}
    event_times = defaultdict(list)
    ioctl_times = defaultdict(list)
    timeline = []
    saw_pio_markers = False

    def record(name, ts):
        events.setdefault(name, ts)
        event_times[name].append(ts)
        timeline.append((name, ts))

    for line in raw_text.splitlines():
        line = line.strip()
        if not line or line.startswith("Attaching "):
            continue
        if ": VMM: main" in line:
            record("vmm_main", int(line.split(":", 1)[0]))
            continue
        if ": VMM: first_guest_run" in line:
            record("vmm_first_guest_run", int(line.split(":", 1)[0]))
            continue
        if ": VMM: exit" in line:
            events.setdefault("vmm_exit", int(line.split(":", 1)[0]))
            continue
        if ": KVMIOCTL: " in line:
            ts_str, payload = line.split(": KVMIOCTL: ", 1)
            fields = payload.split()
            if len(fields) != 3:
                continue
            try:
                ts = int(ts_str)
                cmd = int(fields[0], 16)
                ret = int(fields[1])
                duration = int(fields[2])
            except ValueError:
                continue
            name = KVM_IOCTL_NAMES.get(cmd, f"0x{cmd:x}")
            ioctl_times[name].append((ts - duration, ts, duration, ret))
            continue
        if ": CH: " in line:
            ts_str, payload = line.split(": CH: ", 1)
            try:
                ts = int(ts_str)
            except ValueError:
                continue
            fields = payload.rsplit(":", 1)
            if len(fields) != 2:
                continue
            name, phase = fields
            if phase in ("enter", "exit"):
                record(f"ch_{name}_{phase}", ts)
            continue
        parts = line.split(": ", 1)
        if len(parts) != 2:
            continue
        fields = parts[1].split(" ", 1)
        if len(fields) != 2:
            continue
        try:
            ts = int(parts[0])
            code = int(fields[0])
        except ValueError:
            continue
        if code in EVENTS:
            saw_pio_markers = True
            record(EVENTS[code], ts)

    if not saw_pio_markers:
        marker_re = re.compile(r"GRAMINE_BOOT_MARKER:\s*(?:(\d+)\s+)?(\d+)")
        synthetic_ts = events.get("vmm_first_guest_run", 0)
        for line in launcher_lines:
            match = marker_re.search(line)
            if not match:
                continue
            logged_ts, code_str = match.groups()
            code = int(code_str)
            if code not in EVENTS:
                continue
            if logged_ts:
                record(EVENTS[code], int(logged_ts))
            else:
                synthetic_ts += 1
                record(EVENTS[code], synthetic_ts)

    timeline.sort(key=lambda item: item[1])
    return events, event_times, timeline, ioctl_times


def print_results(events, event_times, timeline, ioctl_times):
    def first(name):
        values = event_times.get(name)
        return values[0] if values else None

    def last(name):
        values = event_times.get(name)
        return values[-1] if values else None

    def delta(label, start, end, use_last_start=False, use_last_end=False):
        start_ts = last(start) if use_last_start else first(start)
        end_ts = last(end) if use_last_end else first(end)
        if start_ts is not None and end_ts is not None:
            print(f"{label:32s} {(end_ts - start_ts) / 1e6:10.3f} ms")

    def stage_intervals(name):
        starts = event_times.get(f"ch_{name}_enter", [])
        ends = event_times.get(f"ch_{name}_exit", [])
        intervals = []
        end_idx = 0
        for start_ts in starts:
            while end_idx < len(ends) and ends[end_idx] < start_ts:
                end_idx += 1
            if end_idx == len(ends):
                break
            intervals.append((start_ts, ends[end_idx]))
            end_idx += 1
        return intervals

    def print_stage(label, name, indent=0):
        start_ts = first(f"ch_{name}_enter")
        end_ts = last(f"ch_{name}_exit")
        if start_ts is not None and end_ts is not None:
            print(f"{'  ' * indent}{label:42s} {(end_ts - start_ts) / 1e6:10.3f} ms")

    def print_stage_total(label, name, indent=0, within=None):
        intervals = stage_intervals(name)
        if within is not None:
            parents = stage_intervals(within)
            intervals = [
                (start_ts, end_ts)
                for start_ts, end_ts in intervals
                if any(
                    parent_start <= start_ts and end_ts <= parent_end
                    for parent_start, parent_end in parents
                )
            ]
        if not intervals:
            return
        total = sum(end_ts - start_ts for start_ts, end_ts in intervals)
        suffix = f" ({len(intervals)} calls)" if len(intervals) != 1 else ""
        print(f"{'  ' * indent}{label:42s} {total / 1e6:10.3f} ms{suffix}")

    def print_transition(label, start, end, indent=0, use_last_end=False):
        start_ts = first(start)
        end_ts = last(end) if use_last_end else first(end)
        if start_ts is not None and end_ts is not None:
            print(f"{'  ' * indent}{label:42s} {(end_ts - start_ts) / 1e6:10.3f} ms")

    print("\n=== summary ===")
    for name, ts in events.items():
        print(f"{name:24s} {ts}")

    print("\n=== deltas ===")
    delta("vmm main -> first guest run", "vmm_main", "vmm_first_guest_run")
    delta("first guest run -> td-shim start", "vmm_first_guest_run", "tdshim_start")
    delta("td-shim start -> accept start", "tdshim_start", "tdshim_accept_start")
    delta("td-shim accept total", "tdshim_accept_start", "tdshim_accept_done", use_last_end=True)
    delta(
        "accept done -> payload measure",
        "tdshim_accept_done",
        "tdshim_payload_measure_start",
        use_last_start=True,
    )
    delta("td-shim payload measure", "tdshim_payload_measure_start", "tdshim_payload_measure_done")
    delta("payload measure -> payload launch", "tdshim_payload_measure_done", "tdshim_payload_launch")
    delta(
        "accept done -> payload launch",
        "tdshim_accept_done",
        "tdshim_payload_launch",
        use_last_start=True,
    )
    delta("payload launch -> PAL start_c", "tdshim_payload_launch", "pal_start_c")
    delta("PAL start_c -> before first thread", "pal_start_c", "pal_before_first_thread")
    delta("before first thread -> start_continue", "pal_before_first_thread", "pal_start_continue")
    delta("PAL start_continue -> before pal_main", "pal_start_continue", "pal_before_pal_main")

    if any(name.startswith("ch_") for name in event_times):
        print("\n=== cloud-hypervisor setup ===")
        print_transition("[fn] main() -> Vmm::vm_boot()", "vmm_main", "ch_vm_boot_request_enter")
        print_stage("[fn] Vmm::vm_boot() total", "vm_boot_request")
        print_transition(
            "[fn] Vmm::vm_boot() -> Vm::new()",
            "ch_vm_boot_request_enter",
            "ch_vm_new_enter",
            indent=1,
        )
        print_stage("[fn] Vm::new() total", "vm_new", indent=1)
        print_stage("[fn] Vm::create_hypervisor_vm()", "create_hypervisor_vm", indent=2)
        print_stage("[fn] KvmHypervisor::create_vm()", "kvm_create_vm", indent=3)
        print_stage("[fn] MemoryManager::new()", "memory_manager_new", indent=2)
        print_stage("[fn] Vm::new_from_memory_manager()", "vm_new_from_memory_manager", indent=2)
        print_stage("[fn] Vm::create_device_manager()", "create_device_manager", indent=3)
        print_stage("[fn] DeviceManager::new()", "device_manager_new", indent=4)
        print_stage("[fn] Vm::hypervisor_specific_init()", "hypervisor_specific_init", indent=3)
        print_stage_total(
            "[fn] KvmVm::create_user_memory_region()",
            "kvm_create_mem_region",
            indent=4,
            within="hypervisor_specific_init",
        )
        print_stage_total(
            "[fn] build_tdx_user_memory_region2()",
            "kvm_build_user_memory_region2",
            indent=5,
            within="hypervisor_specific_init",
        )
        print_stage("[fn] DeviceManager::make_virtio_devices()", "make_virtio_devices", indent=4)
        print_stage("[fn] DeviceManager::add_pci_devices()", "add_pci_devices", indent=4)
        print_stage("[fn] Vm::boot() total", "vm_boot", indent=1)
        print_stage("[fn] Vm::populate_tdx_sections()", "populate_tdx_sections", indent=2)
        print_stage_total(
            "[fn] KvmVm::create_user_memory_region()",
            "kvm_create_mem_region",
            indent=3,
            within="populate_tdx_sections",
        )
        print_stage_total(
            "[fn] build_tdx_user_memory_region2()",
            "kvm_build_user_memory_region2",
            indent=4,
            within="populate_tdx_sections",
        )
        print_stage("[fn] CpuManager::initialize_tdx()", "initialize_tdx", indent=2)
        print_stage("[fn] KvmVcpu::tdx_init()", "vcpu_tdx_init", indent=3)
        print_stage("[fn] Vm::init_tdx_memory()", "init_tdx_memory", indent=2)
        print_stage_total(
            "[fn] KvmVcpu::tdx_map_memory_region()",
            "kvm_vcpu_tdx_map_memory_region",
            indent=3,
        )
        print_stage_total(
            "[fn] KvmVm::tdx_init_memory_region()",
            "kvm_tdx_init_memory_region",
            indent=3,
        )
        print_stage("[fn] KvmVm::tdx_finalize()", "kvm_tdx_finalize", indent=2)
        print_stage("[fn] CpuManager::activate_vcpus()", "activate_vcpus", indent=2)

    if ioctl_times:
        def print_ioctl_totals(title, filtered):
            if not filtered:
                return
            print(f"\n=== {title} ===")
            for name, samples in sorted(
                filtered.items(), key=lambda item: sum(v[2] for v in item[1]), reverse=True
            ):
                total = sum(duration for _, _, duration, _ in samples)
                failed = sum(1 for _, _, _, ret in samples if ret < 0)
                suffix = f", {failed} failed" if failed else ""
                print(f"{name:34s} {total / 1e6:10.3f} ms ({len(samples)} calls{suffix})")

        first_run_ts = first("vmm_first_guest_run")
        if first_run_ts is not None:
            before_first_run = {
                name: [sample for sample in samples if sample[1] <= first_run_ts]
                for name, samples in ioctl_times.items()
            }
            before_first_run = {name: samples for name, samples in before_first_run.items() if samples}
            print_ioctl_totals("KVM ioctl totals before first guest run", before_first_run)

        print_ioctl_totals("KVM ioctl totals whole process", ioctl_times)

    print("\n=== timeline ===")
    for idx in range(1, len(timeline)):
        prev_name, prev_ts = timeline[idx - 1]
        name, ts = timeline[idx]
        print(f"{prev_name:24s} -> {name:24s} {(ts - prev_ts) / 1e6:10.3f} ms")


def main():
    args = parse_args()
    app_path = Path(args.app).expanduser().resolve()
    app_args = args.app_args[1:] if args.app_args[:1] == ["--"] else args.app_args
    if not app_path.is_file():
        raise SystemExit(f"Application not found: {app_path}")

    if args.vmm == "qemu":
        launcher = QEMU_LAUNCHER
        vmm_bin = Path(args.qemu_path).expanduser().resolve()
    else:
        launcher = CH_LAUNCHER
        vmm_bin = Path(args.cloud_hypervisor_path).expanduser().resolve()

    if not launcher.is_file() or not os.access(launcher, os.X_OK):
        raise SystemExit(f"Launcher not found or not executable: {launcher}")
    if not vmm_bin.is_file() or not os.access(vmm_bin, os.X_OK):
        raise SystemExit(f"VMM binary not found or not executable: {vmm_bin}")

    env = build_env()
    env.setdefault("GRAMINE_VM_ID", str(pick_vm_id()))
    if args.vmm == "qemu":
        env["QEMU_PATH"] = str(vmm_bin)
        if args.disable_qgs:
            env["GRAMINE_QEMU_DISABLE_QGS"] = "1"
    else:
        env["CLOUD_HYPERVISOR_PATH"] = str(vmm_bin)

    main_offset, run_offset, stage_offsets = resolve_offsets(vmm_bin, args.vmm)
    print(f"Using launcher: {launcher}")
    print(f"Using VMM binary: {vmm_bin}")
    print(f"Using GRAMINE_VM_ID: {env['GRAMINE_VM_ID']}")
    print(f"Using probes: main=0x{main_offset} run=0x{run_offset}")
    if stage_offsets:
        print(f"Using Cloud Hypervisor stage probes: {len(stage_offsets)}")

    if os.geteuid() != 0:
        subprocess.run(["sudo", "-v"], check=True)

    bpf = subprocess.Popen(
        (["bpftrace"] if os.geteuid() == 0 else ["sudo", "-n", "bpftrace"]) + ["-"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    assert bpf.stdin is not None
    bpf.stdin.write(bpftrace_program(vmm_bin, main_offset, run_offset, stage_offsets))
    bpf.stdin.close()

    time.sleep(2)

    launcher_lines = []
    launcher_proc = subprocess.Popen(
        [str(launcher), f"./{app_path.name}", *app_args],
        cwd=app_path.parent,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert launcher_proc.stdout is not None
    for line in launcher_proc.stdout:
        sys.stdout.write(line)
        launcher_lines.append(line)
    launcher_rc = launcher_proc.wait()

    time.sleep(1)
    if bpf.poll() is None:
        bpf.terminate()
        try:
            bpf.wait(timeout=5)
        except subprocess.TimeoutExpired:
            bpf.kill()
            bpf.wait()

    raw_text = bpf.stdout.read() if bpf.stdout is not None else ""
    events, event_times, timeline, ioctl_times = parse_trace(raw_text, launcher_lines)
    print_results(events, event_times, timeline, ioctl_times)
    raise SystemExit(launcher_rc)


if __name__ == "__main__":
    main()
