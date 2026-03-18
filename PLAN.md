# Zipstream — Streaming ZIP Extractor CLI Tool (Zig 0.15.2)

## Context

Build a CLI tool that downloads a ZIP file from a URL and extracts it **on the fly** — streaming decompression, not download-then-extract. The core challenge is that ZIP's central directory is at EOF, but we need to extract from a forward-only HTTP stream. We solve this by parsing local file headers sequentially.

---

## 1. Architecture Overview

### Data Flow

```
std.http.Client GET request
        │
        ▼
  *std.Io.Reader  (streaming HTTP body — chunked/content-length transparent)
        │
        ▼
  LocalHeaderParser  (reads PK\x03\x04 + header fields sequentially)
        │
        ├── filename, compression method, sizes, flags
        │
        ▼
  Per-entry pipeline:
    LimitedReader(compressed_size)  ──►  Decompressor  ──►  CRC32 check  ──►  File writer
        │
        ▼
  TopLevelFolder logic (deferred — rename on second distinct root)
        │
        ▼
  Progress output to stderr
```

### Project Structure

```
zipstream/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig            # CLI entry, HTTP setup, orchestration
    ├── ZipStream.zig       # Streaming ZIP local-header parser + entry iterator
    ├── extract.zig         # Extraction logic, top-level folder, path safety
    └── progress.zig        # Progress display to stderr
```

Keeping it to 4 source files. CRC32 check is inlined (just `std.hash.crc.Crc32IsoHdlc`). Decompressor dispatch is part of `ZipStream.zig` since `std.zip.Decompress` already provides store+deflate unification.

---

## 2. Module Design

### `main.zig` — Entry Point & HTTP Client

**Responsibilities**: CLI arg parsing, HTTP request, wire reader into extraction pipeline, top-level error formatting.

**Key types**:
```zig
const Options = struct {
    url: []const u8,
    output_dir: []const u8 = ".",
    strip_components: u32 = 0,
};
```

**HTTP flow** (Zig 0.15.2 API):
```zig
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

const uri = std.Uri.parse(url) catch |e| fatal("invalid URL: {}", .{e});
var req = try client.request(.GET, uri, .{
    .headers = .{ .accept_encoding = .none },  // we do NOT want HTTP-level compression
});
defer req.deinit();
try req.sendBodiless();

var redirect_buf: [4096]u8 = undefined;
var response = try req.receiveHead(&redirect_buf);

if (response.head.status != .ok) fatal("HTTP {d}: {s}", .{@intFromEnum(response.head.status), response.head.reason});

const content_length = response.head.content_length;  // ?u64, for progress

var transfer_buf: [16384]u8 = undefined;
const body_reader: *std.Io.Reader = response.reader(&transfer_buf);
```

**Critical**: Set `accept_encoding = .none` to prevent the HTTP client from requesting gzip/deflate content encoding — we need the raw ZIP bytes, not HTTP-decompressed content.

**Arg parsing**: Manual iteration over `std.process.args()`. No library needed for 3 flags.

### `ZipStream.zig` — Streaming ZIP Parser

**Responsibilities**: Read local file headers from a forward-only `*std.Io.Reader`, yield entries, provide per-entry decompressed reader.

**Key approach**: Reuse `std.zip.LocalFileHeader` (extern struct, correct binary layout) for reading the fixed header portion. Reuse `std.zip.Decompress` for store/deflate decompression. Reimplement `GeneralPurposeFlags` to access bit 3 (data descriptor flag — the std version hides it behind `_: u15`).

