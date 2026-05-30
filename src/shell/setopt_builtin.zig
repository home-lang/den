//! zsh-style `setopt` / `unsetopt` builtins.
//!
//! These accept zsh option names (e.g. `extendedglob`, `nullglob`, `autocd`)
//! and map them onto Den's existing `shopt_*` / `option_*` flags via the zsh
//! compatibility layer. Unknown names produce a diagnostic and a non-zero exit.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const zsh = @import("../compat/zsh.zig");

const Shell = @import("../shell.zig").Shell;

/// Point a zsh OptionTarget at the concrete shell flag it controls.
fn flagPtr(self: *Shell, target: zsh.OptionTarget) ?*bool {
    return switch (target) {
        .extglob => &self.shopt_extglob,
        .nullglob => &self.shopt_nullglob,
        .dotglob => &self.shopt_dotglob,
        .nocaseglob => &self.shopt_nocaseglob,
        .globstar => &self.shopt_globstar,
        .failglob => &self.shopt_failglob,
        .autocd => &self.shopt_autocd,
        .histappend => &self.shopt_histappend,
        .expand_aliases => &self.shopt_expand_aliases,
        .errexit => &self.option_errexit,
        .nounset => &self.option_nounset,
        .xtrace => &self.option_xtrace,
        .noglob => &self.option_noglob,
        .pipefail => &self.option_pipefail,
        .verbose => &self.option_verbose,
        .unknown => null,
    };
}

/// Shared implementation; `enable` is true for `setopt`, false for `unsetopt`.
fn apply(self: *Shell, cmd: *types.ParsedCommand, enable: bool) !void {
    if (cmd.args.len == 0) {
        // With no operands, print the options that are currently enabled.
        try printEnabled(self);
        self.last_exit_code = 0;
        return;
    }

    var ok = true;
    for (cmd.args) |raw| {
        // zsh ignores case and underscores in option names.
        const resolved = zsh.resolveOption(raw);
        if (flagPtr(self, resolved.target)) |ptr| {
            ptr.* = if (enable) resolved.on_value else !resolved.on_value;
        } else {
            try IO.eprint("den: {s}: no such option: {s}\n", .{ if (enable) "setopt" else "unsetopt", raw });
            ok = false;
        }
    }
    self.last_exit_code = if (ok) 0 else 1;
}

fn printEnabled(self: *Shell) !void {
    const names = [_]struct { []const u8, *bool }{
        .{ "extendedglob", &self.shopt_extglob },
        .{ "nullglob", &self.shopt_nullglob },
        .{ "globdots", &self.shopt_dotglob },
        .{ "nocaseglob", &self.shopt_nocaseglob },
        .{ "globstarshort", &self.shopt_globstar },
        .{ "nomatch", &self.shopt_failglob },
        .{ "autocd", &self.shopt_autocd },
        .{ "appendhistory", &self.shopt_histappend },
        .{ "errexit", &self.option_errexit },
        .{ "nounset", &self.option_nounset },
        .{ "xtrace", &self.option_xtrace },
        .{ "noglob", &self.option_noglob },
        .{ "pipefail", &self.option_pipefail },
        .{ "verbose", &self.option_verbose },
    };
    for (names) |n| {
        if (n[1].*) try IO.print("{s}\n", .{n[0]});
    }
}

pub fn builtinSetopt(self: *Shell, cmd: *types.ParsedCommand) !void {
    try apply(self, cmd, true);
}

pub fn builtinUnsetopt(self: *Shell, cmd: *types.ParsedCommand) !void {
    try apply(self, cmd, false);
}
