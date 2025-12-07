const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;

/// Alias builtins: alias, unalias
/// Supports -s flag for suffix aliases (zsh-style): alias -s ts='bun'
/// Supports -g flag for global aliases (zsh-style): alias -g L='| less'

pub fn alias(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    const shell_ref = ctx.getShell() catch {
        try IO.eprint("den: alias: shell context not available\n", .{});
        return 1;
    };

    // Check for flags
    var is_suffix_alias = false;
    var is_global_alias = false;
    var args_start: usize = 0;

    while (args_start < command.args.len) {
        const arg = command.args[args_start];
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    's' => is_suffix_alias = true,
                    'g' => is_global_alias = true,
                    else => {
                        try IO.eprint("den: alias: invalid option: -{c}\n", .{c});
                        return 1;
                    },
                }
            }
            args_start += 1;
        } else {
            break;
        }
    }

    const effective_args = command.args[args_start..];

    if (is_suffix_alias) {
        return handleSuffixAlias(ctx, shell_ref, effective_args);
    }

    if (is_global_alias) {
        return handleGlobalAlias(ctx, shell_ref, effective_args);
    }

    // Handle regular aliases
    if (effective_args.len == 0) {
        // Display all aliases
        var iter = shell_ref.aliases.iterator();
        while (iter.next()) |entry| {
            try IO.print("alias {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        var global_iter = shell_ref.global_aliases.iterator();
        while (global_iter.next()) |entry| {
            try IO.print("alias -g {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    const arg = effective_args[0];
    const eq_pos = std.mem.indexOf(u8, arg, "=") orelse {
        // No '=', just show the alias value
        if (shell_ref.aliases.get(arg)) |value| {
            try IO.print("alias {s}='{s}'\n", .{ arg, value });
        } else if (shell_ref.global_aliases.get(arg)) |value| {
            try IO.print("alias -g {s}='{s}'\n", .{ arg, value });
        } else {
            try IO.eprint("den: alias: {s}: not found\n", .{arg});
            return 1;
        }
        return 0;
    };

    const name = arg[0..eq_pos];
    const value = arg[eq_pos + 1 ..];

    const name_owned = try ctx.allocator.dupe(u8, name);
    const value_owned = try ctx.allocator.dupe(u8, value);

    const gop = try shell_ref.aliases.getOrPut(name_owned);
    if (gop.found_existing) {
        ctx.allocator.free(name_owned);
        ctx.allocator.free(gop.value_ptr.*);
    }
    gop.value_ptr.* = value_owned;

    return 0;
}

fn handleSuffixAlias(ctx: *BuiltinContext, shell_ref: anytype, effective_args: [][]const u8) !i32 {
    if (effective_args.len == 0) {
        var iter = shell_ref.suffix_aliases.iterator();
        while (iter.next()) |entry| {
            try IO.print("alias -s {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    const arg = effective_args[0];
    const eq_pos = std.mem.indexOf(u8, arg, "=") orelse {
        if (shell_ref.suffix_aliases.get(arg)) |value| {
            try IO.print("alias -s {s}='{s}'\n", .{ arg, value });
        } else {
            try IO.eprint("den: alias: suffix alias {s}: not found\n", .{arg});
            return 1;
        }
        return 0;
    };

    const extension = arg[0..eq_pos];
    var value = arg[eq_pos + 1 ..];

    // Remove quotes if present
    if (value.len >= 2 and
        ((value[0] == '\'' and value[value.len - 1] == '\'') or
        (value[0] == '"' and value[value.len - 1] == '"')))
    {
        value = value[1 .. value.len - 1];
    }

    const ext_owned = try ctx.allocator.dupe(u8, extension);
    const value_owned = try ctx.allocator.dupe(u8, value);

    const gop = try shell_ref.suffix_aliases.getOrPut(ext_owned);
    if (gop.found_existing) {
        ctx.allocator.free(ext_owned);
        ctx.allocator.free(gop.value_ptr.*);
    }
    gop.value_ptr.* = value_owned;

    return 0;
}

fn handleGlobalAlias(ctx: *BuiltinContext, shell_ref: anytype, effective_args: [][]const u8) !i32 {
    if (effective_args.len == 0) {
        var iter = shell_ref.global_aliases.iterator();
        while (iter.next()) |entry| {
            try IO.print("alias -g {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    const arg = effective_args[0];
    const eq_pos = std.mem.indexOf(u8, arg, "=") orelse {
        if (shell_ref.global_aliases.get(arg)) |value| {
            try IO.print("alias -g {s}='{s}'\n", .{ arg, value });
        } else {
            try IO.eprint("den: alias: global alias {s}: not found\n", .{arg});
            return 1;
        }
        return 0;
    };

    const name = arg[0..eq_pos];
    var value = arg[eq_pos + 1 ..];

    // Remove quotes if present
    if (value.len >= 2 and
        ((value[0] == '\'' and value[value.len - 1] == '\'') or
        (value[0] == '"' and value[value.len - 1] == '"')))
    {
        value = value[1 .. value.len - 1];
    }

    const name_owned = try ctx.allocator.dupe(u8, name);
    const value_owned = try ctx.allocator.dupe(u8, value);

    const gop = try shell_ref.global_aliases.getOrPut(name_owned);
    if (gop.found_existing) {
        ctx.allocator.free(name_owned);
        ctx.allocator.free(gop.value_ptr.*);
    }
    gop.value_ptr.* = value_owned;

    return 0;
}

pub fn unalias(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    const shell_ref = ctx.getShell() catch {
        try IO.eprint("den: unalias: shell context not available\n", .{});
        return 1;
    };

    if (command.args.len == 0) {
        try IO.eprint("den: unalias: usage: unalias [-s|-g] [-a] name [name ...]\n", .{});
        return 1;
    }

    // Check for flags
    var is_suffix_alias = false;
    var is_global_alias = false;
    var args_start: usize = 0;

    while (args_start < command.args.len) {
        const arg = command.args[args_start];
        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != 'a') {
            for (arg[1..]) |c| {
                switch (c) {
                    's' => is_suffix_alias = true,
                    'g' => is_global_alias = true,
                    else => {
                        try IO.eprint("den: unalias: invalid option: -{c}\n", .{c});
                        return 1;
                    },
                }
            }
            args_start += 1;
        } else {
            break;
        }
    }

    const effective_args = command.args[args_start..];

    if (effective_args.len == 0) {
        try IO.eprint("den: unalias: usage: unalias [-s|-g] [-a] name [name ...]\n", .{});
        return 1;
    }

    if (is_suffix_alias) {
        if (std.mem.eql(u8, effective_args[0], "-a")) {
            var iter = shell_ref.suffix_aliases.iterator();
            while (iter.next()) |entry| {
                ctx.allocator.free(entry.key_ptr.*);
                ctx.allocator.free(entry.value_ptr.*);
            }
            shell_ref.suffix_aliases.clearRetainingCapacity();
            return 0;
        }

        for (effective_args) |extension| {
            if (shell_ref.suffix_aliases.fetchRemove(extension)) |kv| {
                ctx.allocator.free(kv.key);
                ctx.allocator.free(kv.value);
            } else {
                try IO.eprint("den: unalias: suffix alias {s}: not found\n", .{extension});
                return 1;
            }
        }
        return 0;
    }

    if (is_global_alias) {
        if (std.mem.eql(u8, effective_args[0], "-a")) {
            var iter = shell_ref.global_aliases.iterator();
            while (iter.next()) |entry| {
                ctx.allocator.free(entry.key_ptr.*);
                ctx.allocator.free(entry.value_ptr.*);
            }
            shell_ref.global_aliases.clearRetainingCapacity();
            return 0;
        }

        for (effective_args) |name| {
            if (shell_ref.global_aliases.fetchRemove(name)) |kv| {
                ctx.allocator.free(kv.key);
                ctx.allocator.free(kv.value);
            } else {
                try IO.eprint("den: unalias: global alias {s}: not found\n", .{name});
                return 1;
            }
        }
        return 0;
    }

    // Support -a flag to remove all aliases
    if (std.mem.eql(u8, effective_args[0], "-a")) {
        var iter = shell_ref.aliases.iterator();
        while (iter.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            ctx.allocator.free(entry.value_ptr.*);
        }
        shell_ref.aliases.clearRetainingCapacity();

        var global_iter = shell_ref.global_aliases.iterator();
        while (global_iter.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            ctx.allocator.free(entry.value_ptr.*);
        }
        shell_ref.global_aliases.clearRetainingCapacity();
        return 0;
    }

    // Remove specific alias
    for (effective_args) |name| {
        if (shell_ref.aliases.fetchRemove(name)) |kv| {
            ctx.allocator.free(kv.key);
            ctx.allocator.free(kv.value);
        } else if (shell_ref.global_aliases.fetchRemove(name)) |kv| {
            ctx.allocator.free(kv.key);
            ctx.allocator.free(kv.value);
        } else {
            try IO.eprint("den: unalias: {s}: not found\n", .{name});
            return 1;
        }
    }

    return 0;
}
