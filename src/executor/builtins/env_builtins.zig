const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;

/// Environment builtins: env, export, set, unset

pub fn env(ctx: *BuiltinContext) !i32 {
    var iter = ctx.envIterator();
    while (iter.next()) |entry| {
        try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return 0;
}

pub fn exportBuiltin(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        return try env(ctx);
    }

    // Check for --help
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try IO.print("Usage: export [-fnp] [name[=value] ...]\n", .{});
            try IO.print("Set export attribute for shell variables.\n\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -f    treat each NAME as a shell function\n", .{});
            try IO.print("  -n    remove the export property from NAME\n", .{});
            try IO.print("  -p    display all exported variables and functions\n", .{});
            try IO.print("  -pf   display all exported functions\n", .{});
            try IO.print("\nWith no NAME, display all exported variables.\n", .{});
            return 0;
        }
    }

    // Check for -pf flag (print exported functions)
    if (command.args.len >= 1 and (std.mem.eql(u8, command.args[0], "-pf") or
        (command.args.len >= 2 and std.mem.eql(u8, command.args[0], "-p") and std.mem.eql(u8, command.args[1], "-f"))))
    {
        if (ctx.hasShell()) {
            const shell_ref = try ctx.getShell();
            var iter = shell_ref.function_manager.functions.iterator();
            while (iter.next()) |entry| {
                const func = entry.value_ptr;
                if (func.is_exported) {
                    try IO.print("export -f {s}\n", .{func.name});
                }
            }
        }
        return 0;
    }

    // Check for -p flag (print in reusable format)
    if (command.args.len == 1 and std.mem.eql(u8, command.args[0], "-p")) {
        var iter = ctx.envIterator();
        while (iter.next()) |entry| {
            try IO.print("export {s}=\"", .{entry.key_ptr.*});
            for (entry.value_ptr.*) |c| {
                switch (c) {
                    '"' => try IO.print("\\\"", .{}),
                    '\\' => try IO.print("\\\\", .{}),
                    '$' => try IO.print("\\$", .{}),
                    '`' => try IO.print("\\`", .{}),
                    '\n' => try IO.print("\\n", .{}),
                    else => try IO.print("{c}", .{c}),
                }
            }
            try IO.print("\"\n", .{});
        }
        return 0;
    }

    // Parse flags
    var arg_start: usize = 0;
    var unexport_mode = false;
    var function_mode = false;

    while (arg_start < command.args.len) {
        const arg = command.args[arg_start];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-n")) {
                unexport_mode = true;
                arg_start += 1;
            } else if (std.mem.eql(u8, arg, "-f")) {
                function_mode = true;
                arg_start += 1;
            } else if (std.mem.eql(u8, arg, "-nf") or std.mem.eql(u8, arg, "-fn")) {
                unexport_mode = true;
                function_mode = true;
                arg_start += 1;
            } else if (std.mem.eql(u8, arg, "--")) {
                arg_start += 1;
                break;
            } else {
                break;
            }
        } else {
            break;
        }
    }

    // Handle function export mode
    if (function_mode) {
        if (ctx.hasShell()) {
            const shell_ref = try ctx.getShell();
            for (command.args[arg_start..]) |func_name| {
                if (unexport_mode) {
                    if (shell_ref.function_manager.getFunction(func_name)) |func| {
                        func.is_exported = false;
                    } else {
                        try IO.eprint("den: export: {s}: not a function\n", .{func_name});
                    }
                } else {
                    if (shell_ref.function_manager.getFunction(func_name)) |func| {
                        func.is_exported = true;
                    } else {
                        try IO.eprint("den: export: {s}: not a function\n", .{func_name});
                    }
                }
            }
        }
        return 0;
    }

    if (unexport_mode) {
        for (command.args[arg_start..]) |arg| {
            ctx.unsetEnv(arg);
        }
        return 0;
    }

    for (command.args[arg_start..]) |arg| {
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const var_name = arg[0..eq_pos];
            const var_value = arg[eq_pos + 1 ..];
            try ctx.setEnv(var_name, var_value);
        } else {
            // Just variable name - export with empty value or existing value
            if (ctx.getEnv(arg) == null) {
                try ctx.setEnv(arg, "");
            }
        }
    }

    return 0;
}

