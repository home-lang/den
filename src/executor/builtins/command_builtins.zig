const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;
const utils = @import("../../utils.zig");

/// Command lookup and hash builtins: which, type, hash

/// which - locate a command
pub fn which(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: which: missing argument\n", .{});
        return 1;
    }

    var found_all = true;
    var show_all = false;
    var arg_start: usize = 0;

    // Parse flags
    for (command.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => show_all = true,
                    else => {},
                }
            }
            arg_start = i + 1;
        } else {
            break;
        }
    }

    if (arg_start >= command.args.len) {
        try IO.eprint("den: which: missing argument\n", .{});
        return 1;
    }

    for (command.args[arg_start..]) |cmd_name| {
        // Check if it's a builtin
        if (ctx.isBuiltin(cmd_name)) {
            try IO.print("{s}: shell builtin command\n", .{cmd_name});
            if (!show_all) continue;
        }

        // Parse PATH and find executable
        var path_list = utils.env.PathList.fromEnv(ctx.allocator) catch {
            try IO.eprint("den: which: failed to parse PATH\n", .{});
            return 1;
        };
        defer path_list.deinit();

        if (show_all) {
            // Find all matches
            const all_paths = try path_list.findAllExecutables(ctx.allocator, cmd_name);
            defer {
                for (all_paths) |p| ctx.allocator.free(p);
                ctx.allocator.free(all_paths);
            }

            if (all_paths.len == 0 and !ctx.isBuiltin(cmd_name)) {
                found_all = false;
            } else {
                for (all_paths) |exec_path| {
                    try IO.print("{s}\n", .{exec_path});
                }
            }
        } else {
            // Find first match only
            if (try path_list.findExecutable(ctx.allocator, cmd_name)) |exec_path| {
                defer ctx.allocator.free(exec_path);
                try IO.print("{s}\n", .{exec_path});
            } else {
                found_all = false;
            }
        }
    }

    return if (found_all) 0 else 1;
}

/// type - display command type
pub fn typeBuiltin(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: type: missing argument\n", .{});
        return 1;
    }

    // Parse flags
    var show_all = false;
    var type_only = false;
    var path_only = false;
    var arg_start: usize = 0;

    for (command.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => show_all = true,
                    't' => type_only = true,
                    'p' => path_only = true,
                    else => {
                        try IO.eprint("den: type: -{c}: invalid option\n", .{c});
                        return 1;
                    },
                }
            }
            arg_start = i + 1;
        } else {
            break;
        }
    }

    if (arg_start >= command.args.len) {
        try IO.eprint("den: type: missing argument\n", .{});
        return 1;
    }

    var found_all = true;

    for (command.args[arg_start..]) |cmd_name| {
        var found_any = false;

        // Check if it's a builtin
        if (ctx.isBuiltin(cmd_name)) {
            found_any = true;
            if (type_only) {
                try IO.print("builtin\n", .{});
            } else if (!path_only) {
                try IO.print("{s} is a shell builtin\n", .{cmd_name});
            }
            if (!show_all) continue;
        }

        // Check if it's in PATH
        var path_list = utils.env.PathList.fromEnv(ctx.allocator) catch {
            try IO.eprint("den: type: failed to parse PATH\n", .{});
            return 1;
        };
        defer path_list.deinit();

        if (show_all) {
            // Show all matches in PATH
            for (path_list.paths.items) |path_dir| {
                const full_path = std.fs.path.join(ctx.allocator, &[_][]const u8{ path_dir, cmd_name }) catch continue;
                defer ctx.allocator.free(full_path);

                // Check if file exists and is executable
                std.fs.accessAbsolute(full_path, .{}) catch continue;

                if (builtin.os.tag != .windows) {
                    const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;
                    defer file.close();
                    const stat = file.stat() catch continue;
                    if (stat.mode & 0o111 == 0) continue;
                }

                found_any = true;
                if (type_only) {
                    try IO.print("file\n", .{});
                } else if (path_only) {
                    try IO.print("{s}\n", .{full_path});
                } else {
                    try IO.print("{s} is {s}\n", .{ cmd_name, full_path });
                }
            }
        } else {
            // Just find first match
            if (try path_list.findExecutable(ctx.allocator, cmd_name)) |exec_path| {
                defer ctx.allocator.free(exec_path);
                found_any = true;
                if (type_only) {
                    try IO.print("file\n", .{});
                } else if (path_only) {
                    try IO.print("{s}\n", .{exec_path});
                } else {
                    try IO.print("{s} is {s}\n", .{ cmd_name, exec_path });
                }
            }
        }

        if (!found_any) {
            if (!type_only and !path_only) {
                try IO.print("den: type: {s}: not found\n", .{cmd_name});
            }
            found_all = false;
        }
    }

    return if (found_all) 0 else 1;
}

