const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;

/// I/O builtins - delegated to Shell for state access

pub fn printf(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinPrintf(cmd);
}

pub fn read(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinRead(cmd);
}
