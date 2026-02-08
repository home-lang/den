const std = @import("std");
const posix = std.posix;
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

    // Create pipes for stdout and stderr capture
    var stdout_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stdout_fds) != 0) {
        try IO.eprint("http: failed to create pipe\n", .{});
        return 1;
    }
    var stderr_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stderr_fds) != 0) {
        _ = std.c.close(stdout_fds[0]);
        _ = std.c.close(stdout_fds[1]);
        try IO.eprint("http: failed to create pipe\n", .{});
        return 1;
    }

    // Build null-terminated argv for execvp
    // Each arg string needs to be null-terminated
    var c_argv_buf: [64]?[*:0]const u8 = .{null} ** 64;
    var z_strs: [64][]u8 = undefined;
    var z_count: usize = 0;
    for (argv.items, 0..) |arg, idx| {
        if (idx >= 63) break;
        const z = try allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(z[0..arg.len], arg);
        c_argv_buf[idx] = z.ptr;
        z_strs[idx] = z;
        z_count = idx + 1;
    }
    defer for (z_strs[0..z_count]) |z| allocator.free(z[0 .. z.len + 1]);

    const fork_ret = std.c.fork();
    if (fork_ret < 0) {
        _ = std.c.close(stdout_fds[0]);
        _ = std.c.close(stdout_fds[1]);
        _ = std.c.close(stderr_fds[0]);
        _ = std.c.close(stderr_fds[1]);
        try IO.eprint("http: failed to fork\n", .{});
        return 1;
    }

    const pid: std.c.pid_t = @intCast(fork_ret);
    if (pid == 0) {
        // Child process
        _ = std.c.close(stdout_fds[0]);
        _ = std.c.close(stderr_fds[0]);
        _ = std.c.dup2(stdout_fds[1], posix.STDOUT_FILENO);
        _ = std.c.dup2(stderr_fds[1], posix.STDERR_FILENO);
        _ = std.c.close(stdout_fds[1]);
        _ = std.c.close(stderr_fds[1]);

        const c_argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&c_argv_buf);
        _ = common.c_exec.execvp(c_argv_buf[0].?, c_argv_ptr);
        std.c._exit(127);
    }

    // Parent process
    _ = std.c.close(stdout_fds[1]);
    _ = std.c.close(stderr_fds[1]);

    // Read stdout
    var output_buf = std.ArrayList(u8).empty;
    defer output_buf.deinit(allocator);
    {
        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = posix.read(@intCast(stdout_fds[0]), &read_buf) catch break;
            if (n == 0) break;
            try output_buf.appendSlice(allocator, read_buf[0..n]);
        }
    }
    _ = std.c.close(stdout_fds[0]);

    // Read stderr
    var stderr_buf = std.ArrayList(u8).empty;
    defer stderr_buf.deinit(allocator);
    {
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(@intCast(stderr_fds[0]), &read_buf) catch break;
            if (n == 0) break;
            try stderr_buf.appendSlice(allocator, read_buf[0..n]);
        }
    }
    _ = std.c.close(stderr_fds[0]);

    // Wait for child to complete
    var wait_status: c_int = 0;
    _ = std.c.waitpid(pid, &wait_status, 0);
    const wait_u: u32 = @bitCast(wait_status);
    const exit_code: i32 = if (std.posix.W.IFEXITED(wait_u))
        @intCast(std.posix.W.EXITSTATUS(wait_u))
    else if (std.posix.W.IFSIGNALED(wait_u))
        128 + @as(i32, @intCast(@intFromEnum(std.posix.W.TERMSIG(wait_u))))
    else
        1;

    // Print output
    if (output_buf.items.len > 0) {
        try IO.writeBytes(output_buf.items);
        if (output_buf.items[output_buf.items.len - 1] != '\n') {
            try IO.print("\n", .{});
        }
    }

    // Print stderr if curl reported an error
    if (exit_code != 0) {
        if (stderr_buf.items.len > 0) {
            const trimmed = std.mem.trim(u8, stderr_buf.items, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                try IO.eprint("http: curl error: {s}\n", .{trimmed});
            }
        }
    }

    return exit_code;
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
