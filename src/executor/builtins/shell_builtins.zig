const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;

/// Shell builtins that require shell state access
/// Includes: cd, pwd, read, source, history

pub fn cd(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    var path = if (command.args.len > 0) command.args[0] else blk: {
        if (ctx.getEnv("HOME")) |home| {
            break :blk home;
        }
        try IO.eprint("den: cd: HOME not set\n", .{});
        return 1;
    };

    // Handle special cd - (go to OLDPWD)
    if (std.mem.eql(u8, path, "-")) {
        if (ctx.getEnv("OLDPWD")) |oldpwd| {
            path = oldpwd;
            try IO.print("{s}\n", .{path});
        } else {
            try IO.eprint("den: cd: OLDPWD not set\n", .{});
            return 1;
        }
    }

    // Expand ~name for named directories (zsh-style)
    var expanded_path: ?[]const u8 = null;
    defer if (expanded_path) |p| ctx.allocator.free(p);

    if (path.len > 0 and path[0] == '~') {
        if (ctx.hasShell()) {
            if (path.len > 1 and path[1] != '/') {
                const shell_ref = ctx.getShell() catch unreachable;
                const name_end = std.mem.indexOfAny(u8, path[1..], &[_]u8{'/'}) orelse path.len - 1;
                const name = path[1 .. name_end + 1];

                if (shell_ref.named_dirs.get(name)) |named_path| {
                    if (name_end + 1 < path.len) {
                        expanded_path = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ named_path, path[name_end + 1 ..] });
                        path = expanded_path.?;
                    } else {
                        path = named_path;
                    }
                }
            }
        }
    }

    // Save current directory as OLDPWD before changing
    var old_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const old_cwd = blk: {
        const result = std.c.getcwd(&old_cwd_buf, old_cwd_buf.len) orelse break :blk null;
        break :blk @as(?[]u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(result)), 0));
    };

    // Check if path is relative (doesn't start with / or ~ or .)
    const is_relative = path.len > 0 and path[0] != '/' and path[0] != '~' and path[0] != '.';

    // Try direct path first
    const chdir_result = blk: {
        var path_z_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;
        break :blk std.c.chdir(path_z_buf[0..path.len :0]);
    };
    if (chdir_result == 0) {
        if (old_cwd) |cwd| {
            try ctx.setEnv("OLDPWD", cwd);
        }
        return 0;
    } else {
        // If relative path and CDPATH is set, try CDPATH directories
        if (is_relative) {
            if (ctx.getEnv("CDPATH")) |cdpath| {
                var cdpath_path: ?[]const u8 = null;
                defer if (cdpath_path) |p| ctx.allocator.free(p);

                var iter = std.mem.splitScalar(u8, cdpath, ':');
                while (iter.next()) |dir| {
                    const full_path = if (dir.len == 0)
                        path
                    else blk: {
                        if (cdpath_path) |p| ctx.allocator.free(p);
                        cdpath_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ dir, path });
                        break :blk cdpath_path.?;
                    };

                    const cdpath_chdir_result = inner_blk: {
                        var fp_z_buf: [std.fs.max_path_bytes]u8 = undefined;
                        @memcpy(fp_z_buf[0..full_path.len], full_path);
                        fp_z_buf[full_path.len] = 0;
                        break :inner_blk std.c.chdir(fp_z_buf[0..full_path.len :0]);
                    };
                    if (cdpath_chdir_result == 0) {
                        try IO.print("{s}\n", .{full_path});
                        if (old_cwd) |cwd| {
                            try ctx.setEnv("OLDPWD", cwd);
                        }
                        return 0;
                    } else {
                        continue;
                    }
                }
            }
        }

        try IO.eprint("den: cd: {s}: No such file or directory\n", .{path});
        return 1;
    }
}