**Public API**:
```zig
pub const ZipStream = struct {
    reader: *Reader,           // the HTTP body reader
    buf: [buf_size]u8,         // working buffer
    done: bool,

    pub const Entry = struct {
        filename: []const u8,
        compression_method: std.zip.CompressionMethod,
        compressed_size: u64,
        uncompressed_size: u64,
        expected_crc32: u32,
        has_data_descriptor: bool,
        is_dir: bool,
    };

    pub fn init(reader: *Reader) ZipStream { ... }

    /// Returns next entry, or null when central directory / end record reached.
    pub fn next(self: *ZipStream) !?Entry { ... }

    /// Returns a reader for the current entry's decompressed content.
    /// Caller must fully consume this reader before calling next() again.
    pub fn entryReader(self: *ZipStream, entry: *const Entry) !EntryReader { ... }

    /// After consuming entry data, finalize: read data descriptor if needed, verify CRC32.
    pub fn finishEntry(self: *ZipStream, entry: *const Entry, actual_crc: u32) !void { ... }
};
```

**How `next()` works**:
1. Read 4 bytes. If `PK\x03\x04` → local file header, continue. If `PK\x01\x02` or `PK\x05\x06` → return `null` (reached central directory, done).
2. Read remaining `@sizeOf(LocalFileHeader) - 4` bytes.
3. Read `filename_len` bytes into buffer.
4. Parse extra field: scan for zip64 extra header (id `0x0001`) to get 64-bit sizes if 32-bit fields are `0xFFFFFFFF`.
5. Skip remaining extra data.
6. Check bit 3 of flags for `has_data_descriptor`.
7. Return `Entry`.

**Decompression**: Use `std.zip.Decompress.init(limited_reader, method, &decompress_buffer)` which returns an `std.Io.Reader` supporting both store and deflate. This is the exact same approach `std.zip` uses internally.

**LimitedReader**: Use `std.Io.Reader.Limited` to wrap the body reader with the entry's `compressed_size`, so the decompressor only reads that entry's bytes.

**Data descriptor handling**: After consuming all decompressed bytes, if `has_data_descriptor` is set, read 12 or 16 bytes (check for optional `PK\x07\x08` signature prefix). Use descriptor's CRC32 for validation if the header's CRC was 0.

### `extract.zig` — Extraction Orchestrator

**Responsibilities**: Drive iteration, create files/dirs, handle top-level folder logic, strip components, path safety.

