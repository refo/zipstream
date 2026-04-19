# Wrap / No-Wrap Flags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace implicit auto-wrap with explicit `--wrap` / `--no-wrap` flags; stop wrapping when `-o <dir>` is supplied; derive wrapper names from `Content-Disposition` or URL basename instead of a hardcoded stub.

**Architecture:** Add a `WrapMode { auto, always, never }` enum parsed from two CLI flags (mutually exclusive). Thread the mode plus the URL and response `Content-Disposition` header value into `extract()`. Inside `extract`, replace the stubbed `inferWrapperName` with a resolver chain (Content-Disposition → URL basename → timestamp) that sanitizes and collision-suffixes the chosen name. Branch the existing wrap-triggering site on the mode and on whether the output path is the current working directory.

**Tech Stack:** Zig 0.15.2, `std.http.Client`, `std.fs.Dir`, `std.Io.Reader`. Tests are inline Zig `test { ... }` blocks discovered through `src/main.zig`.

**Spec:** `docs/superpowers/specs/2026-04-19-wrap-flags-design.md`

## File Map

- **Modify** `src/main.zig` — parse new flags, read `Content-Disposition`, forward URL and header into `extract`
- **Modify** `src/extract.zig` — new `WrapMode` enum, resolver chain, sanitize + collision helpers, updated `extract()` signature, branching on wrap mode
- **Modify** `README.md` — options table + "Auto-wrapping" section describing new behavior

No new files. All unit tests go inline in `src/extract.zig` at the bottom of the file.

---

### Task 1: Add `WrapMode` enum and resolver stubs in `src/extract.zig`

**Files:**
- Modify: `src/extract.zig` (add near top of file, below existing `ExtractError`)

- [ ] **Step 1: Add the `WrapMode` enum and the new resolver function signatures**

In `src/extract.zig`, immediately after the `ExtractError` declaration (around line 22), add:

```zig
pub const WrapMode = enum { auto, always, never };

/// Maximum bytes for a derived wrapper directory name.
pub const max_wrapper_name_len: usize = 255;

/// Result of resolving a wrapper name. `len` is the number of valid bytes in `buf`.
pub const WrapperName = struct {
    buf: [max_wrapper_name_len]u8,
    len: usize,

    pub fn slice(self: *const WrapperName) []const u8 {
        return self.buf[0..self.len];
    }
};
```

- [ ] **Step 2: Replace the stub `inferWrapperName` with a resolver chain**

Delete the current `inferWrapperName` function (lines ~371–374). Add this in its place:

```zig
/// Resolve a wrapper directory name using the following chain:
/// 1. `content_disposition` filename (if provided), with `.zip`/`.ZIP` stripped
/// 2. URL path basename, with query/fragment removed and `.zip`/`.ZIP` stripped
/// 3. Timestamp fallback `zipstream-YYYYMMDD-HHMMSS`
///
/// Each candidate is sanitized; if the sanitized result is empty the resolver
/// falls through to the next tier.
pub fn resolveWrapperName(
    url: []const u8,
    content_disposition: ?[]const u8,
    now_unix_seconds: i64,
) WrapperName {
    var out: WrapperName = .{ .buf = undefined, .len = 0 };

    if (content_disposition) |cd| {
        const raw = extractCdFilename(cd);
        if (raw.len > 0) {
            const trimmed = stripZipSuffix(raw);
            if (sanitizeWrapperName(trimmed, &out.buf)) |n| {
                out.len = n;
                return out;
            }
        }
    }

    const url_base = urlBasename(url);
    if (url_base.len > 0) {
        const trimmed = stripZipSuffix(url_base);
        if (sanitizeWrapperName(trimmed, &out.buf)) |n| {
            out.len = n;
            return out;
        }
    }

    // Timestamp fallback: zipstream-YYYYMMDD-HHMMSS in UTC (portable; no
    // dependency on local timezone data).
    const ts = std.fmt.bufPrint(&out.buf, "zipstream-{s}", .{formatTimestamp(now_unix_seconds)}) catch {
        const literal = "zipstream-output";
        @memcpy(out.buf[0..literal.len], literal);
        out.len = literal.len;
        return out;
    };
    out.len = ts.len;
    return out;
}
```

