const std = @import("std");
const extract_mod = @import("extract.zig");
const Progress = @import("progress.zig");

const Reader = std.Io.Reader;

const Options = struct {
    url: []const u8,
    output_dir: []const u8,
    strip_components: u32,
    json: bool,
    wrap_mode: extract_mod.WrapMode,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const options = parseArgs(allocator) orelse {
        printUsage();
        std.process.exit(1);
    };

    run(allocator, options) catch |err| {
        const stderr = std.fs.File.stderr();
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {}\n", .{err}) catch "error\n";
        stderr.writeAll(msg) catch {};
        const exit_code: u8 = switch (err) {
            error.ReadFailed, error.EndOfStream => 2,
            error.BadZipFile, error.EncryptedZip, error.CrcMismatch => 3,
            error.IoError => 4,
            else => 1,
        };
        std.process.exit(exit_code);
    };
}

fn run(allocator: std.mem.Allocator, options: Options) !void {
    // Setup HTTP client
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(options.url) catch {
        fatal("invalid URL: {s}", .{options.url});
    };

    var req = try client.request(.GET, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    // Accept identity content encoding (the default accept_encoding array
    // only has gzip/deflate enabled, but we want raw bytes)
    req.accept_encoding = comptime blk: {
        var ae: @TypeOf(req.accept_encoding) = @splat(false);
        ae[@intFromEnum(std.http.ContentEncoding.identity)] = true;
        break :blk ae;
    };

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        var buf: [256]u8 = undefined;
        const reason = response.head.reason;
        const msg = std.fmt.bufPrint(&buf, "HTTP {d}: {s}", .{
            @intFromEnum(response.head.status),
            reason,
        }) catch "HTTP error";
        fatal("{s}", .{msg});
    }

    const content_length = response.head.content_length;

    const content_disposition_raw: ?[]const u8 = blk: {
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-disposition")) break :blk h.value;
        }
        break :blk null;
    };

    // Get body reader (raw, no decompression)
    var transfer_buf: [16384]u8 = undefined;
    const body_reader: *Reader = response.reader(&transfer_buf);

    // Extract
    const progress_mode: Progress.Mode = if (options.json) .json else .human;
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
}

fn parseArgs(allocator: std.mem.Allocator) ?Options {
    var args = std.process.argsWithAllocator(allocator) catch {
        fatal("failed to read command-line arguments", .{});
    };
    defer args.deinit();
    _ = args.skip(); // program name

    var url: ?[]const u8 = null;
    var output_dir: []const u8 = ".";
    var strip_components: u32 = 0;
    var json = false;
    var wrap_flag = false;
    var no_wrap_flag = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--wrap")) {
            wrap_flag = true;
        } else if (std.mem.eql(u8, arg, "--no-wrap")) {
            no_wrap_flag = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_dir = args.next() orelse {
                fatal("missing value for {s}", .{arg});
            };
        } else if (std.mem.eql(u8, arg, "--strip-components")) {
            const val = args.next() orelse {
                fatal("missing value for --strip-components", .{});
            };
            strip_components = std.fmt.parseInt(u32, val, 10) catch {
                fatal("invalid number for --strip-components: {s}", .{val});
            };
        } else if (arg[0] == '-') {
            fatal("unknown option: {s}", .{arg});
        } else {
            url = arg;
        }
    }

    if (url == null) return null;

    if (wrap_flag and no_wrap_flag) {
        fatal("--wrap and --no-wrap are mutually exclusive", .{});
    }

    const wrap_mode: extract_mod.WrapMode =
        if (wrap_flag) .always else if (no_wrap_flag) .never else .auto;

    return Options{
        .url = url.?,
        .output_dir = output_dir,
        .strip_components = strip_components,
        .json = json,
        .wrap_mode = wrap_mode,
    };
}

fn printUsage() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll(
        \\Usage: zipstream <url> [options]
        \\
        \\Downloads and extracts a ZIP file in a single streaming pass.
        \\
        \\Options:
        \\  -o, --output <dir>          Extract to directory (default: .)
        \\  --strip-components <n>      Strip N leading path components
        \\  --wrap                      Always wrap entries in a generated directory
        \\  --no-wrap                   Never wrap entries (extract directly)
        \\  --json                      Output progress as NDJSON to stderr
        \\  -h, --help                  Show this help
        \\
        \\Examples:
        \\  zipstream https://github.com/user/repo/archive/main.zip
        \\  zipstream https://example.com/data.zip -o /tmp/data
        \\  zipstream https://example.com/data.zip --strip-components 1
        \\
    ) catch {};
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    const stderr = std.fs.File.stderr();
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt ++ "\n", args) catch "error\n";
    stderr.writeAll(msg) catch {};
    std.process.exit(1);
}

test {
    _ = @import("ZipStream.zig");
    _ = @import("extract.zig");
    _ = @import("progress.zig");
}
