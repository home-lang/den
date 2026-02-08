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
/// - process_builtins: Process-related builtins (times, umask, timeout)
/// - macos_builtins: macOS/system utilities (copyssh, reloaddns, emptytrash, show, hide, dotfiles, library)
/// - http_builtins: HTTP client (http get/post/put/delete/head via curl)
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
pub const process_builtins = @import("process_builtins.zig");
pub const macos_builtins = @import("macos_builtins.zig");
pub const signal_builtins = @import("signal_builtins.zig");
pub const dev_builtins = @import("dev_builtins.zig");
pub const interactive_builtins = @import("interactive_builtins.zig");
pub const job_builtins = @import("job_builtins.zig");
pub const command_builtins = @import("command_builtins.zig");
pub const state_builtins = @import("state_builtins.zig");
pub const exec_builtins = @import("exec_builtins.zig");
pub const context = @import("context.zig");

// Nushell-inspired structured data builtins
pub const data_builtins = @import("data_builtins.zig");
pub const pipeline_builtins = @import("pipeline_builtins.zig");
pub const str_builtins = @import("str_builtins.zig");
pub const path_builtins = @import("path_builtins.zig");
pub const math_builtins = @import("math_builtins.zig");
pub const date_builtins = @import("date_builtins.zig");
pub const encode_builtins = @import("encode_builtins.zig");
pub const convert_builtins = @import("convert_builtins.zig");
pub const detect_builtins = @import("detect_builtins.zig");
pub const bench_builtins = @import("bench_builtins.zig");
pub const http_builtins = @import("http_builtins.zig");
pub const seq_builtins = @import("seq_builtins.zig");
pub const watch_builtins = @import("watch_builtins.zig");
pub const help_system = @import("help_system.zig");
pub const explore_builtins = @import("explore_builtins.zig");

pub const BuiltinContext = context.BuiltinContext;
