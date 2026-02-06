const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;
const networking = @import("networking.zig");

/// Apply I/O redirections for a command.
/// Handles output/append, input, heredoc, herestring, fd duplication, and fd close.
pub fn applyRedirections(
    allocator: std.mem.Allocator,
    redirections: []types.Redirection,
    environment: *std.StringHashMap([]const u8),
    expansion_context: ?ExpansionContext,
) !void {
    for (redirections) |redir| {
        switch (redir.kind) {
            .output_truncate => try applyOutputTruncate(allocator, redir),
            .output_append => try applyOutputAppend(allocator, redir),
            .input => try applyInput(allocator, redir),
            .input_output => try applyInputOutput(allocator, redir),
            .heredoc, .herestring => try applyHeredocOrHerestring(allocator, redir, environment, expansion_context),
            .fd_duplicate => try applyFdDuplicate(redir),
            .fd_close => applyFdClose(redir),
        }
    }
}

/// Context for variable expansion in heredocs/herestrings
pub const ExpansionContext = struct {
    option_nounset: bool,
    var_attributes: *std.StringHashMap(types.VarAttributes),
    arrays: *std.StringHashMap([][]const u8),
    assoc_arrays: *std.StringHashMap(std.StringHashMap([]const u8)),
};

fn applyOutputTruncate(allocator: std.mem.Allocator, redir: types.Redirection) !void {
    // Check for /dev/tcp or /dev/udp virtual path
    if (networking.openDevNet(redir.target)) |sock| {
        if (std.c.dup2(sock, @intCast(redir.fd)) < 0) return error.Unexpected;
        std.posix.close(sock);
    } else {
        // Open file for writing, truncate if exists
        const path_z = try allocator.dupeZ(u8, redir.target);
        defer allocator.free(path_z);

        const fd = std.c.open(
            path_z,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            @as(std.c.mode_t, 0o644),
        );
        if (fd < 0) {
            try IO.eprint("den: {s}: cannot open\n", .{redir.target});
            std.c._exit(1);
        }

        if (std.c.dup2(fd, @intCast(redir.fd)) < 0) return error.Unexpected;
        std.posix.close(fd);
    }
}

fn applyOutputAppend(allocator: std.mem.Allocator, redir: types.Redirection) !void {
    // Check for /dev/tcp or /dev/udp virtual path
    if (networking.openDevNet(redir.target)) |sock| {
        if (std.c.dup2(sock, @intCast(redir.fd)) < 0) return error.Unexpected;
        std.posix.close(sock);
    } else {
        // Open file for appending
        const path_z = try allocator.dupeZ(u8, redir.target);
        defer allocator.free(path_z);

        const fd = std.c.open(
            path_z,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            @as(std.c.mode_t, 0o644),
        );
        if (fd < 0) {
            try IO.eprint("den: {s}: cannot open\n", .{redir.target});
            std.c._exit(1);
        }

        if (std.c.dup2(fd, @intCast(redir.fd)) < 0) return error.Unexpected;
        std.posix.close(fd);
    }
}

fn applyInput(allocator: std.mem.Allocator, redir: types.Redirection) !void {
    // Check for /dev/tcp or /dev/udp virtual path
    if (networking.openDevNet(redir.target)) |sock| {
        if (std.c.dup2(sock, std.posix.STDIN_FILENO) < 0) return error.Unexpected;
        std.posix.close(sock);
    } else {
        // Open file for reading
        const path_z = try allocator.dupeZ(u8, redir.target);
        defer allocator.free(path_z);

        const fd = std.c.open(
            path_z,
            .{ .ACCMODE = .RDONLY },
            @as(std.c.mode_t, 0),
        );
        if (fd < 0) {
            try IO.eprint("den: {s}: cannot open\n", .{redir.target});
            std.c._exit(1);
        }

        if (std.c.dup2(fd, std.posix.STDIN_FILENO) < 0) return error.Unexpected;
        std.posix.close(fd);
    }
}

fn applyInputOutput(allocator: std.mem.Allocator, redir: types.Redirection) !void {
    // <> opens file for both reading and writing
    if (networking.openDevNet(redir.target)) |sock| {
        if (std.c.dup2(sock, @intCast(redir.fd)) < 0) return error.Unexpected;
        std.posix.close(sock);
    } else {
        const path_z = try allocator.dupeZ(u8, redir.target);
        defer allocator.free(path_z);

        // Open for read+write, create if doesn't exist
        const fd = std.c.open(
            path_z,
            .{ .ACCMODE = .RDWR, .CREAT = true },
            @as(std.c.mode_t, 0o644),
        );
        if (fd < 0) {
            try IO.eprint("den: {s}: cannot open\n", .{redir.target});
            std.c._exit(1);
        }

        if (std.c.dup2(fd, @intCast(redir.fd)) < 0) return error.Unexpected;
        std.posix.close(fd);
    }
}

