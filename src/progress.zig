const std = @import("std");

const Progress = @This();

pub const Mode = enum {
    human,
    json,
};

stderr: std.fs.File,
is_tty: bool,
mode: Mode,
total_bytes: ?u64,
bytes_downloaded: u64,
/// Bytes consumed before the current file started (accumulated from previous files)
bytes_before_current_file: u64,
files_extracted: u64,
current_file: []const u8,
last_line_len: usize,
/// Throttle: last reported byte count (avoids flooding JSON consumers)
last_reported_bytes: u64,

pub fn init(total_bytes: ?u64, mode: Mode) Progress {
    const stderr = std.fs.File.stderr();
    return .{
        .stderr = stderr,
        .is_tty = stderr.isTty(),
        .mode = mode,
        .total_bytes = total_bytes,
        .bytes_downloaded = 0,
        .bytes_before_current_file = 0,
        .files_extracted = 0,
        .current_file = "",
        .last_line_len = 0,
        .last_reported_bytes = 0,
    };
}

pub fn setCurrentFile(self: *Progress, name: []const u8) void {
    // Accumulate bytes from the previous file
    self.bytes_before_current_file = self.bytes_downloaded;
    self.current_file = name;
    self.files_extracted += 1;
}

/// Set downloaded bytes for the current file (compressed bytes consumed from stream).
/// This is relative to the current file; we add the accumulated total from previous files.
pub fn setDownloaded(self: *Progress, current_file_bytes: u64) void {
    self.bytes_downloaded = self.bytes_before_current_file + current_file_bytes;
}

pub fn update(self: *Progress) void {
    switch (self.mode) {
        .human => {
            if (self.is_tty) {
                self.printTty();
            }
        },
        .json => {
            // Throttle: only emit if bytes changed by at least 64KB or
            // percentage changed by at least 1%
            const threshold: u64 = if (self.total_bytes) |total|
                @max(total / 100, 1)
            else
                65536;
            if (self.bytes_downloaded - self.last_reported_bytes >= threshold) {
                self.last_reported_bytes = self.bytes_downloaded;
                self.emitJson(.progress);
            }
        },
    }
}

pub fn printExtracted(self: *Progress) void {
    switch (self.mode) {
        .human => {
            if (self.is_tty) {
                self.clearLine();
            }
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "  {s}\n", .{self.current_file}) catch return;
            self.stderr.writeAll(msg) catch {};
            self.last_line_len = 0;
        },
        .json => {
            self.emitJson(.extract);
        },
    }
}

pub fn printWarning(self: *Progress, message: []const u8) void {
    switch (self.mode) {
        .human => {
            self.stderr.writeAll(message) catch {};
        },
        .json => {
            self.emitJsonMessage(.warning, message);
        },
    }
}

pub fn finish(self: *Progress, output_dir: []const u8) void {
    switch (self.mode) {
        .human => {
            if (self.is_tty) {
                self.clearLine();
            }
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Extracted {d} files to {s}\n", .{
                self.files_extracted,
                output_dir,
            }) catch return;
            self.stderr.writeAll(msg) catch {};
        },
        .json => {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf,
                \\{{"type":"done","files_extracted":{d},"bytes_downloaded":{d},"output":"{s}"}}
                \\
            , .{
                self.files_extracted,
                self.bytes_downloaded,
                output_dir,
            }) catch return;
            self.stderr.writeAll(msg) catch {};
        },
    }
}

pub fn emitError(self: *Progress, message: []const u8) void {
    switch (self.mode) {
        .human => {
            self.stderr.writeAll(message) catch {};
        },
        .json => {
            self.emitJsonMessage(.@"error", message);
        },
    }
}

const EventType = enum { progress, extract, warning, @"error" };

fn emitJson(self: *Progress, event: EventType) void {
    var buf: [1024]u8 = undefined;
    const percent: ?u64 = if (self.total_bytes) |total|
        (if (total > 0) self.bytes_downloaded * 100 / total else 0)
    else
        null;

    const msg = if (percent) |pct|
        std.fmt.bufPrint(&buf,
            \\{{"type":"{s}","file":"{s}","bytes_downloaded":{d},"bytes_total":{d},"percent":{d}}}
            \\
        , .{
            @tagName(event),
            self.current_file,
            self.bytes_downloaded,
            self.total_bytes.?,
            pct,
        }) catch return
    else
        std.fmt.bufPrint(&buf,
            \\{{"type":"{s}","file":"{s}","bytes_downloaded":{d}}}
            \\
        , .{
            @tagName(event),
            self.current_file,
            self.bytes_downloaded,
        }) catch return;

    self.stderr.writeAll(msg) catch {};
}

fn emitJsonMessage(self: *Progress, event: EventType, message: []const u8) void {
    // Strip trailing newline from message for clean JSON
    const trimmed = std.mem.trimRight(u8, message, "\n");
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\{{"type":"{s}","message":"{s}"}}
        \\
    , .{
        @tagName(event),
        trimmed,
    }) catch return;
    self.stderr.writeAll(msg) catch {};
}

fn printTty(self: *Progress) void {
    var buf: [512]u8 = undefined;
    const msg = if (self.total_bytes) |total|
        std.fmt.bufPrint(&buf, "\r  {s} ({d}%)", .{
            truncateName(self.current_file),
            if (total > 0) self.bytes_downloaded * 100 / total else @as(u64, 0),
        }) catch return
    else
        std.fmt.bufPrint(&buf, "\r  {s} ({d} bytes)", .{
            truncateName(self.current_file),
            self.bytes_downloaded,
        }) catch return;

    // Pad with spaces to clear previous line
    const pad_len = if (self.last_line_len > msg.len) self.last_line_len - msg.len else 0;
    self.stderr.writeAll(msg) catch {};
    if (pad_len > 0) {
        var spaces: [80]u8 = undefined;
        const n = @min(pad_len, spaces.len);
        @memset(spaces[0..n], ' ');
        self.stderr.writeAll(spaces[0..n]) catch {};
    }
    self.last_line_len = msg.len;
}

fn clearLine(self: *Progress) void {
    if (self.last_line_len > 0) {
        self.stderr.writeAll("\r") catch {};
        var spaces: [120]u8 = undefined;
        const n = @min(self.last_line_len + 10, spaces.len);
        @memset(spaces[0..n], ' ');
        self.stderr.writeAll(spaces[0..n]) catch {};
        self.stderr.writeAll("\r") catch {};
    }
}

fn truncateName(name: []const u8) []const u8 {
    if (name.len <= 60) return name;
    return name[name.len - 57 ..];
}
