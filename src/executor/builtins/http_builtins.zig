const std = @import("std");
const common = @import("common.zig");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

/// HTTP client builtin: http <method> <url> [options]
///
/// Supported methods: get, post, put, delete, head
///
/// Options:
///   --body <data>           Request body (for POST/PUT)
///   --header <key:value>    Add a request header (can be repeated)
///   --content-type <type>   Set Content-Type header
///
/// Examples:
///   http get https://api.example.com/users
///   http post https://api.example.com/users --body '{"name":"den"}' --content-type application/json
///   http put https://api.example.com/users/1 --body '{"name":"updated"}' --header "Authorization:Bearer tok123"
///   http delete https://api.example.com/users/1
///   http head https://api.example.com/health
pub fn httpCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try printUsage();
        return 1;
    }

    // Parse subcommand (method)
    const method_str = command.args[0];
    const method = parseMethod(method_str) orelse {
        try IO.eprint("http: unknown method '{s}'\n", .{method_str});
        try IO.eprint("Supported methods: get, post, put, delete, head\n", .{});
        return 1;
    };

    if (command.args.len < 2) {
        try IO.eprint("http: missing URL\n", .{});
        try IO.eprint("Usage: http {s} <url> [options]\n", .{method_str});
        return 1;
    }

    const url = command.args[1];

    // Parse optional flags
    var body: ?[]const u8 = null;
    var content_type: ?[]const u8 = null;
    var headers = std.ArrayList([]const u8).empty;
    defer headers.deinit(allocator);

    var i: usize = 2;
    while (i < command.args.len) : (i += 1) {
        if (std.mem.eql(u8, command.args[i], "--body") or std.mem.eql(u8, command.args[i], "-d")) {
            if (i + 1 < command.args.len) {
                body = command.args[i + 1];
                i += 1;
            } else {
                try IO.eprint("http: --body requires a value\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, command.args[i], "--header") or std.mem.eql(u8, command.args[i], "-H")) {
            if (i + 1 < command.args.len) {
                try headers.append(allocator, command.args[i + 1]);
                i += 1;
            } else {
                try IO.eprint("http: --header requires a value (key:value)\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, command.args[i], "--content-type")) {
            if (i + 1 < command.args.len) {
                content_type = command.args[i + 1];
                i += 1;
            } else {
                try IO.eprint("http: --content-type requires a value\n", .{});
                return 1;
            }
        } else {
            try IO.eprint("http: unknown option '{s}'\n", .{command.args[i]});
            return 1;
        }
    }

    // Validate: POST/PUT should have a body (warn if not)
    if ((method == .post or method == .put) and body == null) {
        try IO.eprint("http: warning: {s} request without --body\n", .{method_str});
    }

    // Build curl argv
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "curl");
    try argv.append(allocator, "-s"); // silent mode (no progress bar)
    try argv.append(allocator, "-S"); // show errors even in silent mode

    // For HEAD requests, use -I to show headers only
    if (method == .head) {
        try argv.append(allocator, "-I");
    } else {
        // Include response headers in output for non-HEAD requests
        try argv.append(allocator, "-i");
    }

    // Set HTTP method
    try argv.append(allocator, "-X");
    try argv.append(allocator, method.toCurlFlag());

    // Add Content-Type header if specified
    if (content_type) |ct| {
        try argv.append(allocator, "-H");
        const ct_header = try std.fmt.allocPrint(allocator, "Content-Type: {s}", .{ct});
        defer allocator.free(ct_header);
        const ct_header_owned = try allocator.dupe(u8, ct_header);
        try argv.append(allocator, ct_header_owned);
    }

    // Track which header strings we allocated so we can free them
    var allocated_headers = std.ArrayList([]const u8).empty;
    defer {
        for (allocated_headers.items) |h| {
            allocator.free(h);
        }
        allocated_headers.deinit(allocator);
    }

    if (content_type) |_| {
        // The ct_header_owned was already added; track it for cleanup
        // It's the last item in argv that we allocated
        try allocated_headers.append(allocator, argv.items[argv.items.len - 1]);
    }

    // Add custom headers
    for (headers.items) |header| {
        // Validate header format (should contain ':')
        if (std.mem.indexOfScalar(u8, header, ':') == null) {
            try IO.eprint("http: invalid header format '{s}' (expected key:value)\n", .{header});
            return 1;
        }
        try argv.append(allocator, "-H");
        // Convert "key:value" to "key: value" for curl if needed
        const formatted = try formatHeader(allocator, header);
        try argv.append(allocator, formatted);
        try allocated_headers.append(allocator, formatted);
    }

    // Add request body
    if (body) |b| {
        try argv.append(allocator, "-d");
        try argv.append(allocator, b);
    }

    // Add URL (must be last)
    try argv.append(allocator, url);

    // Use spawn.captureOutput for cross-platform process execution
    const spawn = common.spawn;
    const result = spawn.captureOutput(allocator, .{
        .argv = argv.items,
    }) catch {
        try IO.eprint("http: failed to execute curl\n", .{});
        return 1;
    };
    defer result.deinit(allocator);

    // Print output
    if (result.stdout.len > 0) {
        try IO.writeBytes(result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') {
            try IO.print("\n", .{});
        }
    }

    if (result.exit_code != 0) {
        try IO.eprint("http: curl exited with code {d}\n", .{result.exit_code});
    }

    return result.exit_code;
}

/// Supported HTTP methods
const HttpMethod = enum {
    get,
    post,
    put,
    delete,
    head,

    /// Convert to the curl -X method string
    fn toCurlFlag(self: HttpMethod) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .put => "PUT",
            .delete => "DELETE",
            .head => "HEAD",
        };
    }
};

/// Parse method string to HttpMethod enum
fn parseMethod(s: []const u8) ?HttpMethod {
    // Case-insensitive comparison
    if (std.ascii.eqlIgnoreCase(s, "get")) return .get;
    if (std.ascii.eqlIgnoreCase(s, "post")) return .post;
    if (std.ascii.eqlIgnoreCase(s, "put")) return .put;
    if (std.ascii.eqlIgnoreCase(s, "delete")) return .delete;
    if (std.ascii.eqlIgnoreCase(s, "head")) return .head;
    return null;
}

/// Format a "key:value" header string into "key: value" for curl
fn formatHeader(allocator: std.mem.Allocator, header: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, header, ':')) |colon_pos| {
        const key = std.mem.trim(u8, header[0..colon_pos], &std.ascii.whitespace);
        const val_start = colon_pos + 1;
        const val = if (val_start < header.len)
            std.mem.trim(u8, header[val_start..], &std.ascii.whitespace)
        else
            "";
        return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ key, val });
    }
    return try allocator.dupe(u8, header);
}

/// Print usage information
fn printUsage() !void {
    try IO.print(
        \\Usage: http <method> <url> [options]
        \\
        \\Methods:
        \\  get       Send a GET request
        \\  post      Send a POST request
        \\  put       Send a PUT request
        \\  delete    Send a DELETE request
        \\  head      Send a HEAD request
        \\
        \\Options:
        \\  --body, -d <data>           Request body (for POST/PUT)
        \\  --header, -H <key:value>    Add a request header (repeatable)
        \\  --content-type <type>       Set the Content-Type header
        \\
        \\Examples:
        \\  http get https://api.example.com/users
        \\  http post https://api.example.com/users --body '{{"name":"den"}}' --content-type application/json
        \\  http delete https://api.example.com/users/1
        \\  http head https://api.example.com/health
        \\  http get https://example.com --header "Authorization:Bearer token123"
        \\
    , .{});
}
