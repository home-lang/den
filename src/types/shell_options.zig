/// Shell options module for Den shell.
///
/// This module contains all shell option flags including:
/// - POSIX set options (-e, -u, -x, etc.)
/// - Bash-style shopt options (extglob, globstar, etc.)

/// Shell options controlled by the `set` builtin.
pub const SetOptions = struct {
    /// set -e: Exit immediately if a command exits with non-zero status.
    errexit: bool = false,

    /// set -E: Inherit ERR trap in shell functions.
    errtrace: bool = false,

    /// set -x: Print commands and their arguments before execution.
    xtrace: bool = false,

    /// set -u: Treat unset variables as an error when substituting.
    nounset: bool = false,

    /// set -o pipefail: Pipeline returns the exit status of the last command
    /// to exit with a non-zero status, or zero if all commands exit successfully.
    pipefail: bool = false,

    /// set -n: Read commands but do not execute them (syntax check mode).
    noexec: bool = false,

    /// set -v: Print shell input lines as they are read.
    verbose: bool = false,

    /// set -f: Disable filename expansion (globbing).
    noglob: bool = false,

    /// set -C: Prevent output redirection from overwriting existing files.
    noclobber: bool = false,
};

/// Shell options controlled by the `shopt` builtin (bash-style).
pub const ShoptOptions = struct {
    /// Extended glob patterns (?(...), *(...), +(...), @(...), !(...)).
    extglob: bool = true,

    /// Patterns that match nothing expand to the empty string.
    nullglob: bool = false,

    /// Patterns match dotfiles (files beginning with .).
    dotglob: bool = false,

    /// Case-insensitive globbing.
    nocaseglob: bool = false,

    /// ** pattern matches zero or more directories recursively.
    globstar: bool = false,

    /// Pattern expansion failure causes an error.
    failglob: bool = false,

    /// Expand aliases in non-interactive shells.
    expand_aliases: bool = true,

    /// Search PATH for the `source` command.
    sourcepath: bool = true,

    /// Check window size after each command.
    checkwinsize: bool = true,

    /// Append to history file instead of overwriting.
    histappend: bool = false,

    /// Save multi-line commands as a single history entry.
    cmdhist: bool = true,

    /// Typing a directory name auto-changes to that directory.
    autocd: bool = false,

    /// Correct minor spelling errors in cd commands.
    cdspell: bool = false,

    /// Correct minor spelling errors in directory names during completion.
    dirspell: bool = false,

    /// Allow comments in interactive shells (# at start of word).
    interactive_comments: bool = true,

    /// Send SIGHUP to all jobs on exit.
    huponexit: bool = false,

    /// Warn about running/stopped jobs on shell exit (requires 2nd exit).
    checkjobs: bool = false,

    /// Don't exit interactive shell if exec fails.
    execfail: bool = false,

    /// Perform quote expansion within ${...}.
    extquote: bool = true,

    /// Apply FIGNORE to filename completion results.
    force_fignore: bool = true,

    /// Attempt hostname completion on words containing @.
    hostcomplete: bool = true,

    /// Save multi-line commands with embedded newlines.
    lithist: bool = false,

    /// Don't attempt completion on empty command line.
    no_empty_cmd_completion: bool = false,

    /// Enable programmable completion.
    progcomp: bool = true,

    /// Expand variables in PS1/PS2/PS4.
    promptvars: bool = true,

    /// Print error message for invalid shift count.
    shift_verbose: bool = false,

    /// Make echo expand backslash escapes by default.
    xpg_echo: bool = false,

    /// Case-insensitive pattern matching in case and [[.
    nocasematch: bool = false,

    /// Correct minor spelling errors in directory arguments to cd.
    direxpand: bool = false,

    /// Check that hashed command exists before executing.
    checkhash: bool = false,

    /// Include filenames beginning with . in pattern expansion.
    globasciiranges: bool = true,

    /// Complete hostnames from /etc/hosts.
    complete_fullquote: bool = true,

    /// Attempt to save all lines of a multi-line command in same entry.
    cmdhist_enabled: bool = true,
};