- [ ] **Step 3: Commit**

```bash
git add src/extract.zig
git commit -m "feat(extract): add WrapMode enum and resolveWrapperName skeleton"
```

Expected: compile will fail because `extractCdFilename`, `stripZipSuffix`, `urlBasename`, `sanitizeWrapperName`, and `formatTimestamp` don't exist yet. That's fine — commit anyway so the skeleton is isolated. The next tasks fill them in.

If you prefer a clean build at this point, stash Step 2 until after Task 2 and Task 3. Either order is acceptable.

---

### Task 2: Implement `stripZipSuffix`, `urlBasename`, `extractCdFilename` with tests

**Files:**
- Modify: `src/extract.zig` (add helpers near bottom, next to other helpers like `getFirstComponent`)

- [ ] **Step 1: Write failing tests at the bottom of `src/extract.zig`**

Append to `src/extract.zig` (if no `test` blocks exist yet, this is the first):

```zig
test "stripZipSuffix removes .zip case-insensitively" {
    try std.testing.expectEqualStrings("data", stripZipSuffix("data.zip"));
    try std.testing.expectEqualStrings("data", stripZipSuffix("data.ZIP"));
    try std.testing.expectEqualStrings("data.tar", stripZipSuffix("data.tar"));
    try std.testing.expectEqualStrings("", stripZipSuffix(".zip"));
    try std.testing.expectEqualStrings("", stripZipSuffix(""));
}

test "urlBasename returns final path segment without query or fragment" {
    try std.testing.expectEqualStrings("data.zip", urlBasename("https://example.com/data.zip"));
    try std.testing.expectEqualStrings("29796857.zip", urlBasename("https://s66.put.io/zipstream/29796857.zip?oauth_token=ABC"));
    try std.testing.expectEqualStrings("filename.zip", urlBasename("https://site.com/path/to/filename.zip?a=b&c=d"));
    try std.testing.expectEqualStrings("file.zip", urlBasename("https://example.com/file.zip#section"));
    try std.testing.expectEqualStrings("", urlBasename("https://example.com/"));
    try std.testing.expectEqualStrings("", urlBasename(""));
    try std.testing.expectEqualStrings("bare", urlBasename("bare"));
}

test "extractCdFilename parses RFC 6266 filename= form" {
    try std.testing.expectEqualStrings("movie.zip", extractCdFilename("attachment; filename=\"movie.zip\""));
    try std.testing.expectEqualStrings("movie.zip", extractCdFilename("attachment; filename=movie.zip"));
    try std.testing.expectEqualStrings("a b.zip", extractCdFilename("attachment; filename=\"a b.zip\""));
    try std.testing.expectEqualStrings("", extractCdFilename("inline"));
    try std.testing.expectEqualStrings("", extractCdFilename("attachment; filename*=UTF-8''movie.zip"));
    try std.testing.expectEqualStrings("", extractCdFilename(""));
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zig build test
```

Expected: compile errors — functions not defined. (If Task 1 Step 2 added forward references, the same compile failure covers those too.)

- [ ] **Step 3: Implement the helpers**

Append to `src/extract.zig` above the `test` blocks, next to the other file-local helpers:

