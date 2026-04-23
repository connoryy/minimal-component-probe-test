# Vector Component Probes — Minimal Demo

A self-contained Docker demo that shows **per-component CPU profiling** for [Vector](https://vector.dev) using eBPF/bpftrace, powered by the experimental `component-probes` feature.

## What it does

Vector's `component-probes` feature exposes lightweight probe points that let external tools (bpftrace, SystemTap, DTrace) observe which pipeline component each thread is executing. This demo:

1. Builds Vector from the [`component-probes`](https://github.com/connoryy/vector/tree/component-probes) branch with a minimal feature set
2. Runs a simple pipeline: `demo_logs` → `remap` (triple SHA-256) → `blackhole`
3. Attaches a bpftrace script that samples CPU usage at ~997 Hz and attributes each sample to a named Vector component
4. Prints a per-component CPU histogram every 5 seconds

## Quick start

### Native build (recommended for development)

Build Vector with the `component-probes` feature:

```bash
cargo build --release --features component-probes
```

Then run Vector, attach bpftrace, and observe per-component CPU:

```bash
# Terminal 1: start bpftrace (must start before Vector)
sudo bpftrace probe.bt

# Terminal 2: start Vector
./target/release/vector --config vector.yaml
```

### Docker (self-contained demo)

```bash
docker build -t vector-probes .
docker run --rm -it --privileged --pid=host vector-probes
```

> `--privileged --pid=host` is required for bpftrace to attach kernel/user probes.

### Expected output

```
[component] id=1 name=gen
[component] id=2 name=crunch
[component] id=3 name=devnull
[thread]    tid=1234 addr=0x...
[thread]    tid=1235 addr=0x...

@cpu[crunch]: 3847
@cpu[gen]: 612
@cpu[devnull]: 41
@cpu[(idle)]: 489
```

The `crunch` transform dominates because it's doing triple SHA-256 on every event — exactly what we'd expect.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build: compile Vector, then run it with bpftrace in a slim Debian image |
| `vector.yaml` | Pipeline config: demo_logs → remap (SHA-256 ×3) → blackhole |
| `probe.bt` | bpftrace script that hooks into Vector's probe points and samples CPU |
| `run.sh` | Entrypoint that starts bpftrace, waits for it to attach, then starts Vector |

## How the probes work

Vector's `component-probes` feature provides two `#[no_mangle]` functions that serve as stable uprobe targets:

- **`vector_register_component(id, name_ptr, name_len)`** — called once per component at startup. Maps a numeric ID to a human-readable name (e.g., `"crunch"`).
- **`vector_register_thread(tid, addr)`** — called once per worker thread. Provides a pointer to a thread-local `u32` that Vector updates atomically as execution moves between components.

The bpftrace script:
1. Hooks both registration functions to build lookup tables
2. Uses `profile:hz:997` to sample the running thread's current component ID via the registered pointer
3. Aggregates samples by component name and prints every 5 seconds

## Customizing

### Change the pipeline

Edit `vector.yaml` to use any source/transform/sink combination. The probes automatically cover all components — no bpftrace changes needed.

### Adjust sampling rate

In `probe.bt`, change `profile:hz:997` to a different frequency. 997 Hz is a good default (prime number avoids aliasing with periodic work).

### Adjust reporting interval

In `probe.bt`, change `interval:s:5` to your preferred interval.

## Requirements

- Docker
- `--privileged --pid=host` on `docker run`

## FAQ

**Q: Why does the build take so long?**
It's compiling Vector from source with only the features needed for this demo. The first build pulls and compiles ~400 crates. Subsequent builds use Docker's layer cache.

**Q: Can I use this with my own Vector config?**
Yes. Replace `vector.yaml` with your config, rebuild the image, and the probes will automatically track all components in your pipeline.

**Q: Does this work on macOS/Windows?**
The bpftrace probes require Linux. On macOS/Windows, Docker Desktop runs a Linux VM, so it works as long as you pass `--privileged --pid=host`. However, some Docker Desktop configurations may restrict eBPF access.

**Q: What's the overhead?**
The probes are essentially free when not attached. When bpftrace is sampling at 997 Hz, overhead is typically <1% CPU — the probe points are just atomic u32 reads, no syscalls or allocations.

**Q: Can I use DTrace/SystemTap instead of bpftrace?**
Yes. The `#[no_mangle]` functions are standard uprobe targets that any tracing framework can hook into. You'd need to write equivalent scripts for your tool of choice.
