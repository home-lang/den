const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;

/// Process control builtins - delegated to Shell

pub fn exec(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinExec(cmd);
}

pub fn wait(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinWait(cmd);
}

pub fn kill(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinKill(cmd);
}

pub fn disown(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinDisown(cmd);
}
