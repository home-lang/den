const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;

/// Variable management builtins - delegated to Shell

pub fn local(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinLocal(cmd);
}

pub fn declare(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinDeclare(cmd);
}

pub fn readonly(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinReadonly(cmd);
}

pub fn typeset(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinTypeset(cmd);
}

pub fn let(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinLet(cmd);
}