fn applyHeredocOrHerestring(
    allocator: std.mem.Allocator,
    redir: types.Redirection,
    environment: *std.StringHashMap([]const u8),
    expansion_context: ?ExpansionContext,
) !void {
    // Create a pipe for the content
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    // Write content to pipe
    const content = blk: {
        if (redir.kind == .herestring) {
            // For herestring, expand variables and use the content
            var expansion = Expansion.init(allocator, environment, 0);
            // Set options from context if available
            if (expansion_context) |ctx| {
                expansion.option_nounset = ctx.option_nounset;
                expansion.var_attributes = ctx.var_attributes;
                expansion.arrays = ctx.arrays;
                expansion.assoc_arrays = ctx.assoc_arrays;
            }
            const expanded = expansion.expand(redir.target) catch redir.target;
            // Add newline for herestring
            var buf: [4096]u8 = undefined;
            const with_newline = std.fmt.bufPrint(&buf, "{s}\n", .{expanded}) catch redir.target;
            if (expanded.ptr != redir.target.ptr) {
                allocator.free(expanded);
            }
            break :blk try allocator.dupe(u8, with_newline);
        } else {
            // For heredoc, use the target as-is (it contains the content)
            // Note: Full heredoc support requires parser changes
            // This provides basic support for single-line heredocs
            break :blk try allocator.dupe(u8, redir.target);
        }
    };
    defer allocator.free(content);

    // Fork to write content (avoid blocking)
    const fork_ret = std.c.fork();
    if (fork_ret < 0) return error.Unexpected;
    const writer_pid: std.posix.pid_t = @intCast(fork_ret);
    if (writer_pid == 0) {
        // Child: write content and exit
        std.posix.close(read_fd);
        (std.Io.File{ .handle = write_fd, .flags = .{ .nonblocking = false } }).writeStreamingAll(std.Options.debug_io, content) catch {};
        std.posix.close(write_fd);
        std.c._exit(0);
    }

    // Parent: close write end and dup read end to stdin
    std.posix.close(write_fd);
    if (std.c.dup2(read_fd, std.posix.STDIN_FILENO) < 0) return error.Unexpected;
    std.posix.close(read_fd);

    // Wait for writer to finish
    {
        var wait_status: c_int = 0;
        _ = std.c.waitpid(writer_pid, &wait_status, 0);
    }
}

fn applyFdDuplicate(redir: types.Redirection) !void {
    // Parse target as file descriptor number
    // Format: N>&M or N<&M (duplicate fd M to fd N)
    const target_fd = std.fmt.parseInt(u32, redir.target, 10) catch {
        try IO.eprint("den: invalid file descriptor: {s}\n", .{redir.target});
        return error.InvalidFd;
    };

    // Duplicate the target_fd to redir.fd
    if (std.c.dup2(@intCast(target_fd), @intCast(redir.fd)) < 0) return error.Unexpected;
}

fn applyFdClose(redir: types.Redirection) void {
    // Close the specified file descriptor
    // Format: N>&- or N<&- (close fd N)
    std.posix.close(@intCast(redir.fd));
}

/// Save current stdout and stderr file descriptors (for Windows builtin redirections)
pub const SavedFds = struct {
    stdout_save: ?std.posix.fd_t = null,
    stderr_save: ?std.posix.fd_t = null,

    pub fn save() SavedFds {
        var saved = SavedFds{};

        // Duplicate stdout and stderr
        saved.stdout_save = std.posix.dup(std.posix.STDOUT_FILENO) catch null;
        saved.stderr_save = std.posix.dup(std.posix.STDERR_FILENO) catch null;

        return saved;
    }

    pub fn restore(self: *SavedFds) void {
        // Restore stdout
        if (self.stdout_save) |fd| {
            _ = std.c.dup2(fd, std.posix.STDOUT_FILENO);
            std.posix.close(fd);
            self.stdout_save = null;
        }

        // Restore stderr
        if (self.stderr_save) |fd| {
            _ = std.c.dup2(fd, std.posix.STDERR_FILENO);
            std.posix.close(fd);
            self.stderr_save = null;
        }
    }
};

// Tests
test "apply fd close" {
    // Just a simple test to verify the module compiles
    const redir = types.Redirection{
        .kind = .fd_close,
        .fd = 99, // Non-existent fd, but that's okay for this test
        .target = "",
    };
    applyFdClose(redir);
}
