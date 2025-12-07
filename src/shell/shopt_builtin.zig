//! Shopt Builtin Implementation
//!
//! This module implements the shopt builtin command
//! for managing shell options.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: shopt - set and unset shell options
pub fn builtinShopt(self: *Shell, cmd: *types.ParsedCommand) !void {
    var set_mode = false; // -s: set
    var unset_mode = false; // -u: unset
    var quiet_mode = false; // -q: quiet (just return status)
    var print_mode = false; // -p: print in reusable form
    var arg_start: usize = 0;

    // Parse flags
    while (arg_start < cmd.args.len) {
        const arg = cmd.args[arg_start];
        if (arg.len > 0 and arg[0] == '-') {
            arg_start += 1;
            for (arg[1..]) |c| {
                switch (c) {
                    's' => set_mode = true,
                    'u' => unset_mode = true,
                    'q' => quiet_mode = true,
                    'p' => print_mode = true,
                    else => {},
                }
            }
        } else {
            break;
        }
    }

    // Option definitions
    const ShoptOption = struct {
        name: []const u8,
        ptr: *bool,
    };
    var options = [_]ShoptOption{
        .{ .name = "extglob", .ptr = &self.shopt_extglob },
        .{ .name = "nullglob", .ptr = &self.shopt_nullglob },
        .{ .name = "dotglob", .ptr = &self.shopt_dotglob },
        .{ .name = "nocaseglob", .ptr = &self.shopt_nocaseglob },
        .{ .name = "globstar", .ptr = &self.shopt_globstar },
        .{ .name = "failglob", .ptr = &self.shopt_failglob },
        .{ .name = "expand_aliases", .ptr = &self.shopt_expand_aliases },
        .{ .name = "sourcepath", .ptr = &self.shopt_sourcepath },
        .{ .name = "checkwinsize", .ptr = &self.shopt_checkwinsize },
        .{ .name = "histappend", .ptr = &self.shopt_histappend },
        .{ .name = "cmdhist", .ptr = &self.shopt_cmdhist },
        .{ .name = "autocd", .ptr = &self.shopt_autocd },
    };

    // No arguments - print all or specified options
    if (arg_start >= cmd.args.len) {
        for (&options) |*opt| {
            if (!quiet_mode) {
                if (print_mode) {
                    try IO.print("shopt {s} {s}\n", .{ if (opt.ptr.*) "-s" else "-u", opt.name });
                } else {
                    try IO.print("{s}\t{s}\n", .{ opt.name, if (opt.ptr.*) "on" else "off" });
                }
            }
        }
        self.last_exit_code = 0;
        return;
    }

    // Process specified options
    var all_found = true;
    for (cmd.args[arg_start..]) |opt_name| {
        var found = false;
        for (&options) |*opt| {
            if (std.mem.eql(u8, opt_name, opt.name)) {
                found = true;
                if (set_mode) {
                    opt.ptr.* = true;
                } else if (unset_mode) {
                    opt.ptr.* = false;
                } else if (!quiet_mode) {
                    if (print_mode) {
                        try IO.print("shopt {s} {s}\n", .{ if (opt.ptr.*) "-s" else "-u", opt.name });
                    } else {
                        try IO.print("{s}\t{s}\n", .{ opt.name, if (opt.ptr.*) "on" else "off" });
                    }
                }
                break;
            }
        }
        if (!found) {
            if (!quiet_mode) {
                try IO.eprint("den: shopt: {s}: invalid shell option name\n", .{opt_name});
            }
            all_found = false;
        }
    }

    self.last_exit_code = if (all_found) 0 else 1;
}