```zig
fn stripZipSuffix(name: []const u8) []const u8 {
    if (name.len < 4) return name;
    const tail = name[name.len - 4 ..];
    if (std.ascii.eqlIgnoreCase(tail, ".zip")) {
        return name[0 .. name.len - 4];
    }
    return name;
}

fn urlBasename(url: []const u8) []const u8 {
    // Strip fragment then query.
    var s = url;
    if (std.mem.indexOfScalar(u8, s, '#')) |i| s = s[0..i];
    if (std.mem.indexOfScalar(u8, s, '?')) |i| s = s[0..i];
    // Trim scheme for clarity; find last '/'.
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| {
        return s[i + 1 ..];
    }
    return s;
}

/// Very small RFC 6266 parser. Handles `filename=value` and `filename="value"`.
/// Ignores RFC 5987 `filename*=` forms (returns empty).
fn extractCdFilename(header: []const u8) []const u8 {
    const needle = "filename=";
    const idx = std.ascii.indexOfIgnoreCase(header, needle) orelse return "";
    // Reject the `filename*=` variant.
    if (idx > 0 and header[idx - 1] == '*') return "";
    var rest = header[idx + needle.len ..];
    if (rest.len == 0) return "";
    if (rest[0] == '"') {
        rest = rest[1..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
        return rest[0..end];
    }
    // Unquoted: terminate at `;` or whitespace.
    const end = std.mem.indexOfAny(u8, rest, "; \t") orelse rest.len;
    return rest[0..end];
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
zig build test
```

Expected: the three tests above pass. Other tests (sanitize, resolver) still fail — that's fine, they're next.

- [ ] **Step 5: Commit**

```bash
git add src/extract.zig
git commit -m "feat(extract): add stripZipSuffix, urlBasename, extractCdFilename helpers"
```

---

### Task 3: Implement `sanitizeWrapperName` with tests

**Files:**
- Modify: `src/extract.zig`

- [ ] **Step 1: Write failing tests**

Append to the test section at the bottom of `src/extract.zig`:

```zig
test "sanitizeWrapperName replaces separators and strips control chars" {
    var buf: [max_wrapper_name_len]u8 = undefined;

    const n1 = sanitizeWrapperName("hello/world", &buf).?;
    try std.testing.expectEqualStrings("hello-world", buf[0..n1]);

    const n2 = sanitizeWrapperName("a\\b", &buf).?;
    try std.testing.expectEqualStrings("a-b", buf[0..n2]);

    const n3 = sanitizeWrapperName("x\x01y\x7fz", &buf).?;
    try std.testing.expectEqualStrings("xyz", buf[0..n3]);

    const n4 = sanitizeWrapperName("  .name.  ", &buf).?;
    try std.testing.expectEqualStrings("name", buf[0..n4]);

    try std.testing.expect(sanitizeWrapperName("", &buf) == null);
    try std.testing.expect(sanitizeWrapperName("   ", &buf) == null);
    try std.testing.expect(sanitizeWrapperName("....", &buf) == null);
}

test "sanitizeWrapperName truncates to max_wrapper_name_len bytes" {
    var buf: [max_wrapper_name_len]u8 = undefined;
    var input: [512]u8 = undefined;
    @memset(&input, 'a');
    const n = sanitizeWrapperName(&input, &buf).?;
    try std.testing.expectEqual(max_wrapper_name_len, n);
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zig build test
```

Expected: compile error — `sanitizeWrapperName` not defined.

- [ ] **Step 3: Implement `sanitizeWrapperName`**

Append to `src/extract.zig` above the test blocks:

