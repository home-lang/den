const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;

/// State management builtins: trap, bookmark

/// trap - set signal handlers
pub fn trap(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // If no arguments, list all traps
    if (command.args.len == 0) {
        if (ctx.signalHandlersIterator()) |iter_val| {
            var iter = iter_val;
            while (iter.next()) |entry| {
                const signal = entry.key_ptr.*;
                const action = entry.value_ptr.*;
                if (action.len > 0) {
                    try IO.print("trap -- '{s}' {s}\n", .{ action, signal });
                } else {
                    try IO.print("trap -- '' {s}\n", .{signal});
                }
            }
        } else {
            try IO.eprint("den: trap: shell context not available\n", .{});
            return 1;
        }
        return 0;
    }

    var start_idx: usize = 0;

    // Skip '--' if present (POSIX compatibility)
    if (std.mem.eql(u8, command.args[0], "--")) {
        start_idx = 1;
        if (command.args.len == 1) {
            try IO.eprint("den: trap: usage: trap [-lp] [[arg] signal_spec ...]\n", .{});
            return 1;
        }
    }

    // Handle -l flag (list signal names)
    if (std.mem.eql(u8, command.args[start_idx], "-l") or std.mem.eql(u8, command.args[start_idx], "--list")) {
        const signal_names = [_][]const u8{
            "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE",
            "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM",
            "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG",
            "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "SYS",
        };
        for (signal_names, 0..) |sig, i| {
            try IO.print("{d}) {s}\n", .{ i + 1, sig });
        }
        return 0;
    }

    // Handle -p flag (print trap commands)
    if (std.mem.eql(u8, command.args[start_idx], "-p") or std.mem.eql(u8, command.args[start_idx], "--print")) {
        if (command.args.len <= start_idx + 1) {
            return 0;
        }
        for (command.args[start_idx + 1 ..]) |signal| {
            if (ctx.getSignalHandler(signal)) |action| {
                try IO.print("trap -- '{s}' {s}\n", .{ action, signal });
            }
        }
        return 0;
    }

    // Need at least 2 args: action and signal
    if (command.args.len < start_idx + 2) {
        try IO.eprint("den: trap: usage: trap [-lp] [[arg] signal_spec ...]\n", .{});
        return 1;
    }

    const action = command.args[start_idx];
    const signals = command.args[start_idx + 1 ..];

    // Handle empty string action - remove the trap
    if (action.len == 0) {
        for (signals) |signal| {
            _ = ctx.removeSignalHandler(signal);
        }
        return 0;
    }

    // Handle '-' action - reset to default handler
    if (std.mem.eql(u8, action, "-")) {
        for (signals) |signal| {
            _ = ctx.removeSignalHandler(signal);
            try ctx.setSignalHandler(signal, "");
        }
        return 0;
    }

    // Set up the trap
    for (signals) |signal| {
        _ = ctx.removeSignalHandler(signal);
        try ctx.setSignalHandler(signal, action);
    }

    return 0;
}

/// bookmark - manage directory bookmarks
pub fn bookmark(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // bookmark         - list all bookmarks
    // bookmark name    - cd to bookmark
    // bookmark -a name - add current dir as bookmark
    // bookmark -d name - delete bookmark

    if (command.args.len == 0) {
        // List all bookmarks
        if (ctx.namedDirsIterator()) |iter_val| {
            var iter = iter_val;
            var count: usize = 0;
            while (iter.next()) |entry| {
                try IO.print("{s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                count += 1;
            }
            if (count == 0) {
                try IO.print("No bookmarks set. Use 'bookmark -a name' to add one.\n", .{});
            }
        } else {
            try IO.eprint("den: bookmark: shell not available\n", .{});
            return 1;
        }
        return 0;
    }

    const first_arg = command.args[0];

    if (std.mem.eql(u8, first_arg, "-a")) {
        // Add bookmark
        if (command.args.len < 2) {
            try IO.eprint("den: bookmark: -a requires a name\n", .{});
            return 1;
        }
        const name = command.args[1];

        // Get current directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch {
            try IO.eprint("den: bookmark: failed to get current directory\n", .{});
            return 1;
        };

        try ctx.setNamedDir(name, cwd);
        try IO.print("Bookmark '{s}' -> {s}\n", .{ name, cwd });
        return 0;
    }

    if (std.mem.eql(u8, first_arg, "-d")) {
        // Delete bookmark
        if (command.args.len < 2) {
            try IO.eprint("den: bookmark: -d requires a name\n", .{});
            return 1;
        }
        const name = command.args[1];

        if (ctx.removeNamedDir(name)) {
            try IO.print("Bookmark '{s}' removed\n", .{name});
        } else {
            try IO.eprint("den: bookmark: '{s}' not found\n", .{name});
            return 1;
        }
        return 0;
    }

    // No flag - cd to bookmark
    const name = first_arg;

    if (ctx.getNamedDir(name)) |path| {
        std.posix.chdir(path) catch |err| {
            try IO.eprint("den: bookmark: {s}: {}\n", .{ path, err });
            return 1;
        };
        try IO.print("{s}\n", .{path});
    } else {
        try IO.eprint("den: bookmark: '{s}' not found\n", .{name});
        return 1;
    }

    return 0;
}

/// reload - reload shell configuration
pub fn reload(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // Check for --help
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try IO.print("reload - reload shell configuration\n", .{});
            try IO.print("Usage: reload [options]\n\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -h, --help    Show this help message\n", .{});
            try IO.print("  -v, --verbose Show what is being reloaded\n\n", .{});
            try IO.print("Reloads aliases, environment variables, and other settings\n", .{});
            try IO.print("from the shell configuration file.\n", .{});
            return 0;
        }
    }

    var verbose = false;
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    if (verbose) {
        try IO.print("Reloading shell configuration...\n", .{});
    }

    ctx.reloadShell() catch |err| {
        if (err == error.NoShellContext) {
            try IO.eprint("den: reload: shell context not available\n", .{});
            return 1;
        }
        try IO.eprint("den: reload: failed to reload configuration: {}\n", .{err});
        return 1;
    };

    if (verbose) {
        try IO.print("Configuration reloaded successfully.\n", .{});
    }

    return 0;
}