pub fn set(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        return try env(ctx);
    }

    var arg_idx: usize = 0;
    while (arg_idx < command.args.len) {
        const arg = command.args[arg_idx];

        // Handle shell options (-e, -E, +e, +E, etc.)
        if (arg.len > 0 and (arg[0] == '-' or arg[0] == '+')) {
            const enable = arg[0] == '-';
            const option = arg[1..];

            if (ctx.hasShell()) {
                const shell_ref = try ctx.getShell();
                if (std.mem.eql(u8, option, "e")) {
                    shell_ref.option_errexit = enable;
                } else if (std.mem.eql(u8, option, "E")) {
                    shell_ref.option_errtrace = enable;
                } else if (std.mem.eql(u8, option, "x")) {
                    shell_ref.option_xtrace = enable;
                } else if (std.mem.eql(u8, option, "u")) {
                    shell_ref.option_nounset = enable;
                } else if (std.mem.eql(u8, option, "n")) {
                    shell_ref.option_noexec = enable;
                } else if (std.mem.eql(u8, option, "v")) {
                    shell_ref.option_verbose = enable;
                } else if (std.mem.eql(u8, option, "f")) {
                    shell_ref.option_noglob = enable;
                } else if (std.mem.eql(u8, option, "C")) {
                    shell_ref.option_noclobber = enable;
                } else if (std.mem.eql(u8, option, "o")) {
                    if (arg_idx + 1 < command.args.len) {
                        const opt_name = command.args[arg_idx + 1];
                        if (std.mem.eql(u8, opt_name, "errexit")) {
                            shell_ref.option_errexit = enable;
                        } else if (std.mem.eql(u8, opt_name, "errtrace")) {
                            shell_ref.option_errtrace = enable;
                        } else if (std.mem.eql(u8, opt_name, "xtrace")) {
                            shell_ref.option_xtrace = enable;
                        } else if (std.mem.eql(u8, opt_name, "nounset")) {
                            shell_ref.option_nounset = enable;
                        } else if (std.mem.eql(u8, opt_name, "pipefail")) {
                            shell_ref.option_pipefail = enable;
                        } else if (std.mem.eql(u8, opt_name, "noexec")) {
                            shell_ref.option_noexec = enable;
                        } else if (std.mem.eql(u8, opt_name, "verbose")) {
                            shell_ref.option_verbose = enable;
                        } else if (std.mem.eql(u8, opt_name, "noglob")) {
                            shell_ref.option_noglob = enable;
                        } else if (std.mem.eql(u8, opt_name, "noclobber")) {
                            shell_ref.option_noclobber = enable;
                        } else {
                            try IO.eprint("den: set: {s}: invalid option name\n", .{opt_name});
                            return 1;
                        }
                        arg_idx += 1;
                    } else {
                        try IO.print("Current option settings:\n", .{});
                        try IO.print("errexit        {s}\n", .{if (shell_ref.option_errexit) "on" else "off"});
                        try IO.print("errtrace       {s}\n", .{if (shell_ref.option_errtrace) "on" else "off"});
                        try IO.print("xtrace         {s}\n", .{if (shell_ref.option_xtrace) "on" else "off"});
                        try IO.print("nounset        {s}\n", .{if (shell_ref.option_nounset) "on" else "off"});
                        try IO.print("pipefail       {s}\n", .{if (shell_ref.option_pipefail) "on" else "off"});
                        try IO.print("noexec         {s}\n", .{if (shell_ref.option_noexec) "on" else "off"});
                        try IO.print("verbose        {s}\n", .{if (shell_ref.option_verbose) "on" else "off"});
                        try IO.print("noglob         {s}\n", .{if (shell_ref.option_noglob) "on" else "off"});
                        try IO.print("noclobber      {s}\n", .{if (shell_ref.option_noclobber) "on" else "off"});
                    }
                } else {
                    try IO.eprint("den: set: unknown option: {s}\n", .{arg});
                    return 1;
                }
            } else {
                try IO.eprint("den: set: shell options not available in this context\n", .{});
                return 1;
            }
        } else if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const var_name = arg[0..eq_pos];
            const var_value = arg[eq_pos + 1 ..];
            try ctx.setEnv(var_name, var_value);
        } else {
            try IO.eprint("den: set: {s}: not a valid identifier\n", .{arg});
            return 1;
        }
        arg_idx += 1;
    }

    return 0;
}

pub fn unset(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: unset: not enough arguments\n", .{});
        return 1;
    }

    var unset_functions = false;
    var unset_variables = true;
    var arg_start: usize = 0;

    // Parse flags
    for (command.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-f")) {
                unset_functions = true;
                unset_variables = false;
                arg_start = i + 1;
            } else if (std.mem.eql(u8, arg, "-v")) {
                unset_variables = true;
                unset_functions = false;
                arg_start = i + 1;
            } else if (std.mem.eql(u8, arg, "-fv") or std.mem.eql(u8, arg, "-vf")) {
                unset_variables = true;
                unset_functions = true;
                arg_start = i + 1;
            } else if (std.mem.eql(u8, arg, "--help")) {
                try IO.print("Usage: unset [-fv] name [...]\n", .{});
                try IO.print("Remove NAME from the shell environment.\n\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -f    treat each NAME as a shell function\n", .{});
                try IO.print("  -v    treat each NAME as a shell variable (default)\n", .{});
                return 0;
            } else if (std.mem.eql(u8, arg, "--")) {
                arg_start = i + 1;
                break;
            } else {
                try IO.eprint("den: unset: invalid option -- '{s}'\n", .{arg});
                return 1;
            }
        } else {
            break;
        }
    }

    if (arg_start >= command.args.len) {
        try IO.eprint("den: unset: not enough arguments\n", .{});
        return 1;
    }

    if (unset_variables) {
        for (command.args[arg_start..]) |var_name| {
            ctx.unsetEnv(var_name);
        }
    }

    if (unset_functions) {
        if (ctx.hasShell()) {
            const shell_ref = try ctx.getShell();
            for (command.args[arg_start..]) |func_name| {
                shell_ref.function_manager.removeFunction(func_name);
            }
        }
    }

    return 0;
}