/// hash - command hash table management
pub fn hash(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // hash with no args - list all cached paths
    if (command.args.len == 0) {
        if (ctx.commandCacheIterator()) |iter_val| {
            var iter = iter_val;
            var has_entries = false;
            while (iter.next()) |entry| {
                try IO.print("{s}\t{s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                has_entries = true;
            }
            if (!has_entries) {
                try IO.print("hash: hash table empty\n", .{});
            }
        } else {
            try IO.eprint("den: hash: shell context not available\n", .{});
            return 1;
        }
        return 0;
    }

    // Parse flags
    var arg_idx: usize = 0;
    while (arg_idx < command.args.len) {
        const arg = command.args[arg_idx];

        // hash -r - clear hash table
        if (std.mem.eql(u8, arg, "-r")) {
            ctx.clearCommandCache();
            arg_idx += 1;
            continue;
        }

        // hash -l - list in reusable format
        if (std.mem.eql(u8, arg, "-l")) {
            if (ctx.commandCacheIterator()) |iter_val| {
                var iter = iter_val;
                while (iter.next()) |entry| {
                    try IO.print("builtin hash -p {s} {s}\n", .{ entry.value_ptr.*, entry.key_ptr.* });
                }
            }
            return 0;
        }

        // hash -d name - delete specific entry
        if (std.mem.eql(u8, arg, "-d")) {
            if (arg_idx + 1 >= command.args.len) {
                try IO.eprint("den: hash: -d: option requires an argument\n", .{});
                return 1;
            }
            const name = command.args[arg_idx + 1];
            if (!ctx.removeCommandCache(name)) {
                try IO.eprint("den: hash: {s}: not found\n", .{name});
                return 1;
            }
            arg_idx += 2;
            continue;
        }

        // hash -p path name - add specific path for name
        if (std.mem.eql(u8, arg, "-p")) {
            if (arg_idx + 2 >= command.args.len) {
                try IO.eprint("den: hash: -p: option requires path and name arguments\n", .{});
                return 1;
            }
            const path = command.args[arg_idx + 1];
            const name = command.args[arg_idx + 2];

            // Remove old entry if exists, then add new
            _ = ctx.removeCommandCache(name);
            try ctx.setCommandCache(name, path);
            arg_idx += 3;
            continue;
        }

        // hash -t name... - print cached path for name
        if (std.mem.eql(u8, arg, "-t")) {
            if (arg_idx + 1 >= command.args.len) {
                try IO.eprint("den: hash: -t: option requires an argument\n", .{});
                return 1;
            }
            var found_all_t = true;
            for (command.args[arg_idx + 1 ..]) |name| {
                if (ctx.getCommandCache(name)) |path| {
                    try IO.print("{s}\n", .{path});
                } else {
                    try IO.eprint("den: hash: {s}: not found\n", .{name});
                    found_all_t = false;
                }
            }
            return if (found_all_t) 0 else 1;
        }

        // Not a flag, must be command name(s) to hash
        break;
    }

    // If we only had -r flag with no commands, we're done
    if (arg_idx >= command.args.len) {
        return 0;
    }

    // hash command [command...] - add commands to hash table
    const path_var = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var path_list = utils.env.PathList.parse(ctx.allocator, path_var) catch {
        return 1;
    };
    defer path_list.deinit();

    for (command.args[arg_idx..]) |cmd_name| {
        if (try path_list.findExecutable(ctx.allocator, cmd_name)) |exec_path| {
            // Remove old entry if exists, then add new
            _ = ctx.removeCommandCache(cmd_name);
            // exec_path is already owned, transfer ownership to cache
            const key = try ctx.allocator.dupe(u8, cmd_name);
            const shell_ref = ctx.shell orelse return error.NoShellContext;
            try shell_ref.command_cache.put(key, exec_path);
        } else {
            try IO.eprint("den: hash: {s}: not found\n", .{cmd_name});
            return 1;
        }
    }

    return 0;
}
