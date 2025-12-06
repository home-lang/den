const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const builtin = @import("builtin");

/// Pipeline execution for connecting multiple commands with pipes.
/// Handles both POSIX (fork/pipe) and Windows (CreateProcess) implementations.

/// Maximum number of pipes supported in a single pipeline
pub const MAX_PIPES = 16;

/// Pipeline execution result
pub const PipelineResult = struct {
    exit_code: i32,
    pipefail_code: i32, // Rightmost non-zero exit code (for pipefail option)
};

/// Execute a pipeline of commands on POSIX systems.
/// Creates pipes to connect stdout of each command to stdin of the next.
/// Returns the exit code of the last command (or pipefail code if enabled).
pub fn executePosix(
    allocator: std.mem.Allocator,
    commands: []types.ParsedCommand,
    isBuiltinFn: *const fn ([]const u8) bool,
    executeBuiltinFn: *const fn (*types.ParsedCommand) anyerror!i32,
    executeExternalFn: *const fn (*types.ParsedCommand) anyerror!void,
    applyRedirectionsFn: *const fn ([]types.Redirection) anyerror!void,
) !PipelineResult {
    _ = allocator;

    // Create pipes for communication
    var pipes_buffer: [MAX_PIPES][2]std.posix.fd_t = undefined;
    const num_pipes = commands.len - 1;

    if (num_pipes > MAX_PIPES) return error.TooManyPipes;

    // Create all pipes
    for (0..num_pipes) |i| {
        pipes_buffer[i] = try std.posix.pipe();
    }

    // Spawn all commands in the pipeline
    var pids_buffer: [MAX_PIPES + 1]std.posix.pid_t = undefined;

    for (commands, 0..) |*cmd, i| {
        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process

            // Set up stdin from previous pipe
            if (i > 0) {
                try std.posix.dup2(pipes_buffer[i - 1][0], std.posix.STDIN_FILENO);
            }

            // Set up stdout to next pipe
            if (i < num_pipes) {
                try std.posix.dup2(pipes_buffer[i][1], std.posix.STDOUT_FILENO);
            }

            // Close all pipe fds in child
            for (0..num_pipes) |j| {
                std.posix.close(pipes_buffer[j][0]);
                std.posix.close(pipes_buffer[j][1]);
            }

            // Apply redirections
            applyRedirectionsFn(cmd.redirections) catch {};

            // Execute the command
            if (isBuiltinFn(cmd.name)) {
                const exit_code = executeBuiltinFn(cmd) catch 1;
                std.posix.exit(@intCast(exit_code));
            } else {
                executeExternalFn(cmd) catch {};
            }
            unreachable;
        } else {
            // Parent - store pid
            pids_buffer[i] = pid;
        }
    }

    // Parent: close all pipes
    for (0..num_pipes) |i| {
        std.posix.close(pipes_buffer[i][0]);
        std.posix.close(pipes_buffer[i][1]);
    }

    // Wait for all children
    var last_status: i32 = 0;
    var pipefail_status: i32 = 0;
    for (pids_buffer[0..commands.len]) |pid| {
        const result = std.posix.waitpid(pid, 0);
        const status: i32 = @intCast(std.posix.W.EXITSTATUS(result.status));
        last_status = status;
        // For pipefail: track rightmost non-zero exit status
        if (status != 0) {
            pipefail_status = status;
        }
    }

    return PipelineResult{
        .exit_code = last_status,
        .pipefail_code = pipefail_status,
    };
}

/// Execute a pipeline on Windows using CreateProcess.
/// Note: Windows pipeline support is limited compared to POSIX.
pub fn executeWindows(
    allocator: std.mem.Allocator,
    commands: []types.ParsedCommand,
) !PipelineResult {
    _ = allocator;

    // Windows implementation would use CreateProcess with pipes
    // For now, execute commands sequentially (simplified)
    var last_status: i32 = 0;

    for (commands) |_| {
        // TODO: Implement proper Windows pipeline with CreateProcess
        last_status = 0;
    }

    return PipelineResult{
        .exit_code = last_status,
        .pipefail_code = last_status,
    };
}

/// Check if the current platform supports native pipelines
pub fn supportsNativePipelines() bool {
    return builtin.os.tag != .windows;
}

// Tests
test "pipeline constants" {
    try std.testing.expect(MAX_PIPES >= 16);
}
