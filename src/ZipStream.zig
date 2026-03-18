const std = @import("std");
const zip = std.zip;
const flate = std.compress.flate;

const Reader = std.Io.Reader;
const Limit = std.io.Limit;

const ZipStream = @This();

reader: *Reader,
filename_buf: [1024]u8,
done: bool,

pub const Entry = struct {
    filename: []const u8,
    compression_method: zip.CompressionMethod,
    compressed_size: u64,
    uncompressed_size: u64,
    expected_crc32: u32,
    has_data_descriptor: bool,
    is_dir: bool,
};

pub const Error = error{
    ReadFailed,
    EndOfStream,
    BadZipFile,
    EncryptedZip,
    UnsupportedCompression,
    StoredEntryNoSize,
};

pub fn init(reader: *Reader) ZipStream {
    return .{
        .reader = reader,
        .filename_buf = undefined,
        .done = false,
    };
}

/// Returns the next entry, or null when central directory / end record is reached.
pub fn next(self: *ZipStream) Error!?Entry {
    if (self.done) return null;

    // Read signature (4 bytes)
    const sig = self.reader.takeArray(4) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => {
            self.done = true;
            return null;
        },
    };

    // Check if we've reached central directory or end record
    if (std.mem.eql(u8, sig, &zip.central_file_header_sig) or
        std.mem.eql(u8, sig, &zip.end_record_sig) or
        std.mem.eql(u8, sig, &zip.end_record64_sig) or
        std.mem.eql(u8, sig, &zip.end_locator64_sig))
    {
        self.done = true;
        return null;
    }

    if (!std.mem.eql(u8, sig, &zip.local_file_header_sig)) {
        return error.BadZipFile;
    }

    // Read the rest of the local file header (30 - 4 = 26 bytes)
    const header_bytes = self.reader.take(26) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.BadZipFile,
    };

    const version_needed = std.mem.readInt(u16, header_bytes[0..2], .little);
    _ = version_needed;
    const flags = std.mem.readInt(u16, header_bytes[2..4], .little);
    const compression_method_raw = std.mem.readInt(u16, header_bytes[4..6], .little);
    // skip last_mod_time (2) and last_mod_date (2)
    const crc32 = std.mem.readInt(u32, header_bytes[10..14], .little);
    const compressed_size_32 = std.mem.readInt(u32, header_bytes[14..18], .little);
    const uncompressed_size_32 = std.mem.readInt(u32, header_bytes[18..22], .little);
    const filename_len = std.mem.readInt(u16, header_bytes[22..24], .little);
    const extra_len = std.mem.readInt(u16, header_bytes[24..26], .little);

    // Check for encryption (bit 0)
    if (flags & 1 != 0) {
        return error.EncryptedZip;
    }

    const has_data_descriptor = (flags & (1 << 3)) != 0;

    // Read filename
    if (filename_len > self.filename_buf.len) {
        return error.BadZipFile;
    }
    const filename_slice = self.reader.take(filename_len) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.BadZipFile,
    };
    @memcpy(self.filename_buf[0..filename_len], filename_slice);
    const filename = self.filename_buf[0..filename_len];

    // Parse extra fields for zip64 sizes
    var compressed_size: u64 = compressed_size_32;
    var uncompressed_size: u64 = uncompressed_size_32;

    if (extra_len > 0) {
        // Read extra field data
        var extra_remaining: u16 = extra_len;
        while (extra_remaining >= 4) {
            const extra_header = self.reader.take(4) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => return error.BadZipFile,
            };
            extra_remaining -= 4;

            const header_id = std.mem.readInt(u16, extra_header[0..2], .little);
            const data_size = std.mem.readInt(u16, extra_header[2..4], .little);

            if (data_size > extra_remaining) {
                return error.BadZipFile;
            }

            if (header_id == @intFromEnum(zip.ExtraHeader.zip64_info)) {
                // Parse zip64 extended information
                var zip64_offset: u16 = 0;
                if (uncompressed_size_32 == 0xFFFFFFFF and zip64_offset + 8 <= data_size) {
                    const bytes = self.reader.take(8) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        error.EndOfStream => return error.BadZipFile,
                    };
                    uncompressed_size = std.mem.readInt(u64, bytes[0..8], .little);
                    zip64_offset += 8;
                    extra_remaining -= 8;
                }
                if (compressed_size_32 == 0xFFFFFFFF and zip64_offset + 8 <= data_size) {
                    const bytes = self.reader.take(8) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        error.EndOfStream => return error.BadZipFile,
                    };
                    compressed_size = std.mem.readInt(u64, bytes[0..8], .little);
                    zip64_offset += 8;
                    extra_remaining -= 8;
                }
                // Skip rest of zip64 extra
                const skip = data_size - zip64_offset;
                if (skip > 0) {
                    self.reader.discardAll(skip) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        error.EndOfStream => return error.BadZipFile,
                    };
                    extra_remaining -= skip;
                }
            } else {
                // Skip unknown extra field
                self.reader.discardAll(data_size) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => return error.BadZipFile,
                };
                extra_remaining -= data_size;
            }
        }
        // Skip any remaining extra bytes
        if (extra_remaining > 0) {
            self.reader.discardAll(extra_remaining) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => return error.BadZipFile,
            };
        }
    }

    const compression_method: zip.CompressionMethod = @enumFromInt(compression_method_raw);

    // Determine if it's a directory
    const is_dir = filename_len > 0 and filename[filename_len - 1] == '/';

    return Entry{
        .filename = filename,
        .compression_method = compression_method,
        .compressed_size = compressed_size,
        .uncompressed_size = uncompressed_size,
        .expected_crc32 = crc32,
        .has_data_descriptor = has_data_descriptor,
        .is_dir = is_dir,
    };
}