/// Combined shell options.
pub const ShellOptions = struct {
    set: SetOptions = .{},
    shopt: ShoptOptions = .{},

    /// Initialize with default options.
    pub fn init() ShellOptions {
        return .{
            .set = .{},
            .shopt = .{},
        };
    }

    /// Get a set option by its short flag character.
    pub fn getSetOption(self: *const ShellOptions, flag: u8) ?bool {
        return switch (flag) {
            'e' => self.set.errexit,
            'E' => self.set.errtrace,
            'x' => self.set.xtrace,
            'u' => self.set.nounset,
            'n' => self.set.noexec,
            'v' => self.set.verbose,
            'f' => self.set.noglob,
            'C' => self.set.noclobber,
            else => null,
        };
    }

    /// Set a set option by its short flag character.
    pub fn setSetOption(self: *ShellOptions, flag: u8, value: bool) bool {
        switch (flag) {
            'e' => self.set.errexit = value,
            'E' => self.set.errtrace = value,
            'x' => self.set.xtrace = value,
            'u' => self.set.nounset = value,
            'n' => self.set.noexec = value,
            'v' => self.set.verbose = value,
            'f' => self.set.noglob = value,
            'C' => self.set.noclobber = value,
            else => return false,
        }
        return true;
    }

    /// Get a set option by its long name.
    pub fn getSetOptionByName(self: *const ShellOptions, name: []const u8) ?bool {
        const std = @import("std");
        if (std.mem.eql(u8, name, "errexit")) return self.set.errexit;
        if (std.mem.eql(u8, name, "errtrace")) return self.set.errtrace;
        if (std.mem.eql(u8, name, "xtrace")) return self.set.xtrace;
        if (std.mem.eql(u8, name, "nounset")) return self.set.nounset;
        if (std.mem.eql(u8, name, "pipefail")) return self.set.pipefail;
        if (std.mem.eql(u8, name, "noexec")) return self.set.noexec;
        if (std.mem.eql(u8, name, "verbose")) return self.set.verbose;
        if (std.mem.eql(u8, name, "noglob")) return self.set.noglob;
        if (std.mem.eql(u8, name, "noclobber")) return self.set.noclobber;
        return null;
    }

    /// Set a set option by its long name.
    pub fn setSetOptionByName(self: *ShellOptions, name: []const u8, value: bool) bool {
        const std = @import("std");
        if (std.mem.eql(u8, name, "errexit")) {
            self.set.errexit = value;
            return true;
        }
        if (std.mem.eql(u8, name, "errtrace")) {
            self.set.errtrace = value;
            return true;
        }
        if (std.mem.eql(u8, name, "xtrace")) {
            self.set.xtrace = value;
            return true;
        }
        if (std.mem.eql(u8, name, "nounset")) {
            self.set.nounset = value;
            return true;
        }
        if (std.mem.eql(u8, name, "pipefail")) {
            self.set.pipefail = value;
            return true;
        }
        if (std.mem.eql(u8, name, "noexec")) {
            self.set.noexec = value;
            return true;
        }
        if (std.mem.eql(u8, name, "verbose")) {
            self.set.verbose = value;
            return true;
        }
        if (std.mem.eql(u8, name, "noglob")) {
            self.set.noglob = value;
            return true;
        }
        if (std.mem.eql(u8, name, "noclobber")) {
            self.set.noclobber = value;
            return true;
        }
        return false;
    }

    /// Get a shopt option by name.
    pub fn getShoptOption(self: *const ShellOptions, name: []const u8) ?bool {
        const std = @import("std");
        if (std.mem.eql(u8, name, "extglob")) return self.shopt.extglob;
        if (std.mem.eql(u8, name, "nullglob")) return self.shopt.nullglob;
        if (std.mem.eql(u8, name, "dotglob")) return self.shopt.dotglob;
        if (std.mem.eql(u8, name, "nocaseglob")) return self.shopt.nocaseglob;
        if (std.mem.eql(u8, name, "globstar")) return self.shopt.globstar;
        if (std.mem.eql(u8, name, "failglob")) return self.shopt.failglob;
        if (std.mem.eql(u8, name, "expand_aliases")) return self.shopt.expand_aliases;
        if (std.mem.eql(u8, name, "sourcepath")) return self.shopt.sourcepath;
        if (std.mem.eql(u8, name, "checkwinsize")) return self.shopt.checkwinsize;
        if (std.mem.eql(u8, name, "histappend")) return self.shopt.histappend;
        if (std.mem.eql(u8, name, "cmdhist")) return self.shopt.cmdhist;
        if (std.mem.eql(u8, name, "autocd")) return self.shopt.autocd;
        if (std.mem.eql(u8, name, "cdspell")) return self.shopt.cdspell;
        if (std.mem.eql(u8, name, "dirspell")) return self.shopt.dirspell;
        if (std.mem.eql(u8, name, "interactive_comments")) return self.shopt.interactive_comments;
        if (std.mem.eql(u8, name, "huponexit")) return self.shopt.huponexit;
        if (std.mem.eql(u8, name, "checkjobs")) return self.shopt.checkjobs;
        if (std.mem.eql(u8, name, "execfail")) return self.shopt.execfail;
        if (std.mem.eql(u8, name, "extquote")) return self.shopt.extquote;
        if (std.mem.eql(u8, name, "force_fignore")) return self.shopt.force_fignore;
        if (std.mem.eql(u8, name, "hostcomplete")) return self.shopt.hostcomplete;
        if (std.mem.eql(u8, name, "lithist")) return self.shopt.lithist;
        if (std.mem.eql(u8, name, "no_empty_cmd_completion")) return self.shopt.no_empty_cmd_completion;
        if (std.mem.eql(u8, name, "progcomp")) return self.shopt.progcomp;
        if (std.mem.eql(u8, name, "promptvars")) return self.shopt.promptvars;
        if (std.mem.eql(u8, name, "shift_verbose")) return self.shopt.shift_verbose;
        if (std.mem.eql(u8, name, "xpg_echo")) return self.shopt.xpg_echo;
        if (std.mem.eql(u8, name, "nocasematch")) return self.shopt.nocasematch;
        if (std.mem.eql(u8, name, "direxpand")) return self.shopt.direxpand;
        if (std.mem.eql(u8, name, "checkhash")) return self.shopt.checkhash;
        if (std.mem.eql(u8, name, "globasciiranges")) return self.shopt.globasciiranges;
        if (std.mem.eql(u8, name, "complete_fullquote")) return self.shopt.complete_fullquote;
        return null;
    }

    /// Set a shopt option by name.
    pub fn setShoptOption(self: *ShellOptions, name: []const u8, value: bool) bool {
        const std = @import("std");
        if (std.mem.eql(u8, name, "extglob")) {
            self.shopt.extglob = value;
            return true;
        }
        if (std.mem.eql(u8, name, "nullglob")) {
            self.shopt.nullglob = value;
            return true;
        }
        if (std.mem.eql(u8, name, "dotglob")) {
            self.shopt.dotglob = value;
            return true;
        }
        if (std.mem.eql(u8, name, "nocaseglob")) {
            self.shopt.nocaseglob = value;
            return true;
        }
        if (std.mem.eql(u8, name, "globstar")) {
            self.shopt.globstar = value;
            return true;
        }
        if (std.mem.eql(u8, name, "failglob")) {
            self.shopt.failglob = value;
            return true;
        }
        if (std.mem.eql(u8, name, "expand_aliases")) {
            self.shopt.expand_aliases = value;
            return true;
        }
        if (std.mem.eql(u8, name, "sourcepath")) {
            self.shopt.sourcepath = value;
            return true;
        }
        if (std.mem.eql(u8, name, "checkwinsize")) {
            self.shopt.checkwinsize = value;
            return true;
        }
        if (std.mem.eql(u8, name, "histappend")) {
            self.shopt.histappend = value;
            return true;
        }
        if (std.mem.eql(u8, name, "cmdhist")) {
            self.shopt.cmdhist = value;
            return true;
        }
        if (std.mem.eql(u8, name, "autocd")) {
            self.shopt.autocd = value;
            return true;
        }
        if (std.mem.eql(u8, name, "cdspell")) {
            self.shopt.cdspell = value;
            return true;
        }
        if (std.mem.eql(u8, name, "dirspell")) {
            self.shopt.dirspell = value;
            return true;
        }
        if (std.mem.eql(u8, name, "interactive_comments")) {
            self.shopt.interactive_comments = value;
            return true;
        }
        if (std.mem.eql(u8, name, "huponexit")) {
            self.shopt.huponexit = value;
            return true;
        }
        if (std.mem.eql(u8, name, "checkjobs")) {
            self.shopt.checkjobs = value;
            return true;
        }
        if (std.mem.eql(u8, name, "execfail")) {
            self.shopt.execfail = value;
            return true;
        }
        if (std.mem.eql(u8, name, "extquote")) {
            self.shopt.extquote = value;
            return true;
        }
        if (std.mem.eql(u8, name, "force_fignore")) {
            self.shopt.force_fignore = value;
            return true;
        }
        if (std.mem.eql(u8, name, "hostcomplete")) {
            self.shopt.hostcomplete = value;
            return true;
        }
        if (std.mem.eql(u8, name, "lithist")) {
            self.shopt.lithist = value;
            return true;
        }
        if (std.mem.eql(u8, name, "no_empty_cmd_completion")) {
            self.shopt.no_empty_cmd_completion = value;
            return true;
        }
        if (std.mem.eql(u8, name, "progcomp")) {
            self.shopt.progcomp = value;
            return true;
        }
        if (std.mem.eql(u8, name, "promptvars")) {
            self.shopt.promptvars = value;
            return true;
        }
        if (std.mem.eql(u8, name, "shift_verbose")) {
            self.shopt.shift_verbose = value;
            return true;
        }
        if (std.mem.eql(u8, name, "xpg_echo")) {
            self.shopt.xpg_echo = value;
            return true;
        }
        if (std.mem.eql(u8, name, "nocasematch")) {
            self.shopt.nocasematch = value;
            return true;
        }
        if (std.mem.eql(u8, name, "direxpand")) {
            self.shopt.direxpand = value;
            return true;
        }
        if (std.mem.eql(u8, name, "checkhash")) {
            self.shopt.checkhash = value;
            return true;
        }
        if (std.mem.eql(u8, name, "globasciiranges")) {
            self.shopt.globasciiranges = value;
            return true;
        }
        if (std.mem.eql(u8, name, "complete_fullquote")) {
            self.shopt.complete_fullquote = value;
            return true;
        }
        return false;
    }

    /// Get list of all shopt option names for completion.
    pub fn getShoptOptionNames() []const []const u8 {
        return &[_][]const u8{
            "autocd",
            "cdspell",
            "checkhash",
            "checkjobs",
            "checkwinsize",
            "cmdhist",
            "complete_fullquote",
            "direxpand",
            "dirspell",
            "dotglob",
            "execfail",
            "expand_aliases",
            "extglob",
            "extquote",
            "failglob",
            "force_fignore",
            "globasciiranges",
            "globstar",
            "histappend",
            "hostcomplete",
            "huponexit",
            "interactive_comments",
            "lithist",
            "no_empty_cmd_completion",
            "nocaseglob",
            "nocasematch",
            "nullglob",
            "progcomp",
            "promptvars",
            "shift_verbose",
            "sourcepath",
            "xpg_echo",
        };
    }
};