```zig
/// Sanitize a candidate wrapper name into `out`. Returns the byte length
/// written, or null if the sanitized result is empty.
///
/// - `/`, `\`, NUL become `-`
/// - Bytes below 0x20 and 0x7f are dropped
/// - Leading/trailing whitespace and `.` are trimmed
/// - Result is capped at `max_wrapper_name_len` bytes
fn sanitizeWrapperName(name: []const u8, out: []u8) ?usize {
    var written: usize = 0;
    for (name) |c| {
        if (written == out.len) break;
        const mapped: ?u8 = switch (c) {
            '/', '\\', 0 => '-',
            0x01...0x1f, 0x7f => null,
            else => c,
        };
        if (mapped) |m| {
            out[written] = m;
            written += 1;
        }
    }

    // Trim trailing whitespace and dots.
    while (written > 0) {
        const c = out[written - 1];
        if (c == ' ' or c == '\t' or c == '.') written -= 1 else break;
    }

    // Trim leading whitespace and dots by shifting.
    var start: usize = 0;
    while (start < written) {
        const c = out[start];
        if (c == ' ' or c == '\t' or c == '.') start += 1 else break;
    }
    if (start > 0 and start < written) {
        const len = written - start;
        std.mem.copyForwards(u8, out[0..len], out[start..written]);
        written = len;
    } else if (start >= written) {
        written = 0;
    }

    if (written == 0) return null;
    return written;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
zig build test
```

Expected: the two sanitize tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/extract.zig
git commit -m "feat(extract): add sanitizeWrapperName helper"
```

---

### Task 4: Implement `formatTimestamp` and wire `resolveWrapperName` together with tests

**Files:**
- Modify: `src/extract.zig`

- [ ] **Step 1: Write failing tests**

Append to the test block area:

```zig
test "formatTimestamp produces YYYYMMDD-HHMMSS" {
    // 2026-04-19 14:30:22 UTC => unix seconds 1776789022
    const s = formatTimestamp(1776789022);
    try std.testing.expectEqualStrings("20260419-143022", s);
}

test "resolveWrapperName prefers Content-Disposition over URL" {
    const r = resolveWrapperName(
        "https://s66.put.io/zipstream/29796857.zip?oauth_token=ABC",
        "attachment; filename=\"Movie.Title.2024.zip\"",
        0,
    );
    try std.testing.expectEqualStrings("Movie.Title.2024", r.slice());
}

test "resolveWrapperName falls back to URL basename" {
    const r = resolveWrapperName(
        "https://example.com/path/cool-data.zip?x=1",
        null,
        0,
    );
    try std.testing.expectEqualStrings("cool-data", r.slice());
}

test "resolveWrapperName uses numeric URL basename when that is all we have" {
    const r = resolveWrapperName(
        "https://s66.put.io/zipstream/29796857.zip?oauth_token=ABC",
        null,
        0,
    );
    try std.testing.expectEqualStrings("29796857", r.slice());
}

