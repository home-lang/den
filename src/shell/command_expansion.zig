//! Command Expansion Module
//! Handles variable, brace, glob, and alias expansion for commands

const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;
const Glob = @import("../utils/glob.zig").Glob;
const BraceExpander = @import("../utils/brace.zig").BraceExpander;
const Shell = @import("../shell.zig").Shell;
const builtin = @import("builtin");

/// Expand variables, braces, and globs in a command chain
pub fn expandCommandChain(self: *Shell, chain: *types.CommandChain) !void {
    // Collect positional params for the expander
    // If inside a function, use function's positional params instead of shell's
    var positional_params_slice: [64][]const u8 = undefined;
    var param_count: usize = 0;

    if (self.function_manager.currentFrame()) |frame| {
        // Inside a function - use function's positional params
        var i: usize = 0;
        while (i < frame.positional_params_count) : (i += 1) {
            if (frame.positional_params[i]) |param| {
                positional_params_slice[param_count] = param;
                param_count += 1;
            }
        }
    } else {
        // Not inside a function - use shell's positional params
        for (self.positional_params) |maybe_param| {
            if (maybe_param) |param| {
                positional_params_slice[param_count] = param;
                param_count += 1;
            }
        }
    }

    // Convert PID to i32 for expansion (0 on Windows where we don't track PIDs)
    const pid_for_expansion: i32 = if (builtin.os.tag == .windows)
        0
    else
        @intCast(self.job_manager.getLastPid());

    var expander = Expansion.initWithShell(
        self.allocator,
        &self.environment,
        self.last_exit_code,
        positional_params_slice[0..param_count],
        self.shell_name,
        pid_for_expansion,
        self.last_arg,
        self,
    );
    expander.arrays = &self.arrays; // Add indexed array support
    expander.assoc_arrays = &self.assoc_arrays; // Add associative array support
    expander.var_attributes = &self.var_attributes; // Add nameref support
    // Set local vars pointer if inside a function
    if (self.function_manager.currentFrame()) |frame| {
        expander.local_vars = &frame.local_vars;
    }
    var glob = Glob.init(self.allocator);
    var brace = BraceExpander.init(self.allocator);

    // Get current working directory for glob expansion
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try std.posix.getcwd(&cwd_buf);

    for (chain.commands) |*cmd| {
        // Expand command name (variables only, no globs for command names)
        const expanded_name = try expander.expand(cmd.name);
        self.allocator.free(cmd.name);
        cmd.name = expanded_name;

        // Expand arguments (variables + braces + globs)
        var expanded_args_buffer: [128][]const u8 = undefined;
        var expanded_args_count: usize = 0;

        for (cmd.args) |arg| {
            // First expand variables
            const var_expanded = try expander.expand(arg);
            defer self.allocator.free(var_expanded);

            // Then expand braces
            const brace_expanded = try brace.expand(var_expanded);
            defer {
                for (brace_expanded) |item| {
                    self.allocator.free(item);
                }
                self.allocator.free(brace_expanded);
            }

            // Then expand globs on each brace expansion result
            for (brace_expanded) |brace_item| {
                const glob_expanded = try glob.expand(brace_item, cwd);
                defer {
                    for (glob_expanded) |path| {
                        self.allocator.free(path);
                    }
                    self.allocator.free(glob_expanded);
                }

                // Add all glob matches to args
                for (glob_expanded) |path| {
                    if (expanded_args_count >= expanded_args_buffer.len) {
                        return error.TooManyArguments;
                    }
                    expanded_args_buffer[expanded_args_count] = try self.allocator.dupe(u8, path);
                    expanded_args_count += 1;
                }
            }

            // Free original arg
            self.allocator.free(arg);
        }

        // Replace args with expanded version
        self.allocator.free(cmd.args);
        const new_args = try self.allocator.alloc([]const u8, expanded_args_count);
        @memcpy(new_args, expanded_args_buffer[0..expanded_args_count]);
        cmd.args = new_args;

        // Expand redirection targets (variables only, no globs)
        for (cmd.redirections, 0..) |*redir, i| {
            const expanded_target = try expander.expand(redir.target);
            self.allocator.free(cmd.redirections[i].target);
            cmd.redirections[i].target = expanded_target;
        }
    }
}

/// Expand aliases in a command chain with circular reference detection
pub fn expandAliases(self: *Shell, chain: *types.CommandChain) !void {
    // Track seen aliases to detect circular references
    var seen_aliases: [32][]const u8 = undefined;
    var seen_count: usize = 0;

    for (chain.commands) |*cmd| {
        seen_count = 0; // Reset for each command
        var current_name = cmd.name;
        var expanded = false;

        // Expand aliases iteratively with circular detection
        while (self.aliases.get(current_name)) |alias_value| {
            // Check for circular reference
            for (seen_aliases[0..seen_count]) |seen| {
                if (std.mem.eql(u8, seen, current_name)) {
                    try IO.eprint("den: alias: circular reference detected: {s}\n", .{current_name});
                    return; // Stop expansion on circular reference
                }
            }

            // Track this alias
            if (seen_count < seen_aliases.len) {
                seen_aliases[seen_count] = current_name;
                seen_count += 1;
            } else {
                // Too many nested aliases
                try IO.eprint("den: alias: expansion depth limit exceeded\n", .{});
                return;
            }

            // Get the first word of the alias value as the new command name
            const trimmed = std.mem.trim(u8, alias_value, &std.ascii.whitespace);
            const first_space = std.mem.indexOfScalar(u8, trimmed, ' ');
            const first_word = if (first_space) |pos| trimmed[0..pos] else trimmed;

            // Replace command name with expanded alias
            if (!expanded) {
                const new_name = try self.allocator.dupe(u8, alias_value);
                self.allocator.free(cmd.name);
                cmd.name = new_name;
                expanded = true;
            }

            // POSIX behavior: if the first word of the expansion matches the
            // alias name, stop expanding to allow self-referencing aliases
            // like "ls" -> "ls --color=auto"
            if (std.mem.eql(u8, first_word, current_name)) break;

            // Check if first word is also an alias
            current_name = first_word;
        }
    }
}
