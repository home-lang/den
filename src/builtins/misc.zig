const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;

/// Miscellaneous builtins - delegated to Shell

pub fn sleep(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinSleep(cmd);
}

pub fn help(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinHelp(cmd);
}

pub fn clear(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinClear(cmd);
}

pub fn uname(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinUname(cmd);
}

pub fn whoami(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinWhoami(cmd);
}

pub fn umask(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinUmask(cmd);
}

pub fn time(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinTime(cmd);
}

pub fn caller(shell: *Shell, cmd: *types.ParsedCommand) !void {
    return shell.builtinCaller(cmd);
}
