const std = @import("std");
const zip = std.zip;
const flate = std.compress.flate;
const ZipStream = @import("ZipStream.zig");
const Progress = @import("progress.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.io.Limit;

pub const ExtractError = error{
    ReadFailed,
    EndOfStream,
    BadZipFile,
    EncryptedZip,
    UnsupportedCompression,
    StoredEntryNoSize,
    BadFilename,
    CrcMismatch,
    IoError,
    DecompressError,
};

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

pub fn extract(
    body_reader: *Reader,
    output_dir_path: []const u8,
    strip_components: u32,
    content_length: ?u64,
    progress_mode: Progress.Mode,
) ExtractError!void {
    var zs = ZipStream.init(body_reader);
    var progress = Progress.init(content_length, progress_mode);

    // Open output directory
    var output_dir = std.fs.cwd().openDir(output_dir_path, .{}) catch {
        // Try to create it
        std.fs.cwd().makePath(output_dir_path) catch return error.IoError;
        return extract(body_reader, output_dir_path, strip_components, content_length, progress_mode);
    };
    defer output_dir.close();

    // Top-level folder tracking
    var first_root: ?[256]u8 = null;
    var first_root_len: usize = 0;
    var needs_wrapper = false;
    var wrapper_name_buf: [256]u8 = undefined;
    var wrapper_name_len: usize = 0;

    var warn_buf: [1024]u8 = undefined;

    while (true) {
        const maybe_entry = zs.next() catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
            error.BadZipFile => return error.BadZipFile,
            error.EncryptedZip => return error.EncryptedZip,
            error.UnsupportedCompression => return error.UnsupportedCompression,
            error.StoredEntryNoSize => return error.StoredEntryNoSize,
        };

        const entry = maybe_entry orelse break;

        // Validate filename
        if (isBadFilename(entry.filename)) {
            progress.printWarning(formatWarning(&warn_buf, "skipping bad filename: {s}\n", .{entry.filename}));
            zs.skipEntry(&entry) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => return error.EndOfStream,
                else => return error.BadZipFile,
            };
            continue;
        }

        // Check compression method
        switch (entry.compression_method) {
            .store, .deflate => {},
            else => {
                progress.printWarning(formatWarning(&warn_buf, "skipping {s}: unsupported compression method {d}\n", .{
                    entry.filename,
                    @intFromEnum(entry.compression_method),
                }));
                zs.skipEntry(&entry) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.BadZipFile,
                };
                continue;
            },
        }

        // Apply strip-components
        const stripped_name = stripComponents(entry.filename, strip_components) orelse {
            // Not enough components, skip
            if (!entry.is_dir and entry.compressed_size > 0) {
                zs.skipEntry(&entry) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.BadZipFile,
                };
            } else if (entry.has_data_descriptor and !entry.is_dir) {
                zs.skipEntry(&entry) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.BadZipFile,
                };
            }
            continue;
        };

        if (stripped_name.len == 0) {
            // After stripping, nothing left (was a directory component that got stripped)
            continue;
        }

        // Top-level folder detection (only when strip_components == 0)
        if (strip_components == 0) {
            const root = getFirstComponent(entry.filename);
            if (first_root == null) {
                if (root.len <= 256) {
                    var buf: [256]u8 = undefined;
                    @memcpy(buf[0..root.len], root);
                    first_root = buf;
                    first_root_len = root.len;
                }
            } else if (!needs_wrapper) {
                const fr = first_root.?;
                if (!std.mem.eql(u8, fr[0..first_root_len], root)) {
                    // Multiple top-level entries — need a wrapper directory
                    needs_wrapper = true;
                    const basename = inferWrapperName(output_dir_path);
                    if (basename.len <= wrapper_name_buf.len) {
                        @memcpy(wrapper_name_buf[0..basename.len], basename);
                        wrapper_name_len = basename.len;
                        output_dir.makeDir(wrapper_name_buf[0..wrapper_name_len]) catch {};
                        // Move previously extracted first_root into wrapper
                        const first = fr[0..first_root_len];
                        // Build source and dest paths for rename
                        var src_buf: [512]u8 = undefined;
                        var dst_buf: [512]u8 = undefined;
                        const src_path = std.fmt.bufPrint(&src_buf, "{s}", .{first}) catch first;
                        const wrapper = wrapper_name_buf[0..wrapper_name_len];
                        const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ wrapper, first }) catch {
                            // If we can't build the path, just skip the move
                            continue;
                        };
                        output_dir.rename(src_path, dst_path) catch {
                            // Rename failed, try without wrapper
                            needs_wrapper = false;
                        };
                    }
                }
            }
        }

        // Determine the actual output path
        var path_buf: [1024]u8 = undefined;
        const out_path = if (needs_wrapper and strip_components == 0)
            std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
                wrapper_name_buf[0..wrapper_name_len],
                stripped_name,
            }) catch {
                progress.printWarning(formatWarning(&warn_buf, "path too long: {s}\n", .{stripped_name}));
                continue;
            }
        else
            stripped_name;

        // Replace backslashes with forward slashes
        var sanitized_buf: [1024]u8 = undefined;
        const sanitized = sanitizePath(out_path, &sanitized_buf);

        progress.setCurrentFile(entry.filename);

        if (entry.is_dir) {
            output_dir.makePath(sanitized) catch |err| {
                progress.printWarning(formatWarning(&warn_buf, "failed to create directory {s}: {}\n", .{ sanitized, err }));
            };
            if (entry.has_data_descriptor) {
                zs.skipEntry(&entry) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.BadZipFile,
                };
            }
            continue;
        }

        // Create parent directories
        if (std.fs.path.dirname(sanitized)) |parent| {
            output_dir.makePath(parent) catch |err| {
                progress.printWarning(formatWarning(&warn_buf, "failed to create directory {s}: {}\n", .{ parent, err }));
                zs.skipEntry(&entry) catch |err2| switch (err2) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.BadZipFile,
                };
                continue;
            };
        }

        // Extract file
        extractFile(&zs, &entry, output_dir, sanitized, &progress) catch |err| {
            return err;
        };

        progress.printExtracted();
    }

    progress.finish(output_dir_path);
}

