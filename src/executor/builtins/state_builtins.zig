const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;
const plugins = @import("../../plugins/interface.zig");

/// State management builtins: trap, bookmark, hook

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
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd = blk: {
            const result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse {
                try IO.eprint("den: bookmark: failed to get current directory\n", .{});
                return 1;
            };
            break :blk std.mem.sliceTo(@as([*:0]u8, @ptrCast(result)), 0);
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
        {
            var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
            @memcpy(chdir_buf[0..path.len], path);
            chdir_buf[path.len] = 0;
            if (std.c.chdir(chdir_buf[0..path.len :0]) != 0) {
                try IO.eprint("den: bookmark: {s}: cannot change directory\n", .{path});
                return 1;
            }
        }
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

/// return - return from a function or sourced script
pub fn returnBuiltin(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // Parse return code (default 0)
    var return_code: i32 = 0;
    if (command.args.len > 0) {
        return_code = std.fmt.parseInt(i32, command.args[0], 10) catch {
            try IO.eprint("den: return: {s}: numeric argument required\n", .{command.args[0]});
            return 2;
        };
    }

    // Request return from current function
    ctx.requestFunctionReturn(return_code) catch {
        try IO.eprint("den: return: can only return from a function or sourced script\n", .{});
        return 1;
    };

    return return_code;
}

/// local - declare local variables in function scope
pub fn local(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        // List local variables
        if (ctx.getCurrentFrameLocals()) |locals| {
            var iter = locals.iterator();
            while (iter.next()) |entry| {
                try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
        return 0;
    }

    // Set local variables
    for (command.args) |arg| {
        // Parse name=value or just name
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const name = arg[0..eq_pos];
            const value = arg[eq_pos + 1 ..];
            ctx.setLocalVariable(name, value) catch {
                try IO.eprint("den: local: {s}: can only be used in a function\n", .{name});
                return 1;
            };
        } else {
            // Just declare as empty
            ctx.setLocalVariable(arg, "") catch {
                try IO.eprint("den: local: {s}: can only be used in a function\n", .{arg});
                return 1;
            };
        }
    }

    return 0;
}

/// getopts - parse positional parameters
pub fn getopts(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // getopts optstring name [args...]
    if (command.args.len < 2) {
        try IO.eprint("den: getopts: usage: getopts optstring name [args]\n", .{});
        return 2;
    }

    const optstring = command.args[0];
    const var_name = command.args[1];
    const params = if (command.args.len > 2) command.args[2..] else &[_][]const u8{};

    // Get OPTIND from environment (defaults to 1)
    const optind_str = ctx.environment.get("OPTIND") orelse "1";
    const optind = std.fmt.parseInt(usize, optind_str, 10) catch 1;

    // Check if we're past the end of params
    if (optind == 0 or optind > params.len) {
        try setEnvVar(ctx, "OPTARG", "");
        return 1;
    }

    const current = params[optind - 1];

    // Check if current param doesn't start with '-' or is just '-'
    if (current.len == 0 or current[0] != '-' or std.mem.eql(u8, current, "-")) {
        try setEnvVar(ctx, "OPTARG", "");
        return 1;
    }

    // Handle '--' (end of options)
    if (std.mem.eql(u8, current, "--")) {
        const new_optind = try std.fmt.allocPrint(ctx.allocator, "{d}", .{optind + 1});
        try setEnvVar(ctx, "OPTIND", new_optind);
        ctx.allocator.free(new_optind);
        try setEnvVar(ctx, "OPTARG", "");
        return 1;
    }

    // Extract the flag (first character after '-')
    if (current.len < 2) {
        try setEnvVar(ctx, "OPTARG", "");
        return 1;
    }

    const flag = current[1..2];

    // Check if this flag expects an argument (has ':' after it in optstring)
    var expects_arg = false;
    for (optstring, 0..) |c, i| {
        if (c == flag[0] and i + 1 < optstring.len and optstring[i + 1] == ':') {
            expects_arg = true;
            break;
        }
    }

    // Set the variable to the flag character
    try setEnvVar(ctx, var_name, flag);

    // Handle argument if needed
    if (expects_arg) {
        const arg_value = if (optind < params.len) params[optind] else "";
        try setEnvVar(ctx, "OPTARG", arg_value);
        const new_optind = try std.fmt.allocPrint(ctx.allocator, "{d}", .{optind + 2});
        try setEnvVar(ctx, "OPTIND", new_optind);
        ctx.allocator.free(new_optind);
    } else {
        try setEnvVar(ctx, "OPTARG", "");
        const new_optind = try std.fmt.allocPrint(ctx.allocator, "{d}", .{optind + 1});
        try setEnvVar(ctx, "OPTIND", new_optind);
        ctx.allocator.free(new_optind);
    }

    return 0;
}

/// Helper to safely set environment variable with proper key/value ownership
fn setEnvVar(ctx: *BuiltinContext, name: []const u8, value: []const u8) !void {
    const gop = try ctx.environment.getOrPut(name);
    if (gop.found_existing) {
        ctx.allocator.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try ctx.allocator.dupe(u8, name);
    }
    gop.value_ptr.* = try ctx.allocator.dupe(u8, value);
}

/// hook - manage custom command hooks
pub fn hook(cmd: *types.ParsedCommand) !i32 {
    // Static custom hook registry (persists across calls)
    const S = struct {
        var registry: ?plugins.CustomHookRegistry = null;
    };

    // Initialize registry on first use
    if (S.registry == null) {
        S.registry = plugins.CustomHookRegistry.init(std.heap.page_allocator);
    }
    var registry = &(S.registry.?);

    // No arguments - show help
    if (cmd.args.len == 0) {
        try IO.print("hook - manage custom command hooks\n", .{});
        try IO.print("Usage: hook <command> [args]\n", .{});
        try IO.print("\nCommands:\n", .{});
        try IO.print("  list                  List registered hooks\n", .{});
        try IO.print("  add <name> <pattern> <script>\n", .{});
        try IO.print("                        Register a hook\n", .{});
        try IO.print("  remove <name>         Remove a hook\n", .{});
        try IO.print("  enable <name>         Enable a hook\n", .{});
        try IO.print("  disable <name>        Disable a hook\n", .{});
        try IO.print("  test <command>        Test which hooks match\n", .{});
        try IO.print("\nExamples:\n", .{});
        try IO.print("  hook add git:push \"git push\" \"echo 'Pushing...'\"\n", .{});
        try IO.print("  hook add npm:install \"npm install\" \"echo 'Installing deps'\"\n", .{});
        try IO.print("  hook add docker:build \"docker build\" \"echo 'Building image'\"\n", .{});
        try IO.print("  hook list\n", .{});
        try IO.print("  hook test \"git push origin main\"\n", .{});
        return 0;
    }

    const subcmd = cmd.args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        const hooks = registry.list();
        if (hooks.len == 0) {
            try IO.print("\x1b[2mNo hooks registered\x1b[0m\n", .{});
            try IO.print("\nUse 'hook add <name> <pattern> <script>' to add a hook.\n", .{});
            return 0;
        }

        try IO.print("\x1b[1;36m=== Registered Hooks ===\x1b[0m\n\n", .{});
        for (hooks) |hk| {
            const status = if (hk.enabled) "\x1b[1;32m●\x1b[0m" else "\x1b[2m○\x1b[0m";
            try IO.print("{s} \x1b[1m{s}\x1b[0m\n", .{ status, hk.name });
            try IO.print("    Pattern: {s}\n", .{hk.pattern});
            if (hk.script) |script| {
                try IO.print("    Script:  {s}\n", .{script});
            }
            try IO.print("\n", .{});
        }
        return 0;
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (cmd.args.len < 4) {
            try IO.eprint("den: hook: add: usage: hook add <name> <pattern> <script>\n", .{});
            try IO.eprint("den: hook: add: example: hook add git:push \"git push\" \"echo 'Pushing...'\"\n", .{});
            return 1;
        }

        const name = cmd.args[1];
        const pattern = cmd.args[2];
        const script = cmd.args[3];

        registry.register(name, pattern, script, null, null, 0) catch |err| {
            try IO.eprint("den: hook: add: failed to register: {}\n", .{err});
            return 1;
        };

        try IO.print("\x1b[1;32m✓\x1b[0m Registered hook '{s}'\n", .{name});
        try IO.print("  Pattern: {s}\n", .{pattern});
        try IO.print("  Script:  {s}\n", .{script});
        return 0;
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (cmd.args.len < 2) {
            try IO.eprint("den: hook: remove: missing hook name\n", .{});
            return 1;
        }

        const name = cmd.args[1];
        if (registry.unregister(name)) {
            try IO.print("\x1b[1;32m✓\x1b[0m Removed hook '{s}'\n", .{name});
            return 0;
        } else {
            try IO.eprint("den: hook: remove: '{s}' not found\n", .{name});
            return 1;
        }
    } else if (std.mem.eql(u8, subcmd, "enable")) {
        if (cmd.args.len < 2) {
            try IO.eprint("den: hook: enable: missing hook name\n", .{});
            return 1;
        }

        const name = cmd.args[1];
        if (registry.setEnabled(name, true)) {
            try IO.print("\x1b[1;32m✓\x1b[0m Enabled hook '{s}'\n", .{name});
            return 0;
        } else {
            try IO.eprint("den: hook: enable: '{s}' not found\n", .{name});
            return 1;
        }
    } else if (std.mem.eql(u8, subcmd, "disable")) {
        if (cmd.args.len < 2) {
            try IO.eprint("den: hook: disable: missing hook name\n", .{});
            return 1;
        }

        const name = cmd.args[1];
        if (registry.setEnabled(name, false)) {
            try IO.print("\x1b[1;32m✓\x1b[0m Disabled hook '{s}'\n", .{name});
            return 0;
        } else {
            try IO.eprint("den: hook: disable: '{s}' not found\n", .{name});
            return 1;
        }
    } else if (std.mem.eql(u8, subcmd, "test")) {
        if (cmd.args.len < 2) {
            try IO.eprint("den: hook: test: missing command to test\n", .{});
            return 1;
        }

        // Join remaining args as the test command
        var test_cmd_buf: [1024]u8 = undefined;
        var pos: usize = 0;
        for (cmd.args[1..]) |arg| {
            if (pos > 0) {
                test_cmd_buf[pos] = ' ';
                pos += 1;
            }
            const len = @min(arg.len, test_cmd_buf.len - pos);
            @memcpy(test_cmd_buf[pos .. pos + len], arg[0..len]);
            pos += len;
        }
        const test_cmd = test_cmd_buf[0..pos];

        const matches = registry.findMatchingHooks(test_cmd);
        if (matches.len == 0) {
            try IO.print("\x1b[2mNo hooks match: {s}\x1b[0m\n", .{test_cmd});
        } else {
            try IO.print("\x1b[1;36mHooks matching '{s}':\x1b[0m\n\n", .{test_cmd});
            for (matches) |hk| {
                const cond_met = plugins.CustomHookRegistry.checkCondition(hk.condition);
                const cond_status = if (cond_met) "\x1b[1;32m✓\x1b[0m" else "\x1b[1;31m✗\x1b[0m";
                try IO.print("  {s} {s}\n", .{ cond_status, hk.name });
                if (hk.script) |script| {
                    try IO.print("      → {s}\n", .{script});
                }
            }
        }
        return 0;
    } else {
        try IO.eprint("den: hook: unknown command '{s}'\n", .{subcmd});
        try IO.eprint("den: hook: run 'hook' for usage.\n", .{});
        return 1;
    }
}