/// Skip an entry's data (for unsupported compression methods or directories).
pub fn skipEntry(self: *ZipStream, entry: *const Entry) Error!void {
    if (entry.compressed_size > 0) {
        self.reader.discardAll64(entry.compressed_size) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
        };
    }
    if (entry.has_data_descriptor) {
        try self.readDataDescriptor(entry);
    }
}

/// Read and discard the data descriptor after an entry.
/// Returns the CRC32 from the descriptor if the header CRC was 0.
fn readDataDescriptor(self: *ZipStream, entry: *const Entry) Error!void {
    _ = entry;
    // Data descriptor can be:
    //   [PK\x07\x08] crc32(4) compressed_size(4) uncompressed_size(4)  — with signature
    //   crc32(4) compressed_size(4) uncompressed_size(4)                — without signature
    // Or zip64 variants with 8-byte sizes.
    const first4 = self.reader.takeArray(4) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.EndOfStream,
    };

    if (std.mem.eql(u8, first4, &[_]u8{ 'P', 'K', 7, 8 })) {
        // Has signature prefix — skip crc32 + compressed_size + uncompressed_size
        self.reader.discardAll(12) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
        };
    } else {
        // No signature — first4 is the crc32, skip compressed_size + uncompressed_size
        self.reader.discardAll(8) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
        };
    }
}

/// Read data descriptor and return the CRC32 value from it.
pub fn readDataDescriptorCrc(self: *ZipStream) Error!u32 {
    const first4 = self.reader.takeArray(4) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.EndOfStream,
    };

    if (std.mem.eql(u8, first4, &[_]u8{ 'P', 'K', 7, 8 })) {
        // Has signature prefix — next 4 bytes are CRC32
        const crc_bytes = self.reader.takeArray(4) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
        };
        const crc = std.mem.readInt(u32, crc_bytes, .little);
        // Skip compressed_size + uncompressed_size
        self.reader.discardAll(8) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
        };
        return crc;
    } else {
        // No signature — first4 is the CRC32
        const crc = std.mem.readInt(u32, first4, .little);
        // Skip compressed_size + uncompressed_size
        self.reader.discardAll(8) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
        };
        return crc;
    }
}
