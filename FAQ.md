# Component Probes Demo — FAQ

## Why does `str(arg1, arg2)` truncate component names?

**Short answer:** bpftrace's `str(ptr, len)` treats `len` as the *buffer size
including the null terminator*, so it copies at most `len - 1` bytes of content.
Rust strings are not null-terminated, so passing the exact byte length causes
the last character to be silently dropped (e.g. `"crunch"` → `"crunc"`).

**The fix:** null-terminate the string on the Rust side and use `str(arg1)`
(no length argument) in the bpftrace script. `str()` without a length reads
until the null terminator, which is the standard pattern for C strings in
uprobes.

### Detailed explanation

1. **Rust strings are not null-terminated.** `String::as_bytes()` returns the
   raw UTF-8 bytes without a trailing `\0`. When we pass `(ptr, len)` to the
   uprobe, `len` is the exact content length.

2. **bpftrace `str()` reserves one byte for null.** The
   [official documentation](https://github.com/bpftrace/bpftrace/blob/master/docs/stdlib.md)
   states:

   > `str` reads a NULL terminated (`\0`) string from `data`.
   >
   > In case the string is longer than the specified length only `length - 1`
   > bytes are copied and a NULL byte is appended at the end.

   So `str(ptr, 6)` for `"crunch"` copies 5 bytes + `\0` = `"crunc\0"`.

3. **The kernel helper confirms this.** `str()` compiles down to
   [`bpf_probe_read_user_str`](https://github.com/torvalds/linux/blob/master/kernel/trace/bpf_trace.c),
   which internally calls `strncpy_from_user_nofault()`. This function scans
   user memory for a null terminator; if none is found within the buffer size,
   the result is truncated.

4. **`buf()` exists specifically for non-null-terminated data.** bpftrace added
   `buf()` in v0.12.0
   ([PR #1107](https://github.com/bpftrace/bpftrace/pull/1107)) because `str()`
   requires null termination. `buf()` reads exact byte counts but returns a
   `buffer` type, not a string — it can't be used as a map key or in string
   operations.

### Why `str(arg1)` (no length) is safe and correct

When called without a length, `str()` reads from the pointer until it finds a
`\0` byte, up to `BPFTRACE_MAX_STRLEN` (128 bytes in bpftrace ≤0.19, 1024 in
≥0.20). Since we null-terminate the string on the Rust side, `str()` reads
exactly the right number of bytes and stops. This is the idiomatic pattern for
reading C strings in bpftrace uprobes.

---

## What version of bpftrace does the demo use?

Debian bookworm ships **bpftrace 0.17.0**
([Debian package listing](https://packages.debian.org/bookworm/bpftrace)),
released [2023-01-30](https://github.com/bpftrace/bpftrace/releases/tag/v0.17.0).

The `str()` length-parameter semantics (`length - 1` content bytes + null) have
been consistent since bpftrace v0.10+. Our fix (null-terminate + drop the length
arg) does not depend on any version-specific behavior — it works on all bpftrace
versions.

### Version timeline for reference

| Version | Date | Relevant changes |
|---------|------|-----------------|
| [v0.12.0](https://github.com/bpftrace/bpftrace/releases/tag/v0.12.0) | 2021-04-01 | Added `buf()` for non-null-terminated data ([PR #1107](https://github.com/bpftrace/bpftrace/pull/1107)) |
| [v0.17.0](https://github.com/bpftrace/bpftrace/releases/tag/v0.17.0) | 2023-01-30 | Shipped in Debian bookworm; added `%rh` hex format for `buf()` |
| [v0.18.0](https://github.com/bpftrace/bpftrace/releases/tag/v0.18.0) | 2023-05-15 | Truncation trailer (`..`) added to indicate `str()` was clipped ([PR #2559](https://github.com/bpftrace/bpftrace/pull/2559)) |
| [v0.25.0](https://github.com/bpftrace/bpftrace/releases/tag/v0.25.0) | 2025-03-13 | Fixed off-by-one in `str()` size parameter codegen ([PR #3849](https://github.com/bpftrace/bpftrace/pull/3849)) |

---

## Is there a known bug with `str()` and the length parameter?

Yes. [PR #3849](https://github.com/bpftrace/bpftrace/pull/3849) (merged
2025-02-28, released in v0.25.0) fixed an off-by-one error where the code
generator allocated an extra byte beyond the specified size for the null
terminator. This caused string operations like `strcontains()` to fail because
the null byte was placed outside the string's documented bounds.

**Before the fix** (all versions through v0.24.x): `str(ptr, N)` allocated N+1
bytes internally, putting the null at position N — outside the documented buffer
boundary. String comparisons could silently fail.

**After the fix** (v0.25.0+): `str(ptr, N)` correctly allocates N bytes total
(N-1 content + 1 null), matching the documented behavior.

**Our approach avoids this bug entirely** by not using the length parameter at
all. `str(arg1)` uses the default max-strlen buffer and reads until null — no
length math, no off-by-one risk.

---

## What does the Rust side change look like?

Before (non-null-terminated):
```rust
let id_bytes = component_id.as_bytes();
vector_register_component(probe_id, id_bytes.as_ptr(), id_bytes.len());
```

After (null-terminated via `CString`):
```rust
let c_name = std::ffi::CString::new(component_id)
    .expect("component_id should not contain null bytes");
let name_bytes = c_name.as_bytes_with_nul();
vector_register_component(probe_id, name_bytes.as_ptr(), name_bytes.len());
```

`CString` guarantees a null-terminated byte sequence. `as_bytes_with_nul()`
returns the bytes including the trailing `\0`, so `name_len` includes the null
terminator. The canonical bpftrace script uses `str(arg1)` (no length
argument), which reads until the null byte.

---

## What does the bpftrace script change look like?

Before:
```
uprobe:...:vector_register_component {
    @names[arg0] = str(arg1, arg2);
}
```

After:
```
uprobe:...:vector_register_component {
    @names[arg0] = str(arg1);
}
```

---

## Key references

| What | Link |
|------|------|
| `str()` documentation (requires null-terminated input) | [docs/stdlib.md — str](https://github.com/bpftrace/bpftrace/blob/master/docs/stdlib.md) |
| `buf()` added for non-null-terminated data | [PR #1107](https://github.com/bpftrace/bpftrace/pull/1107) |
| Truncation trailer feature (shows `str()` truncation is a known UX issue) | [Issue #2553](https://github.com/bpftrace/bpftrace/issues/2553), [PR #2559](https://github.com/bpftrace/bpftrace/pull/2559) |
| Off-by-one fix in `str()` size codegen | [PR #3849](https://github.com/bpftrace/bpftrace/pull/3849) |
| Kernel helper: `bpf_probe_read_user_str` implementation | [kernel/trace/bpf_trace.c](https://github.com/torvalds/linux/blob/master/kernel/trace/bpf_trace.c) (search for `bpf_probe_read_user_str_common`) |
| bpftrace `str()` codegen (calls `CreateProbeReadStr`) | [src/ast/passes/codegen_llvm.cpp](https://github.com/bpftrace/bpftrace/blob/master/src/ast/passes/codegen_llvm.cpp) |
| bpftrace `CreateProbeReadStr` (passes size directly to kernel) | [src/ast/irbuilderbpf.cpp](https://github.com/bpftrace/bpftrace/blob/master/src/ast/irbuilderbpf.cpp) |
| Debian bookworm ships bpftrace 0.17.0 | [packages.debian.org](https://packages.debian.org/bookworm/bpftrace) |
| bpf-helpers man page (`bpf_probe_read_str` docs) | [man7.org/bpf-helpers.7](https://man7.org/linux/man-pages/man7/bpf-helpers.7.html) |
