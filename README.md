# Component Probes Demo

Attribute CPU usage to individual Vector pipeline components using eBPF —
without modifying Vector's hot path.

## Quick Start

```bash
docker build -t vector-probes .
docker run --rm -it --privileged --pid=host vector-probes
```

Build takes ~15-30 min the first time (Rust compile); cached after that.

## What It Does

Runs a pipeline: `gen` (demo_logs) -> `crunch` (triple-SHA-256) -> `devnull` (blackhole)

A bpftrace script attaches to Vector's probe points and prints a per-component
CPU breakdown every 5 seconds. The `crunch` transform is intentionally heavy
so it clearly dominates the profile.

## Expected Output

```
[component] id=1 name=gen
[component] id=2 name=crunch
[component] id=3 name=devnull
[thread]    tid=1234 addr=0x...

@cpu[crunch]: 4400
@cpu[(idle)]: 2800
@cpu[devnull]:  550
@cpu[gen]:      130
```

Each `@cpu[name]: N` line is a sample count — how many times the profiler
(~997 Hz per core) caught a thread inside that component during the 5-second
window. Higher = more CPU time.

`(idle)` means Vector threads running outside any component — Tokio runtime
overhead, channel operations, scheduling. Normal and expected (typically
20-40% of samples).

## Files

Everything lives in two files:

| File | What |
|------|------|
| `Dockerfile` | Multi-stage build: compiles Vector with `component-probes`, installs bpftrace |
| `run-demo.sh` | Inline Vector config + bpftrace script, orchestrates both processes |

## Docker Flags

| Flag | Why |
|------|-----|
| `--privileged` | Required for bpftrace to load eBPF programs |
| `--pid=host` | Required so bpftrace TIDs match Vector's actual TIDs |