test "resolveWrapperName falls back to timestamp when URL is useless" {
    const r = resolveWrapperName("https://example.com/", null, 1776789022);
    try std.testing.expectEqualStrings("zipstream-20260419-143022", r.slice());
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zig build test
```

Expected: compile error — `formatTimestamp` not defined.

- [ ] **Step 3: Implement `formatTimestamp`**

Append to `src/extract.zig` above the test blocks:

```zig
/// Format a UTC timestamp (`seconds` since unix epoch) as `YYYYMMDD-HHMMSS`.
/// Returns a static buffer; caller must consume immediately.
fn formatTimestamp(seconds: i64) []const u8 {
    const S = struct {
        threadlocal var buf: [16]u8 = undefined;
    };
    const ep_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const day_secs = ep_secs.getDaySeconds();
    const ep_day = ep_secs.getEpochDay();
    const year_day = ep_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const out = std.fmt.bufPrint(&S.buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        @as(u32, year_day.year),
        @as(u32, month_day.month.numeric()),
        @as(u32, month_day.day_index + 1),
        @as(u32, day_secs.getHoursIntoDay()),
        @as(u32, day_secs.getMinutesIntoHour()),
        @as(u32, day_secs.getSecondsIntoMinute()),
    }) catch return "";
    return out;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
zig build test
```

Expected: all resolver tests pass. Fix any stdlib signature mismatches by consulting `std.time.epoch` — field/function names may differ slightly by Zig 0.15.2 (e.g. `getHoursIntoDay` vs `hours`). If names differ, adjust to match the installed stdlib and keep the output format identical.

- [ ] **Step 5: Commit**

```bash
git add src/extract.zig
git commit -m "feat(extract): wire resolveWrapperName chain with timestamp fallback"
```

---

### Task 5: Add wrap-mode plumbing and collision resolver, update `extract()` signature

**Files:**
- Modify: `src/extract.zig` (signature, wrap-branching site, new collision helper)
- Modify: `src/main.zig` (call site — just pass defaults for now; real flag parsing is Task 6)

- [ ] **Step 1: Write failing tests for the collision resolver**

Append to the test blocks:

```zig
test "allocateWrapperDir appends -1, -2 when directory exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pre-create "data" and "data-1".
    try tmp.dir.makeDir("data");
    try tmp.dir.makeDir("data-1");

    var name_buf: [max_wrapper_name_len + 4]u8 = undefined;
    const final = try allocateWrapperDir(tmp.dir, "data", &name_buf);
    try std.testing.expectEqualStrings("data-2", final);

    // Verify the directory was created.
    var opened = try tmp.dir.openDir("data-2", .{});
    opened.close();
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zig build test
```

Expected: compile error — `allocateWrapperDir` not defined.

- [ ] **Step 3: Implement `allocateWrapperDir`**

Append to `src/extract.zig` above the test blocks:

```zig
pub const WrapperAllocError = error{
    IoError,
    NameTooLong,
    TooManyCollisions,
};

/// Create a wrapper directory under `parent` using `base` as the preferred name.
/// On collision, append `-1`, `-2`, ..., up to `-99`. Returns a slice of
/// `out_buf` holding the final name.
fn allocateWrapperDir(
    parent: std.fs.Dir,
    base: []const u8,
    out_buf: []u8,
) WrapperAllocError![]const u8 {
    if (base.len > out_buf.len) return error.NameTooLong;

    // Try `base` first.
    @memcpy(out_buf[0..base.len], base);
    if (tryMakeDir(parent, out_buf[0..base.len])) |_| {
        return out_buf[0..base.len];
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.IoError,
    }

    var i: u32 = 1;
    while (i <= 99) : (i += 1) {
        const candidate = std.fmt.bufPrint(out_buf, "{s}-{d}", .{ base, i }) catch return error.NameTooLong;
        if (tryMakeDir(parent, candidate)) |_| {
            return candidate;
        } else |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return error.IoError,
        }
    }
    return error.TooManyCollisions;
}