fn extractFile(
    zs: *ZipStream,
    entry: *const ZipStream.Entry,
    output_dir: std.fs.Dir,
    path: []const u8,
    progress: *Progress,
) ExtractError!void {
    // Open output file
    var file = output_dir.createFile(path, .{}) catch {
        var wbuf: [1024]u8 = undefined;
        progress.printWarning(formatWarning(&wbuf, "failed to create file: {s}\n", .{path}));
        zs.skipEntry(entry) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
            else => return error.BadZipFile,
        };
        return;
    };
    defer file.close();

    // Create a limited reader for the compressed data
    // Buffer needs to be large enough for the decompressor to peek/fill
    var limit_buf: [4096]u8 = undefined;
    var limited = zs.reader.limited(Limit.limited64(entry.compressed_size), &limit_buf);

    // CRC32 computation
    var crc: std.hash.crc.Crc32IsoHdlc = .init();

    // Track compressed bytes consumed for progress reporting
    const compressed_total = entry.compressed_size;

    switch (entry.compression_method) {
        .store => {
            // Direct copy with CRC check
            var buf: [8192]u8 = undefined;
            var total_read: u64 = 0;
            while (total_read < entry.compressed_size) {
                const to_read = @min(buf.len, entry.compressed_size - total_read);
                const to_read_usize: usize = @intCast(to_read);
                const n = limited.interface.readSliceShort(buf[0..to_read_usize]) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                };
                if (n == 0) break;
                crc.update(buf[0..n]);
                file.writeAll(buf[0..n]) catch return error.IoError;
                total_read += n;
                // Track consumed compressed bytes
                const consumed = compressed_total - @as(u64, @intFromEnum(limited.remaining));
                progress.setDownloaded(consumed);
                progress.update();
            }
        },
        .deflate => {
            // Use flate decompressor — buffer must be >= flate.max_window_len (65536)
            var inflate_buf: [flate.max_window_len]u8 = undefined;
            var decompress_state = flate.Decompress.init(&limited.interface, .raw, &inflate_buf);
            var read_buf: [8192]u8 = undefined;

            while (true) {
                const n = decompress_state.reader.readSliceShort(&read_buf) catch |err| switch (err) {
                    error.ReadFailed => return error.DecompressError,
                };
                if (n == 0) break;
                crc.update(read_buf[0..n]);
                file.writeAll(read_buf[0..n]) catch return error.IoError;
                // Track consumed compressed bytes
                const consumed = compressed_total - @as(u64, @intFromEnum(limited.remaining));
                progress.setDownloaded(consumed);
                progress.update();
            }

            // Discard any remaining bytes in the limited reader (deflate may not consume all)
            _ = limited.interface.discardRemaining() catch {};
        },
        else => unreachable,
    }

    const actual_crc = crc.final();

    // Handle data descriptor
    if (entry.has_data_descriptor) {
        const descriptor_crc = zs.readDataDescriptorCrc() catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
            else => return error.BadZipFile,
        };
        // Use descriptor CRC if header CRC was 0
        const expected = if (entry.expected_crc32 == 0) descriptor_crc else entry.expected_crc32;
        if (expected != 0 and actual_crc != expected) {
            var crc_warn_buf: [256]u8 = undefined;
            progress.printWarning(formatWarning(&crc_warn_buf, "CRC mismatch for {s}: expected 0x{x:0>8}, got 0x{x:0>8}\n", .{
                entry.filename, expected, actual_crc,
            }));
            return error.CrcMismatch;
        }
    } else {
        if (entry.expected_crc32 != 0 and actual_crc != entry.expected_crc32) {
            var crc_warn_buf: [256]u8 = undefined;
            progress.printWarning(formatWarning(&crc_warn_buf, "CRC mismatch for {s}: expected 0x{x:0>8}, got 0x{x:0>8}\n", .{
                entry.filename, entry.expected_crc32, actual_crc,
            }));
            return error.CrcMismatch;
        }
    }
}

fn isBadFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename[0] == '/')
        return true;

    var it = std.mem.splitScalar(u8, filename, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    // Also check backslash paths
    var it2 = std.mem.splitScalar(u8, filename, '\\');
    while (it2.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    return false;
}

fn stripComponents(path: []const u8, n: u32) ?[]const u8 {
    if (n == 0) return path;

    var remaining = path;
    var stripped: u32 = 0;
    while (stripped < n) {
        if (std.mem.indexOfScalar(u8, remaining, '/')) |idx| {
            remaining = remaining[idx + 1 ..];
            stripped += 1;
        } else {
            return null; // Not enough components
        }
    }
    return remaining;
}

fn getFirstComponent(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |idx| {
        return path[0..idx];
    }
    return path;
}

fn sanitizePath(path: []const u8, buf: []u8) []const u8 {
    if (path.len > buf.len) return path;
    var len: usize = 0;
    for (path) |c| {
        buf[len] = if (c == '\\') '/' else c;
        len += 1;
    }
    return buf[0..len];
}

fn inferWrapperName(output_dir_path: []const u8) []const u8 {
    _ = output_dir_path;
    return "zipstream-output";
}

fn formatWarning(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "warning\n";
}

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