// ========================================
// Tests
// ========================================

test "ShellOptions defaults" {
    const opts = ShellOptions.init();

    // Set options default to false
    try @import("std").testing.expect(!opts.set.errexit);
    try @import("std").testing.expect(!opts.set.xtrace);
    try @import("std").testing.expect(!opts.set.pipefail);

    // Shopt extglob defaults to true
    try @import("std").testing.expect(opts.shopt.extglob);
    try @import("std").testing.expect(!opts.shopt.globstar);
}

test "ShellOptions set by flag" {
    var opts = ShellOptions.init();

    try @import("std").testing.expect(!opts.set.errexit);
    try @import("std").testing.expect(opts.setSetOption('e', true));
    try @import("std").testing.expect(opts.set.errexit);

    // Unknown flag returns false
    try @import("std").testing.expect(!opts.setSetOption('z', true));
}

test "ShellOptions get by name" {
    var opts = ShellOptions.init();

    try @import("std").testing.expectEqual(false, opts.getSetOptionByName("errexit").?);
    try @import("std").testing.expect(opts.setSetOptionByName("errexit", true));
    try @import("std").testing.expectEqual(true, opts.getSetOptionByName("errexit").?);

    // Unknown name returns null
    try @import("std").testing.expect(opts.getSetOptionByName("unknown") == null);
}
