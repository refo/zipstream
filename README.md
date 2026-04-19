# zipstream

A CLI tool that downloads and extracts ZIP files in a single streaming pass — no temporary files, no download-then-extract.

## Features

- **True streaming extraction** — parses local file headers sequentially, extracts files as bytes arrive over HTTP
- **Store and Deflate** compression (covers ~99% of ZIP files in the wild)
- **CRC32 verification** for data integrity
- **Zip64** support for large archives
- **Path traversal protection** — rejects `../` and absolute paths
- **Smart wrapping** — when extracting to the current directory, archives with multiple top-level entries are wrapped in a folder named after the archive. Disable with `--no-wrap`; force with `--wrap`. Supplying `-o <dir>` never auto-wraps.
- **`--strip-components`** — strip leading path components (like `tar`)
- **Progress output** to stderr with TTY-aware formatting
- **`--json`** — NDJSON progress output for machine consumption

## Installation

### Homebrew (macOS & Linux)

```sh
brew install refo/tap/zipstream
```

### Linux / macOS (shell script)

```sh
curl -fsSL https://raw.githubusercontent.com/refo/zipstream/main/install.sh | sh
```

Or install to a custom directory:

```sh
INSTALL_DIR=~/.local/bin curl -fsSL https://raw.githubusercontent.com/refo/zipstream/main/install.sh | sh
```

### Windows (Scoop)

```powershell
scoop bucket add refo https://github.com/refo/scoop-bucket
scoop install zipstream
```

### Download binaries

Pre-built binaries for all platforms are available on the [Releases](https://github.com/refo/zipstream/releases) page.

### Build from source

Requires [Zig 0.15.2](https://ziglang.org/download/).

```sh
git clone https://github.com/refo/zipstream.git
cd zipstream
zig build -Doptimize=ReleaseFast
```

The binary will be at `zig-out/bin/zipstream`.

## Usage

```
zipstream <url> [options]
```

### Options

| Flag | Description |
|------|-------------|
| `-o, --output <dir>` | Extract to directory (default: `.`) |
| `--strip-components <n>` | Strip N leading path components |
| `--wrap` | Always wrap entries in a generated directory |
| `--no-wrap` | Never wrap entries (extract directly) |
| `--json` | Output progress as NDJSON to stderr |
| `-h, --help` | Show help |

### Examples

```sh
# Extract a GitHub repo archive
zipstream https://github.com/user/repo/archive/main.zip

# Extract to a specific directory
zipstream https://example.com/data.zip -o /tmp/data

# Strip the top-level directory (common for GitHub archives)
zipstream https://github.com/user/repo/archive/main.zip --strip-components 1 -o ./repo
```

### JSON output

With `--json`, progress is emitted as [NDJSON](https://github.com/ndjson/ndjson-spec) (one JSON object per line) to stderr:

```jsonl
{"type":"progress","file":"repo-main/large-file.bin","bytes_downloaded":65536}
{"type":"extract","file":"repo-main/large-file.bin","bytes_downloaded":131072}
{"type":"done","files_extracted":42,"bytes_downloaded":1048576,"output":"/tmp/out"}
```

Event types:
- **`progress`** — periodic update during file extraction (throttled)
- **`extract`** — file extraction completed
- **`warning`** — non-fatal issue (unsupported compression, bad filename)
- **`error`** — fatal error with `message` field
- **`done`** — extraction finished successfully

When `Content-Length` is available, `progress` and `extract` events include `bytes_total` and `percent` fields.

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

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Usage error |
| 2 | Network/HTTP error |
| 3 | ZIP format error |
| 4 | I/O error |

## How it works

ZIP files store a central directory at the end of the archive, but each file entry also has a **local file header** immediately before its data. zipstream exploits this by parsing local headers sequentially from a forward-only HTTP stream:

```
[LFH₁][data₁] [LFH₂][data₂] ... [Central Dir] [End Record]
  ↑ read         ↑ read              ↑ stop
```

When a non-local-header signature is encountered (central directory), extraction stops. This means the entire archive never needs to exist on disk.

## Limitations

- Encrypted ZIPs are rejected
- Compression methods other than Store (0) and Deflate (8) are skipped with a warning
- Multi-disk archives are not supported

## License

MIT
