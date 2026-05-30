//! `ai` builtin — translate a natural-language request into a shell command
//! using a configured AI endpoint, then print it for the user to review.
//!
//! Usage:  ai <describe what you want>
//! Example: ai find all zig files modified today
//!
//! Disabled by default; enable via config `ai.enabled = true` and set the API
//! key in the environment variable named by `ai.api_key_env` (default
//! OPENAI_API_KEY). Network/parse failures print a friendly message.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const ai = @import("../ai/completion.zig");

const Shell = @import("../shell.zig").Shell;

pub fn builtinAi(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("usage: ai <describe the command you want>\n", .{});
        self.last_exit_code = 2;
        return;
    }

    if (!self.config.ai.enabled) {
        try IO.eprint("den: ai: disabled. Set ai.enabled = true in your config to use it.\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Join args into a single prompt.
    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(self.allocator);
    for (cmd.args, 0..) |a, i| {
        if (i > 0) try prompt.append(self.allocator, ' ');
        try prompt.appendSlice(self.allocator, a);
    }

    const key = self.environment.get(self.config.ai.api_key_env);

    const suggestion = ai.suggest(self.allocator, self.config.ai, key, prompt.items) catch null;
    if (suggestion) |s| {
        defer self.allocator.free(s);
        // Print the command so the user can copy/run it. We deliberately do not
        // auto-execute model output.
        try IO.print("{s}\n", .{s});
        self.last_exit_code = 0;
    } else {
        if (key == null or key.?.len == 0) {
            try IO.eprint("den: ai: no API key found in ${s}\n", .{self.config.ai.api_key_env});
        } else {
            try IO.eprint("den: ai: no suggestion (network error or unparseable response)\n", .{});
        }
        self.last_exit_code = 1;
    }
}
