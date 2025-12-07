/// Builtins module - organized shell builtin commands
///
/// This module organizes shell builtins into logical categories:
/// - utilities: Standalone utilities (true, false, colon, help, which, type, command, etc.)
/// - file_ops: File operations (tree, grep, find, ls, ft, calc, json)
/// - test_builtins: Test/conditional builtins (test, [, [[)
/// - io_builtins: I/O builtins (echo, printf)
/// - shell_builtins: Shell state builtins (cd, pwd, read, source, history)
/// - env_builtins: Environment builtins (env, export, set, unset)
/// - dir_builtins: Directory stack builtins (pushd, popd, dirs)
/// - alias_builtins: Alias builtins (alias, unalias)
/// - monitoring_builtins: System monitoring (sys-stats, netstats, net-check, log-tail, proc-monitor, log-parse)
/// - context: BuiltinContext interface for state-dependent builtins

pub const utilities = @import("utilities.zig");
pub const file_ops = @import("file_ops.zig");
pub const test_builtins = @import("test_builtins.zig");
pub const io_builtins = @import("io_builtins.zig");
pub const shell_builtins = @import("shell_builtins.zig");
pub const env_builtins = @import("env_builtins.zig");
pub const dir_builtins = @import("dir_builtins.zig");
pub const alias_builtins = @import("alias_builtins.zig");
pub const monitoring_builtins = @import("monitoring_builtins.zig");
pub const context = @import("context.zig");

pub const BuiltinContext = context.BuiltinContext;
