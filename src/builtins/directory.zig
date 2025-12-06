const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;

/// Builtins delegated to Shell for directory stack management
/// These require Shell state access (dir_stack)

pub fn pushd(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinPushd(cmd);
}

pub fn popd(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinPopd(cmd);
}

pub fn dirs(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinDirs(cmd);
}
