# zipstream

A CLI tool that downloads and extracts ZIP files in a single streaming pass — no temporary files, no download-then-extract.

## Features

- **True streaming extraction** — parses local file headers sequentially, extracts files as bytes arrive over HTTP
- **Store and Deflate** compression (covers ~99% of ZIP files in the wild)
- **CRC32 verification** for data integrity
- **Zip64** support for large archives
- **Path traversal protection** — rejects `../` and absolute paths
- **Auto-wrapping** — creates a containing folder when the archive has multiple top-level entries
- **`--strip-components`** — strip leading path components (like `tar`)
- **Progress output** to stderr with TTY-aware formatting

## Installation

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
