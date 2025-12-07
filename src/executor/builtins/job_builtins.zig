const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;

/// Job control builtins: jobs, fg, bg, wait, disown

/// jobs - list active jobs
pub fn jobs(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    return ctx.builtinJobs(command.args) catch |err| {
        if (err == error.NoShellContext) {
            try IO.eprint("den: jobs: shell context not available\n", .{});
            return 1;
        }
        return err;
    };
}

/// fg - bring job to foreground
pub fn fg(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    return ctx.builtinFg(command.args) catch |err| {
        if (err == error.NoShellContext) {
            try IO.eprint("den: fg: shell context not available\n", .{});
            return 1;
        }
        return err;
    };
}

/// bg - resume job in background
pub fn bg(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    return ctx.builtinBg(command.args) catch |err| {
        if (err == error.NoShellContext) {
            try IO.eprint("den: bg: shell context not available\n", .{});
            return 1;
        }
        return err;
    };
}

/// wait - wait for job completion
pub fn wait(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    return ctx.builtinWait(command.args) catch |err| {
        if (err == error.NoShellContext) {
            try IO.eprint("den: wait: shell context not available\n", .{});
            return 1;
        }
        return err;
    };
}

/// disown - remove job from job table
pub fn disown(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    return ctx.builtinDisown(command.args) catch |err| {
        if (err == error.NoShellContext) {
            try IO.eprint("den: disown: shell context not available\n", .{});
            return 1;
        }
        return err;
    };
}