pub fn pwd(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // Parse flags
    var use_physical = false;
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "-P")) {
            use_physical = true;
        } else if (std.mem.eql(u8, arg, "-L")) {
            use_physical = false;
        }
    }

    if (use_physical) {
        const cwd = blk: {
            const result = std.c.getcwd(&buf, buf.len) orelse {
                try IO.eprint("den: pwd: error getting current directory: {}\n", .{error.Unexpected});
                return 1;
            };
            break :blk std.mem.sliceTo(@as([*:0]u8, @ptrCast(result)), 0);
        };
        try IO.print("{s}\n", .{cwd});
    } else {
        // -L: Logical path (default) - use PWD env var if set and valid
        if (ctx.getEnv("PWD")) |pwd_val| {
            var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const real_cwd = blk: {
                const result = std.c.getcwd(&real_buf, real_buf.len) orelse break :blk null;
                break :blk @as(?[]u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(result)), 0));
            };

            if (real_cwd) |_| {
                try IO.print("{s}\n", .{pwd_val});
                return 0;
            }
        }
        // Fallback to physical path if PWD not set or invalid
        const cwd = blk: {
            const result = std.c.getcwd(&buf, buf.len) orelse {
                try IO.eprint("den: pwd: error getting current directory: {}\n", .{error.Unexpected});
                return 1;
            };
            break :blk std.mem.sliceTo(@as([*:0]u8, @ptrCast(result)), 0);
        };
        try IO.print("{s}\n", .{cwd});
    }
    return 0;
}

