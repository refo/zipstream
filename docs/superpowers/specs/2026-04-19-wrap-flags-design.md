# Wrap / No-Wrap Flags Design

## Summary

Replace the implicit "auto-wrap on multiple top-level entries" behavior with an explicit opt-in / opt-out model. Stop wrapping when the user has provided an explicit output directory via `-o`. Improve wrapper name derivation.

## Motivation

Today `zipstream` always wraps multi-root archives into a generated folder named `zipstream-output`, even when the user supplied `-o <dir>`. That produces redundant layouts like `out/zipstream-output/...` and surprises users who already picked a target. The wrapper name itself is a hardcoded stub and carries no archive identity.

## Behavior

### Wrap mode

Three modes, controlled by two mutually exclusive flags:

- **auto** (default): wrap only when extracting to the current working directory AND the archive has multiple top-level entries
- **always**: wrap regardless of conditions; select `--wrap`
- **never**: never wrap; select `--no-wrap`

### Behavior matrix

| Condition | Default (auto) | `--wrap` | `--no-wrap` |
|---|---|---|---|
| cwd (`.`), single root | no wrap | wrap | no wrap |
| cwd (`.`), multi-root | auto-wrap | wrap | no wrap (entries dumped into cwd) |
| `-o <dir>`, single root | no wrap (into `dir/`) | wrap (into `dir/<name>/`) | no wrap |
| `-o <dir>`, multi-root | no wrap (into `dir/`) | wrap (into `dir/<name>/`) | no wrap |

Key change from current behavior: when `-o <dir>` is specified, the default no longer wraps. Users who want the old behavior pass `--wrap`.

### Flag conflict

Passing both `--wrap` and `--no-wrap` in the same invocation exits with code 1 and the message:

```
error: --wrap and --no-wrap are mutually exclusive
```

## Wrapper Name Resolution

When wrapping, resolve the wrapper directory name via this chain (first success wins):

1. **`Content-Disposition` filename**: if the HTTP response contains `Content-Disposition: attachment; filename="..."`, use that value with any `.zip` / `.ZIP` suffix stripped.
2. **URL path basename**: take the final path segment of the URL (ignoring query string and fragment), strip any `.zip` / `.ZIP` suffix. Use if non-empty.
3. **Timestamp fallback**: `zipstream-YYYYMMDD-HHMMSS` in UTC (portable; avoids a timezone-data dependency).

### Sanitization

After resolution, sanitize the chosen name:

- Replace path separators (`/`, `\`) and NUL with `-`
- Strip ASCII control characters (`< 0x20`, `0x7f`)
- Trim leading/trailing whitespace and dots
- If the result is empty after sanitization, fall through to the next tier
- Cap at 255 bytes (truncate to last full UTF-8 boundary if needed)

### Collision handling

If the resolved name already exists as an entry in the target directory, append `-1`, `-2`, ..., up to `-99`. If all 100 candidates collide, exit with `error: could not allocate wrapper directory name`.

## CLI Changes

### New flags

- `--wrap`: force wrapping into a generated directory
- `--no-wrap`: never wrap

### Help text

Update `printUsage()` in `src/main.zig` to include:

```
  --wrap                      Always wrap entries in a generated directory
  --no-wrap                   Never wrap entries (extract directly)
```

### README

Update the options table and add a short "Auto-wrapping" section documenting:

- The three modes and the default
- That `-o <dir>` no longer implies wrapping (behavior change)
- Wrapper name derivation order

## Implementation

### Touch points

- **`src/main.zig`**
  - Extend `Options` with `wrap_mode: WrapMode` where `WrapMode = enum { auto, always, never }`
  - Parse `--wrap` and `--no-wrap`; emit conflict error if both present
  - Capture and forward the `Content-Disposition` filename (if any) from `response.head` into `extract`
  - Forward the URL string into `extract` for basename derivation

- **`src/extract.zig`**
  - Update `extract()` signature to accept `wrap_mode`, `url`, and `content_disposition_filename: ?[]const u8`
  - Replace the stub `inferWrapperName()` with a resolver that implements the chain and sanitization
  - Branch the existing wrap trigger at the current `needs_wrapper = true` site:
    - `.always`: set `needs_wrapper = true` on the first entry (not on second-root detection)
    - `.never`: never set `needs_wrapper`
    - `.auto`: current logic, but gated on `output_dir_path == "."` (detection passes through the caller)
  - Add a sanitize helper and a collision-resolution helper

### Does not change

- Streaming extraction logic, CRC verification, path traversal protection, `--strip-components`, progress / JSON output formats, exit codes.

## Edge Cases

- **`--wrap` + cwd + single root**: wrap anyway — user was explicit
- **`--no-wrap` + cwd + multi-root**: extract entries directly into cwd; overwrite behavior matches current per-file write semantics
- **Derived name collides with existing directory**: append numeric suffix `-1`..`-99`; fail if exhausted
- **Empty archive**: no wrapping applied regardless of mode
- **`Content-Disposition` header with RFC 5987 encoded filename (`filename*=UTF-8''...`)**: out of scope; use only the plain `filename=` form

## Testing

### Unit tests

- Wrapper name resolution: each tier in isolation (Content-Disposition hit, URL basename hit, timestamp fallback)
- Sanitization: path separators, control chars, leading/trailing dots, empty result fall-through, oversize truncation
- Collision suffixing: `-1` through `-99`, exhaustion error

### Integration tests

Cover the full behavior matrix with fixture archives (single-root and multi-root):

- auto + cwd + single root → no wrap
- auto + cwd + multi-root → wrap, name from URL
- auto + `-o dir` + single root → no wrap, into `dir/`
- auto + `-o dir` + multi-root → no wrap, into `dir/` (behavior change vs current)
- `--wrap` + `-o dir` + single root → `dir/<name>/`
- `--wrap` + cwd + single root → wrap
- `--no-wrap` + cwd + multi-root → entries directly in cwd
- `--wrap --no-wrap` → exit 1

## Out of Scope

- Accepting a custom wrapper name via `--wrap=<name>` (would reintroduce tri-state parsing; deferred)
- RFC 5987 encoded `Content-Disposition` filenames
- Prompting the user interactively at runtime