**Path safety** (reimplements `std.zip.isBadFilename` logic since it's not `pub`):
- Reject empty names, names starting with `/`
- Reject any component equal to `..`
- Normalize backslashes to forward slashes (or reject)
- Skip symlink entries (warn to stderr)

**Top-level folder detection — "lazy rename" strategy**:
1. Track `first_root: ?[]const u8` — the first top-level path component seen.
2. Track `needs_wrapper: bool` — initially `false`.
3. For each entry, extract top-level component. If it matches `first_root`, extract normally. If different:
   - Set `needs_wrapper = true`
   - Create wrapper dir (derived from URL basename minus `.zip`)
   - Move `first_root` directory into wrapper dir via `std.fs.Dir.rename`
   - Continue extracting into wrapper dir
4. If only one root was ever seen, no wrapper needed — extraction is already correct.

**`--strip-components <n>`**: Before writing, split path on `/`, skip first `n` components. If fewer than `n+1` components (for files), skip the entry entirely.

**File writing flow** per entry:
```
1. Sanitize + strip path
2. Create parent directories (Dir.makePath)
3. If entry is directory → just create it, continue
4. Open output file for writing
5. Read from entryReader → compute CRC32 → write to file
6. Close file
7. Call finishEntry to verify CRC and consume data descriptor
```

CRC32 computed using `std.hash.crc.Crc32IsoHdlc` — update incrementally as chunks are written.

### `progress.zig` — Progress Display

**Responsibilities**: Print status to stderr.

- If stderr is a TTY (`std.posix.isatty`): use `\r` for in-place updates showing current filename and bytes downloaded.
- If not a TTY: print one line per extracted file.
- If `Content-Length` is known: show percentage of total bytes downloaded.
- Final summary: `Extracted N files to <dir>`.

---

## 3. Streaming Strategy — ZIP Central Directory Problem

**Approach**: Parse local file headers only, ignore central directory entirely.

Local file headers appear immediately before each file's data in the ZIP byte stream:
```
[LFH₁][data₁][DD₁?] [LFH₂][data₂][DD₂?] ... [Central Dir] [End Record]
```

We read LFH → extract data → repeat. When we encounter a non-LFH signature, we stop.

**Why this works**: Local file headers contain all information needed to extract: filename, compression method, sizes (usually), CRC32 (usually). The central directory is redundant for well-formed ZIPs.

**Data descriptor (bit 3) handling**:
- **Deflate**: Self-terminating format. `flate.Decompress` detects end-of-stream naturally. After decompressor signals EOF, read data descriptor for CRC32 validation.
- **Store with bit 3 and size=0**: Impossible to stream without size. Emit clear error: "Cannot stream-extract stored entry without size information." In practice, most ZIP generators include sizes even with bit 3 set.
- **Store with bit 3 and size≠0**: Use the size from the local header. This is the common case.

**Limitations** (documented in `--help` and error messages):
- Encrypted ZIPs: rejected (bit 0)
- Multi-disk archives: rejected
- Entries requiring central directory info not in local header: extremely rare, rejected with clear error

---

## 4. Compression Support Matrix

| Method | Code | Support | Implementation |
|--------|------|---------|---------------|
| **Store** | 0 | Full | Direct copy via `std.zip.Decompress` (`.store` variant) |
| **Deflate** | 8 | Full | `std.zip.Decompress` → `std.compress.flate.Decompress` with `.raw` container |
| Deflate64 | 9 | Skip + warn | Not in std library; no pure-Zig implementation available |
| bzip2 | 12 | Skip + warn | Not in std library |
| LZMA | 14 | Skip + warn | `std.compress.lzma` exists but uses old GenericReader API, not `Io.Reader`. ZIP LZMA also has a custom 4-byte header. Deferred to follow-up. |
| Zstandard | 93 | Skip + warn | `std.compress.zstd` exists with `Io.Reader` support. Deferred to follow-up — requires verifying ZIP-specific framing. |

**Rationale**: Store + Deflate covers ~99%+ of ZIP files in the wild. GitHub, most build tools, and OS archivers all produce deflate ZIPs. Adding zstd/lzma later is straightforward since the architecture supports pluggable decompressors.

When an unsupported method is encountered: print warning to stderr with the entry name and method code, skip the entry's data bytes, continue with next entry.

---

## 5. CLI Parsing & UX

```
Usage: zipstream <url> [options]

Downloads and extracts a ZIP file in a single streaming pass.

Options:
  -o, --output <dir>          Extract to directory (default: .)
  --strip-components <n>      Strip N leading path components
  -h, --help                  Show this help

Examples:
  zipstream https://github.com/user/repo/archive/main.zip
  zipstream https://example.com/data.zip -o /tmp/data
  zipstream https://example.com/data.zip --strip-components 1
```

**Implementation**: Iterate `std.process.args()`, match flag strings, consume next arg for values. No external dependency.

**Exit codes**: 0 = success, 1 = usage error, 2 = network/HTTP error, 3 = ZIP format error, 4 = I/O error.

---

## 6. Error Handling Strategy

| Category | Examples | Behavior |
|----------|----------|----------|
| CLI errors | Missing URL, bad flag | Print usage, exit 1 |
| Network | DNS failure, connection reset, TLS error | Print error, exit 2 |
| HTTP | Non-200 status | Print "HTTP {status}: {reason}", exit 2 |
| ZIP format | Bad signature, encrypted, unsupported method | Print entry name + error, exit 3. Unsupported method: warn + skip (non-fatal) |
| CRC mismatch | Corruption | Print entry name + expected/actual CRC, exit 3 |
| I/O | Permission denied, disk full | Print OS error + path, exit 4 |

**Cleanup**: Use `defer`/`errdefer` throughout. On mid-stream failure:
- Close open file handles (automatic via defer)
- Do NOT delete partially extracted files (user may want to inspect)
- Print "extraction incomplete" message

**Network interruption mid-entry**: The limited reader or decompressor will return `error.EndOfStream` or `error.ReadFailed`. Catch at entry level, report which entry failed, exit.

---

## 7. Reusable Std Library Components

| Component | Location | Usage |
|-----------|----------|-------|
| `LocalFileHeader` | `std/zip.zig:35` | Extern struct — cast bytes directly |
| `CompressionMethod` | `std/zip.zig:14` | Enum for store(0)/deflate(8) |
| `Decompress` | `std/zip.zig:165` | Store+deflate unified reader via vtable |
| `local_file_header_sig` | `std/zip.zig:21` | Signature constant `PK\x03\x04` |
| `central_file_header_sig` | `std/zip.zig:20` | For end-of-entries detection |
| `flate.Decompress` | `std/compress/flate/Decompress.zig` | Raw deflate with `.raw` container |
| `Io.Reader` | `std/Io/Reader.zig` | Vtable-based streaming reader |
| `Io.Reader.Limited` | `std/Io/Reader/Limited.zig` | Bound reader to N bytes |
| `Crc32IsoHdlc` | `std/hash/crc.zig` | Standard ZIP CRC-32 |
| `http.Client` | `std/http/Client.zig` | HTTP/HTTPS with redirect + TLS |

**Key API pattern** (Zig 0.15.2 `Io.Reader`):
- NOT the old `fn read([]u8) !usize` pattern
- Uses vtable: `stream(r, w, limit) !usize` — push-based, writes to a Writer
- `Reader.readSliceAll(buf)` for pulling bytes into a buffer
- `Reader.Limited` for bounding reads to a byte count
- `@fieldParentPtr` for accessing parent struct from vtable callbacks

---

## 8. Testing Plan

### Unit Tests (in-source `test` blocks)

1. **ZipStream.zig**: Parse local file header from fixed bytes, handle zip64 extras, detect data descriptor flag, reject bad signatures
2. **extract.zig**: Path sanitization (reject `../`, leading `/`), strip-components logic, top-level folder detection with single/multiple roots

### Integration Tests

1. Create test ZIPs using system `zip` command in `build.zig` test step
2. Use `std.Io.Reader.fixed()` to simulate HTTP body from a ZIP file read into memory
3. Extract to temp dir, verify output matches expected structure

### Manual Testing

```bash
# Basic extraction
zig build run -- https://github.com/ziglang/zig/archive/refs/tags/0.15.2.zip

# With output dir
zig build run -- https://github.com/ziglang/zig/archive/refs/tags/0.15.2.zip -o /tmp/test

# With strip-components (GitHub archives have a top-level dir)
zig build run -- https://github.com/ziglang/zig/archive/refs/tags/0.15.2.zip --strip-components 1 -o /tmp/test

# Multiple top-level entries (should auto-wrap)
# Create a test ZIP with multiple root files/dirs and serve locally
```

---

## 9. Implementation Order

### Phase 1: Skeleton + HTTP streaming
1. `build.zig` + `build.zig.zon` — project setup
2. `main.zig` — arg parsing, HTTP client, get `*Io.Reader` for body
3. Verify: can download and discard bytes from a URL

### Phase 2: Core ZIP streaming
4. `ZipStream.zig` — local header parser, `next()` iterator
5. `ZipStream.zig` — `entryReader()` using `std.zip.Decompress` + `Io.Reader.Limited`
6. `extract.zig` — basic extraction (create dirs, write files) without top-level logic
7. Verify: can stream-extract a simple deflate ZIP from a URL

### Phase 3: Robustness
8. Data descriptor (bit 3) support for deflate entries
9. CRC32 verification via `std.hash.crc.Crc32IsoHdlc`
10. Zip64 extra field parsing in local headers
11. Path traversal protection
12. Unsupported compression method: skip with warning

### Phase 4: UX features
13. Top-level folder detection + auto-wrapping
14. `--strip-components` support
15. `progress.zig` — progress output to stderr
16. Error messages and exit codes
17. `--help` text

### Phase 5: Tests
18. Unit tests for header parsing and path sanitization
19. Integration tests with real ZIP files