pub fn read(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // Parse options
    var prompt: ?[]const u8 = null;
    var raw_mode = false;
    var array_name: ?[]const u8 = null;
    var delimiter: u8 = '\n';
    var nchars: ?usize = null;
    var var_name_start: usize = 0;

    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (std.mem.eql(u8, arg, "-p")) {
                i += 1;
                if (i >= command.args.len) {
                    try IO.eprint("den: read: -p requires an argument\n", .{});
                    return 1;
                }
                prompt = command.args[i];
            } else if (std.mem.eql(u8, arg, "-r")) {
                raw_mode = true;
            } else if (std.mem.eql(u8, arg, "-a")) {
                i += 1;
                if (i >= command.args.len) {
                    try IO.eprint("den: read: -a requires an argument\n", .{});
                    return 1;
                }
                array_name = command.args[i];
            } else if (std.mem.eql(u8, arg, "-d")) {
                i += 1;
                if (i >= command.args.len) {
                    try IO.eprint("den: read: -d requires an argument\n", .{});
                    return 1;
                }
                delimiter = if (command.args[i].len > 0) command.args[i][0] else 0;
            } else if (std.mem.eql(u8, arg, "-n")) {
                i += 1;
                if (i >= command.args.len) {
                    try IO.eprint("den: read: -n requires an argument\n", .{});
                    return 1;
                }
                nchars = std.fmt.parseInt(usize, command.args[i], 10) catch {
                    try IO.eprint("den: read: {s}: invalid number\n", .{command.args[i]});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "-s")) {
                // Silent mode - parse but not fully implemented
            } else if (std.mem.eql(u8, arg, "-t")) {
                // Timeout - parse argument but not fully implemented
                i += 1;
                if (i >= command.args.len) {
                    try IO.eprint("den: read: -t requires an argument\n", .{});
                    return 1;
                }
                _ = std.fmt.parseFloat(f64, command.args[i]) catch {
                    try IO.eprint("den: read: {s}: invalid timeout\n", .{command.args[i]});
                    return 1;
                };
            } else {
                try IO.eprint("den: read: invalid option: {s}\n", .{arg});
                return 1;
            }
        } else {
            var_name_start = i;
            break;
        }
    }

    const var_names = if (var_name_start < command.args.len)
        command.args[var_name_start..]
    else if (array_name == null)
        &[_][]const u8{"REPLY"}
    else
        &[_][]const u8{};

    if (prompt) |p| {
        try IO.writeBytes(p);
    }

    // Read input
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;

    if (nchars) |n| {
        var chars_read: usize = 0;
        while (chars_read < n and chars_read < line_buf.len) {
            var byte_buf: [1]u8 = undefined;
            const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &byte_buf) catch break;
            if (bytes_read == 0) break;
            line_buf[chars_read] = byte_buf[0];
            chars_read += 1;
        }
        line_len = chars_read;
    } else if (delimiter != '\n') {
        while (line_len < line_buf.len) {
            var byte_buf: [1]u8 = undefined;
            const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &byte_buf) catch break;
            if (bytes_read == 0) break;
            if (byte_buf[0] == delimiter) break;
            line_buf[line_len] = byte_buf[0];
            line_len += 1;
        }
    } else {
        const line_opt = try IO.readLine(ctx.allocator);
        if (line_opt) |line| {
            defer ctx.allocator.free(line);
            const copy_len = @min(line.len, line_buf.len);
            @memcpy(line_buf[0..copy_len], line[0..copy_len]);
            line_len = copy_len;
        } else {
            // EOF
            if (array_name) |arr_name| {
                _ = ctx.removeArray(arr_name);
            } else {
                for (var_names) |var_name| {
                    try ctx.setEnv(var_name, "");
                }
            }
            return 1;
        }
    }

    const line = line_buf[0..line_len];

    // Process line (handle backslash escapes unless -r)
    var processed_line: []const u8 = line;
    var processed_buf: [4096]u8 = undefined;

    if (!raw_mode) {
        var pos: usize = 0;
        var j: usize = 0;
        while (j < line.len and pos < processed_buf.len) {
            if (line[j] == '\\' and j + 1 < line.len) {
                j += 1;
                processed_buf[pos] = line[j];
            } else {
                processed_buf[pos] = line[j];
            }
            j += 1;
            pos += 1;
        }
        processed_line = processed_buf[0..pos];
    }

    // Handle -a (array) mode
    if (array_name) |arr_name| {
        var words = std.ArrayList([]const u8).empty;
        defer words.deinit(ctx.allocator);

        var word_iter = std.mem.tokenizeAny(u8, processed_line, " \t");
        while (word_iter.next()) |word| {
            try words.append(ctx.allocator, try ctx.allocator.dupe(u8, word));
        }

        const arr_slice = try words.toOwnedSlice(ctx.allocator);
        try ctx.setArray(arr_name, arr_slice);

        return 0;
    }

    // Split by IFS if multiple variable names
    if (var_names.len == 1) {
        try ctx.setEnv(var_names[0], processed_line);
    } else {
        var word_iter = std.mem.tokenizeAny(u8, processed_line, " \t");
        var var_idx: usize = 0;

        while (var_idx < var_names.len) : (var_idx += 1) {
            const var_name = var_names[var_idx];
            var value: []const u8 = "";

            if (var_idx == var_names.len - 1) {
                if (word_iter.next()) |first_word| {
                    const rest_start = @intFromPtr(first_word.ptr) - @intFromPtr(processed_line.ptr);
                    value = processed_line[rest_start..];
                }
            } else {
                if (word_iter.next()) |word| {
                    value = word;
                }
            }

            try ctx.setEnv(var_name, value);
        }
    }

    return 0;
}

pub fn source(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: source: missing filename\n", .{});
        return 1;
    }

    const filename = command.args[0];
    const script_args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{};

    const result = ctx.executeScript(filename, script_args) catch |err| {
        try IO.eprint("den: source: error executing {s}: {}\n", .{ filename, err });
        return 1;
    };

    return result.exit_code;
}

pub fn history(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // Parse optional count argument
    var count: ?usize = null;
    if (command.args.len > 0) {
        count = std.fmt.parseInt(usize, command.args[0], 10) catch {
            try IO.eprint("den: history: invalid number: {s}\n", .{command.args[0]});
            return 1;
        };
    }

    const history_count = ctx.historyCount();
    const start_idx = if (count) |c|
        if (c < history_count) history_count - c else 0
    else
        0;

    var idx = start_idx;
    while (idx < history_count) : (idx += 1) {
        if (ctx.getHistoryAt(idx)) |entry| {
            try IO.print("  {d}  {s}\n", .{ idx + 1, entry });
        }
    }

    return 0;
}