fn tryMakeDir(parent: std.fs.Dir, name: []const u8) std.fs.Dir.MakeError!void {
    try parent.makeDir(name);
}
```

- [ ] **Step 4: Run tests to verify the collision test passes**

```bash
zig build test
```

Expected: `allocateWrapperDir appends -1, -2 when directory exists` passes.

- [ ] **Step 5: Enlarge `wrapper_name_buf` and update `extract()` signature**

In `src/extract.zig`, change `var wrapper_name_buf: [256]u8 = undefined;` to `var wrapper_name_buf: [260]u8 = undefined;` so it can hold a 255-byte base name plus a `-99` suffix.

Then change the signature of `extract` (around line 24):

```zig
pub fn extract(
    body_reader: *Reader,
    output_dir_path: []const u8,
    strip_components: u32,
    content_length: ?u64,
    progress_mode: Progress.Mode,
    wrap_mode: WrapMode,
    url: []const u8,
    content_disposition: ?[]const u8,
) ExtractError!void {
```

And in the recursive call inside `extract` (around line 38), forward the new arguments:

```zig
return extract(body_reader, output_dir_path, strip_components, content_length, progress_mode, wrap_mode, url, content_disposition);
```

- [ ] **Step 6: Replace the wrap-triggering block with mode-aware logic**

Inside `extract`, replace the entire block that currently starts with `// Top-level folder detection (only when strip_components == 0)` down through the end of the wrap-setup `}` (roughly lines 115–153) with:

```zig
        // Wrap-mode bookkeeping (only meaningful when strip_components == 0).
        if (strip_components == 0) {
            const root = getFirstComponent(entry.filename);
            if (first_root == null) {
                if (root.len <= 256) {
                    var buf: [256]u8 = undefined;
                    @memcpy(buf[0..root.len], root);
                    first_root = buf;
                    first_root_len = root.len;
                }

                // For `.always` mode we wrap immediately on the first entry.
                if (wrap_mode == .always and !needs_wrapper) {
                    if (initWrapper(output_dir, url, content_disposition, &wrapper_name_buf, &wrapper_name_len)) {
                        needs_wrapper = true;
                        // Note: the first entry has not been extracted yet at
                        // this point, so no rename is required here.
                    }
                }
            } else if (!needs_wrapper) {
                const fr = first_root.?;
                const differs = !std.mem.eql(u8, fr[0..first_root_len], root);
                const should_auto_wrap =
                    wrap_mode == .auto and std.mem.eql(u8, output_dir_path, ".") and differs;
                if (should_auto_wrap) {
                    if (initWrapper(output_dir, url, content_disposition, &wrapper_name_buf, &wrapper_name_len)) {
                        needs_wrapper = true;
                        // Move previously extracted first_root into wrapper.
                        const first = fr[0..first_root_len];
                        var src_buf: [512]u8 = undefined;
                        var dst_buf: [512]u8 = undefined;
                        const src_path = std.fmt.bufPrint(&src_buf, "{s}", .{first}) catch first;
                        const wrapper = wrapper_name_buf[0..wrapper_name_len];
                        const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ wrapper, first }) catch {
                            continue;
                        };
                        output_dir.rename(src_path, dst_path) catch {
                            needs_wrapper = false;
                        };
                    }
                }
            }
        }
```

Then add this helper below the other helpers in `src/extract.zig`:

```zig
/// Resolve a wrapper name, create the directory (with collision suffixing),
/// and copy the final name into `name_buf`. Returns true on success.
fn initWrapper(
    output_dir: std.fs.Dir,
    url: []const u8,
    content_disposition: ?[]const u8,
    name_buf: *[260]u8,
    name_len: *usize,
) bool {
    const resolved = resolveWrapperName(url, content_disposition, std.time.timestamp());
    var alloc_buf: [max_wrapper_name_len + 4]u8 = undefined;
    const final = allocateWrapperDir(output_dir, resolved.slice(), &alloc_buf) catch return false;
    if (final.len > name_buf.len) return false;
    @memcpy(name_buf[0..final.len], final);
    name_len.* = final.len;
    return true;
}
```

- [ ] **Step 7: Update the call site in `src/main.zig`**

In `src/main.zig`, modify the `extract_mod.extract` call inside `run()` to pass defaults (flag parsing comes in Task 6). First, capture the `Content-Disposition` header and URL. Around where `response.head.content_length` is read (~line 78), add:

```zig
    const content_disposition_raw: ?[]const u8 = blk: {
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-disposition")) break :blk h.value;
        }
        break :blk null;
    };
```

Then update the `extract_mod.extract(...)` call to:

```zig
    extract_mod.extract(
        body_reader,
        options.output_dir,
        options.strip_components,
        content_length,
        progress_mode,
        options.wrap_mode,
        options.url,
        content_disposition_raw,
    ) catch |err| {
        return err;
    };
```

Add `wrap_mode: extract_mod.WrapMode` to the `Options` struct at the top of `src/main.zig`:

```zig
const Options = struct {
    url: []const u8,
    output_dir: []const u8,
    strip_components: u32,
    json: bool,
    wrap_mode: extract_mod.WrapMode,
};
```

And in `parseArgs`, default to `.auto` for now (real parsing in Task 6):

```zig
    return Options{
        .url = url.?,
        .output_dir = output_dir,
        .strip_components = strip_components,
        .json = json,
        .wrap_mode = .auto,
    };
```

If `std.http` in Zig 0.15.2 exposes header iteration under a different name (e.g. `iterator()` or `header_iterator()`), adjust the header-scan loop accordingly. The only requirement is to end up with a `?[]const u8` for the `Content-Disposition` value.

- [ ] **Step 8: Build and run all tests**

```bash
zig build test
zig build
```

Expected: builds cleanly. Existing behavior is preserved because `wrap_mode` defaults to `.auto` and the auto branch still wraps on cwd + multi-root.

- [ ] **Step 9: Commit**

```bash
git add src/extract.zig src/main.zig
git commit -m "feat(extract): thread wrap-mode, URL, and Content-Disposition into extract()"
```

---

### Task 6: Parse `--wrap` and `--no-wrap` flags with conflict detection

**Files:**
- Modify: `src/main.zig` (`parseArgs`, `printUsage`)

- [ ] **Step 1: Update `parseArgs` to recognize the new flags**

Inside the `while (args.next()) |arg|` loop in `src/main.zig`, add two new branches. Place them after the `--json` branch and before the `-o`/`--output` branch. Also add local `bool` tracking vars.

Near the top of `parseArgs`, alongside the other locals:

```zig
    var wrap_flag = false;
    var no_wrap_flag = false;
```

Inside the parse loop:

```zig
        } else if (std.mem.eql(u8, arg, "--wrap")) {
            wrap_flag = true;
        } else if (std.mem.eql(u8, arg, "--no-wrap")) {
            no_wrap_flag = true;
```

After the loop, before returning `Options`, add conflict detection and mode resolution:

```zig
    if (wrap_flag and no_wrap_flag) {
        fatal("--wrap and --no-wrap are mutually exclusive", .{});
    }

    const wrap_mode: extract_mod.WrapMode =
        if (wrap_flag) .always else if (no_wrap_flag) .never else .auto;
```

Replace the `.wrap_mode = .auto` line in the returned `Options` with `.wrap_mode = wrap_mode`.

- [ ] **Step 2: Update `printUsage`**

Replace the options section of the usage string with:

```
        \\Options:
        \\  -o, --output <dir>          Extract to directory (default: .)
        \\  --strip-components <n>      Strip N leading path components
        \\  --wrap                      Always wrap entries in a generated directory
        \\  --no-wrap                   Never wrap entries (extract directly)
        \\  --json                      Output progress as NDJSON to stderr
        \\  -h, --help                  Show this help
```

- [ ] **Step 3: Build and smoke-test**

```bash
zig build
./zig-out/bin/zipstream --wrap --no-wrap https://example.com/x.zip
```

Expected: exits with code 1 and prints `error: --wrap and --no-wrap are mutually exclusive`.

```bash
./zig-out/bin/zipstream --help
```

Expected: help output lists the two new flags.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat(cli): add --wrap / --no-wrap flags with mutual-exclusion check"
```

---

### Task 7: Manual end-to-end verification against a real archive

**Files:** none (verification only; produces artifacts in `/tmp/zipstream-verify/`)

- [ ] **Step 1: Prepare two fixture archives with `zip`**

```bash
mkdir -p /tmp/zs-fixtures && cd /tmp/zs-fixtures

# Single-root archive
mkdir single-root && echo hello > single-root/a.txt && zip -r single.zip single-root >/dev/null

# Multi-root archive
mkdir -p multi/a multi/b && echo 1 > multi/a/x.txt && echo 2 > multi/b/y.txt
(cd multi && zip -r ../multi.zip a b >/dev/null)
```

Serve them over HTTP so zipstream can fetch them:

```bash
python3 -m http.server 8765 --directory /tmp/zs-fixtures &
SERVER_PID=$!
```

Expected: server logs `Serving HTTP on ... port 8765`.

- [ ] **Step 2: Verify auto + cwd + multi-root wraps using URL basename**

```bash
mkdir -p /tmp/zs-verify/a && cd /tmp/zs-verify/a
/path/to/zig-out/bin/zipstream http://localhost:8765/multi.zip
ls
```

Expected: the directory contains a single folder named `multi/` containing `a/` and `b/`.

- [ ] **Step 3: Verify auto + `-o dir` + multi-root does NOT wrap**

```bash
rm -rf /tmp/zs-verify/b && mkdir -p /tmp/zs-verify/b
/path/to/zig-out/bin/zipstream http://localhost:8765/multi.zip -o /tmp/zs-verify/b
ls /tmp/zs-verify/b
```

Expected: `/tmp/zs-verify/b` contains `a/` and `b/` directly (no wrapper).

- [ ] **Step 4: Verify `--wrap` forces wrap even with `-o`**

```bash
rm -rf /tmp/zs-verify/c && mkdir -p /tmp/zs-verify/c
/path/to/zig-out/bin/zipstream http://localhost:8765/single.zip -o /tmp/zs-verify/c --wrap
ls /tmp/zs-verify/c
```

Expected: `/tmp/zs-verify/c` contains a single folder named `single/` (the URL basename with `.zip` stripped) which itself contains `single-root/a.txt`.

- [ ] **Step 5: Verify `--no-wrap` disables auto-wrap in cwd**

```bash
rm -rf /tmp/zs-verify/d && mkdir -p /tmp/zs-verify/d && cd /tmp/zs-verify/d
/path/to/zig-out/bin/zipstream http://localhost:8765/multi.zip --no-wrap
ls
```

Expected: the directory contains `a/` and `b/` directly.

- [ ] **Step 6: Clean up**

```bash
kill $SERVER_PID
rm -rf /tmp/zs-fixtures /tmp/zs-verify
```

- [ ] **Step 7: Commit nothing; report results**

No code changes in this task. Report pass/fail for each scenario in the PR description.

---

### Task 8: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the options table (lines 68–73)**

Replace the existing table with:

```markdown
| Flag | Description |
|------|-------------|
| `-o, --output <dir>` | Extract to directory (default: `.`) |
| `--strip-components <n>` | Strip N leading path components |
| `--wrap` | Always wrap entries in a generated directory |
| `--no-wrap` | Never wrap entries (extract directly) |
| `--json` | Output progress as NDJSON to stderr |
| `-h, --help` | Show help |
```

- [ ] **Step 2: Replace the bullet `Auto-wrapping — creates a containing folder when the archive has multiple top-level entries` (line 12) with**

```markdown
- **Smart wrapping** — when extracting to the current directory, archives with multiple top-level entries are wrapped in a folder named after the archive. Disable with `--no-wrap`; force with `--wrap`. Supplying `-o <dir>` never auto-wraps.
```

- [ ] **Step 3: Add an "Auto-wrapping" section immediately before "Exit codes"**

```markdown
### Auto-wrapping

By default, `zipstream` wraps extracted entries in a containing directory only when **both**:

1. you are extracting into the current working directory (no `-o` flag), and
2. the archive has multiple top-level entries.

Pass `--wrap` to always wrap, or `--no-wrap` to never wrap. `--wrap` and `--no-wrap` are mutually exclusive.

The wrapper directory name is derived in this order:

1. The `filename=` field of the `Content-Disposition` response header (if present), with `.zip` stripped
2. The last path segment of the URL, with query string and `.zip` stripped
3. `zipstream-YYYYMMDD-HHMMSS` (UTC)

If the chosen name collides with an existing directory, a numeric suffix (`-1`, `-2`, ...) is appended.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document --wrap / --no-wrap flags and wrapper name derivation"
```

---

## Verification Summary

After all tasks:

```bash
zig build test   # all inline tests pass
zig build        # clean build
```

Manual Task 7 scenarios all pass. README accurately reflects the shipped behavior.
