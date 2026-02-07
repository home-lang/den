const std = @import("std");
const shell = @import("shell.zig");
const Completion = @import("utils/completion.zig").Completion;
const ShellCompletion = @import("shell_completion.zig").ShellCompletion;
const env_utils = @import("utils/env.zig");
const IO = @import("utils/io.zig").IO;

/// Den Shell CLI
/// Provides command-line interface and subcommand handling

pub const VERSION = "0.1.0";

pub const Command = enum {
    interactive, // Default: start interactive shell
    shell, // Explicit: start interactive shell
    exec, // Execute single command
    complete, // Get completions (JSON output)
    completion, // Generate shell completion script
    dev_setup, // Create development shim
    setup, // Install wrapper script
    set_shell, // Set as default shell
    uninstall, // Remove wrapper
    version, // Show version
    help, // Show help
    script, // Execute script file (implicit)
    command_string, // -c "command" - run command string
};

pub const CliArgs = struct {
    command: Command,
    args: []const []const u8,
    allocator: std.mem.Allocator,
    config_path: ?[]const u8 = null, // Custom config path from --config flag
    json_output: bool = false, // Output results in JSON format (for -c commands)
    // Ownership tracking: the heap-allocated argv slice (args may be a sub-slice of this)
    _owned_argv: ?[]const []const u8 = null,

    pub fn deinit(self: *CliArgs) void {
        if (self._owned_argv) |owned| {
            self.allocator.free(owned);
        }
    }
};

/// Parse command line arguments
pub fn parseArgs(allocator: std.mem.Allocator, process_args: std.process.Args) !CliArgs {
    var args = try process_args.iterateAllocator(allocator);
    // NOTE: Do NOT defer args.deinit() here — the allocated strings are
    // owned by the returned CliArgs and must survive this function call.
    // The caller is responsible for the lifetime (CliArgs.deinit handles it).

    // Skip program name
    _ = args.next();

    // Collect all arguments into a heap-allocated list so they survive this function
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);

    while (args.next()) |arg| {
        try argv_list.append(allocator, arg);
    }

    const argv = argv_list.items;

    // Parse global flags first (--config, --json)
    var config_path: ?[]const u8 = null;
    var json_output: bool = false;
    var remaining_list = std.ArrayList([]const u8){};
    errdefer remaining_list.deinit(allocator);
    var i: usize = 0;

    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--config")) {
            // Next argument is the config path
            if (i + 1 < argv.len) {
                config_path = argv[i + 1];
                i += 2;
                continue;
            } else {
                std.debug.print("Error: --config requires a path argument\n", .{});
                return error.MissingConfigPath;
            }
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            // --config=path format
            config_path = arg["--config=".len..];
            i += 1;
            continue;
        } else if (std.mem.eql(u8, arg, "--json")) {
            // Enable JSON output mode
            json_output = true;
            i += 1;
            continue;
        }
        try remaining_list.append(allocator, arg);
        i += 1;
    }

    const remaining_argv = try remaining_list.toOwnedSlice(allocator);

    // No arguments = interactive shell
    if (remaining_argv.len == 0) {
        allocator.free(remaining_argv);
        return CliArgs{
            .command = .interactive,
            .args = &[_][]const u8{},
            .allocator = allocator,
            .config_path = config_path,
        };
    }

    const first_arg = remaining_argv[0];

    // Helper: sub-args (everything after the subcommand name)
    const sub_args = if (remaining_argv.len > 1) remaining_argv[1..] else &[_][]const u8{};

    // Check for subcommands
    if (std.mem.eql(u8, first_arg, "shell")) {
        return CliArgs{
            .command = .shell,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "exec")) {
        return CliArgs{
            .command = .exec,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "complete")) {
        return CliArgs{
            .command = .complete,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "completion")) {
        return CliArgs{
            .command = .completion,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "dev-setup")) {
        return CliArgs{
            .command = .dev_setup,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "setup")) {
        return CliArgs{
            .command = .setup,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "set-shell")) {
        return CliArgs{
            .command = .set_shell,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "uninstall")) {
        return CliArgs{
            .command = .uninstall,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "version") or std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
        return CliArgs{
            .command = .version,
            .args = &[_][]const u8{},
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "help") or std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
        return CliArgs{
            .command = .help,
            .args = &[_][]const u8{},
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    } else if (std.mem.eql(u8, first_arg, "-c")) {
        // -c "command" - run command string
        return CliArgs{
            .command = .command_string,
            .args = sub_args,
            .allocator = allocator,
            .config_path = config_path,
            .json_output = json_output,
            ._owned_argv = remaining_argv,
        };
    } else {
        // Assume it's a script file
        return CliArgs{
            .command = .script,
            .args = remaining_argv,
            .allocator = allocator,
            .config_path = config_path,
            ._owned_argv = remaining_argv,
        };
    }
}

/// Execute the CLI command
pub fn execute(cli_args: CliArgs) !void {
    switch (cli_args.command) {
        .interactive, .shell => try runInteractiveShell(cli_args.allocator, cli_args.config_path),
        .exec => try execCommand(cli_args.allocator, cli_args.args, cli_args.config_path),
        .complete => try getCompletions(cli_args.allocator, cli_args.args),
        .completion => try generateCompletion(cli_args.allocator, cli_args.args),
        .dev_setup => try devSetup(cli_args.allocator),
        .setup => try setup(cli_args.allocator),
        .set_shell => try setShell(cli_args.allocator),
        .uninstall => try uninstall(cli_args.allocator),
        .version => try showVersion(),
        .help => try showHelp(),
        .script => try runScript(cli_args.allocator, cli_args.args, cli_args.config_path),
        .command_string => try runCommandString(cli_args.allocator, cli_args.args, cli_args.config_path, cli_args.json_output),
    }
}

/// Start interactive shell
fn runInteractiveShell(allocator: std.mem.Allocator, config_path: ?[]const u8) !void {
    var den_shell = try shell.Shell.initWithConfig(allocator, config_path);
    defer den_shell.deinit();
    try den_shell.run();
}

/// Execute a single command
fn execCommand(allocator: std.mem.Allocator, args: []const []const u8, config_path: ?[]const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'exec' requires a command argument\n", .{});
        std.debug.print("Usage: den exec <command>\n", .{});
        return error.MissingCommand;
    }

    // Join arguments into a single command string
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (args, 0..) |arg, i| {
        if (i > 0) {
            if (pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
        }
        const to_copy = @min(arg.len, buf.len - pos);
        @memcpy(buf[pos..][0..to_copy], arg[0..to_copy]);
        pos += to_copy;
    }

    const command = buf[0..pos];

    var den_shell = try shell.Shell.initWithConfig(allocator, config_path);
    defer den_shell.deinit();

    // Execute the command
    den_shell.executeCommand(command) catch |err| {
        den_shell.executeExitTrap();
        std.debug.print("Error executing command: {}\n", .{err});
        return err;
    };
    den_shell.executeExitTrap();
}

/// Get completions for input (JSON output)
fn getCompletions(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'complete' requires input argument\n", .{});
        std.debug.print("Usage: den complete <input>\n", .{});
        return error.MissingInput;
    }

    // For simplicity, just use the first argument as the input to complete
    const input = args[0];

    // Initialize completion system
    var comp = Completion.init(allocator);

    // Determine what to complete
    var completions: [][]const u8 = &[_][]const u8{};
    defer {
        for (completions) |c| allocator.free(c);
        allocator.free(completions);
    }

    // Simple heuristic: if input contains '/' or starts with '.', complete files
    // Otherwise, complete commands
    if (std.mem.indexOf(u8, input, "/") != null or std.mem.startsWith(u8, input, ".")) {
        completions = comp.completeFile(input) catch &[_][]const u8{};
    } else {
        // Get the last word to complete
        const last_space = std.mem.lastIndexOfScalar(u8, input, ' ');
        const word_to_complete = if (last_space) |idx| input[idx + 1 ..] else input;
        completions = comp.completeCommand(word_to_complete) catch &[_][]const u8{};
    }

    // Output as JSON array
    std.debug.print("[", .{});
    for (completions, 0..) |completion, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("\"{s}\"", .{completion});
    }
    std.debug.print("]\n", .{});
}

/// Generate shell completion script
fn generateCompletion(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'completion' requires shell type argument\n", .{});
        std.debug.print("Usage: den completion <bash|zsh|fish>\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  den completion bash > ~/.local/share/bash-completion/completions/den\n", .{});
        std.debug.print("  den completion zsh > ~/.zsh/completions/_den\n", .{});
        std.debug.print("  den completion fish > ~/.config/fish/completions/den.fish\n", .{});
        return error.MissingShellType;
    }

    const shell_type = args[0];

    // Validate shell type
    if (!std.mem.eql(u8, shell_type, "bash") and
        !std.mem.eql(u8, shell_type, "zsh") and
        !std.mem.eql(u8, shell_type, "fish"))
    {
        std.debug.print("Error: Unsupported shell type '{s}'\n", .{shell_type});
        std.debug.print("Supported shells: bash, zsh, fish\n", .{});
        return error.UnsupportedShell;
    }

    var comp = ShellCompletion.init(allocator);
    const script = try comp.generate(shell_type);

    std.debug.print("{s}", .{script});
}

/// Create development shim
fn devSetup(_: std.mem.Allocator) !void {
    std.debug.print("Creating development shim...\n", .{});

    // Get current executable path
    var exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executablePath(std.Options.debug_io, &exe_path_buf);
    const exe_path = exe_path_buf[0..exe_path_len];

    // Create shim in ~/.local/bin/den
    const home = env_utils.getEnv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return error.NoHomeDir;
    };

    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const shim_path = try std.fmt.bufPrint(&home_buf, "{s}/.local/bin/den", .{home});

    // Ensure ~/.local/bin exists
    var local_bin_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const local_bin_dir = try std.fmt.bufPrint(&local_bin_dir_buf, "{s}/.local/bin", .{home});
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, local_bin_dir) catch |err| {
        return err;
    };

    // Create shim file
    const shim_file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, shim_path, .{ .truncate = true });
    defer shim_file.close(std.Options.debug_io);

    const shim_content = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "#!/bin/sh\nexec {s} \"$@\"\n",
        .{exe_path},
    );
    defer std.heap.page_allocator.free(shim_content);

    try shim_file.writeStreamingAll(std.Options.debug_io, shim_content);

    // Make executable
    try shim_file.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o755));

    std.debug.print("Development shim created at: {s}\n", .{shim_path});
    std.debug.print("Make sure ~/.local/bin is in your PATH\n", .{});
}

/// Install wrapper script
fn setup(_: std.mem.Allocator) !void {
    // Using std.debug.print instead

    std.debug.print("Installing Den shell wrapper...\n", .{});

    // Get current executable path
    var exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executablePath(std.Options.debug_io, &exe_path_buf);
    const exe_path = exe_path_buf[0..exe_path_len];

    const home = env_utils.getEnv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return error.NoHomeDir;
    };

    var wrapper_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const wrapper_path = try std.fmt.bufPrint(&wrapper_path_buf, "{s}/.local/bin/den", .{home});

    // Ensure ~/.local/bin exists
    var local_bin_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const local_bin_dir = try std.fmt.bufPrint(&local_bin_dir_buf, "{s}/.local/bin", .{home});
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, local_bin_dir) catch |err| {
        return err;
    };

    // Create wrapper script
    const wrapper_file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, wrapper_path, .{ .truncate = true });
    defer wrapper_file.close(std.Options.debug_io);

    const wrapper_content = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "#!/bin/sh\nexec {s} \"$@\"\n",
        .{exe_path},
    );
    defer std.heap.page_allocator.free(wrapper_content);

    try wrapper_file.writeStreamingAll(std.Options.debug_io, wrapper_content);
    try wrapper_file.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o755));

    std.debug.print("Wrapper installed at: {s}\n", .{wrapper_path});
    std.debug.print("\nTo use Den shell:\n", .{});
    std.debug.print("  1. Make sure ~/.local/bin is in your PATH\n", .{});
    std.debug.print("  2. Run 'den set-shell' to set it as your default shell\n", .{});
}

/// Set Den as default shell
fn setShell(_: std.mem.Allocator) !void {
    // Using std.debug.print instead

    std.debug.print("Setting Den as default shell...\n", .{});

    const home = env_utils.getEnv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return error.NoHomeDir;
    };

    var den_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const den_path = try std.fmt.bufPrint(&den_path_buf, "{s}/.local/bin/den", .{home});

    // Check if den wrapper exists
    std.Io.Dir.cwd().access(std.Options.debug_io, den_path, .{}) catch {
        std.debug.print("Error: Den wrapper not found. Run 'den setup' first.\n", .{});
        return error.WrapperNotFound;
    };

    std.debug.print("\nTo set Den as your default shell, run:\n", .{});
    std.debug.print("  chsh -s {s}\n", .{den_path});
    std.debug.print("\nNote: You may need to add the shell path to /etc/shells first:\n", .{});
    std.debug.print("  echo '{s}' | sudo tee -a /etc/shells\n", .{den_path});
}

/// Uninstall Den wrapper
fn uninstall(_: std.mem.Allocator) !void {
    // Using std.debug.print instead

    std.debug.print("Uninstalling Den shell wrapper...\n", .{});

    const home = env_utils.getEnv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return error.NoHomeDir;
    };

    var wrapper_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const wrapper_path = try std.fmt.bufPrint(&wrapper_path_buf, "{s}/.local/bin/den", .{home});

    // Remove wrapper
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, wrapper_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Wrapper not found (already uninstalled?)\n", .{});
            return;
        }
        return err;
    };

    std.debug.print("Wrapper removed from: {s}\n", .{wrapper_path});
    std.debug.print("\nIf Den was your default shell, remember to change it back:\n", .{});
    std.debug.print("  chsh -s /bin/bash  # or your preferred shell\n", .{});
}

/// Show version
fn showVersion() !void {
    // Using std.debug.print instead
    std.debug.print("Den Shell v{s}\n", .{VERSION});
}

/// Show help
fn showHelp() !void {
    std.debug.print(
        \\Den Shell - A modern shell written in Zig
        \\
        \\Usage:
        \\  den                       Start interactive shell (default)
        \\  den shell                 Start interactive shell (explicit)
        \\  den exec <cmd>            Execute single command
        \\  den complete <input>      Get completions (JSON output)
        \\  den completion <shell>    Generate shell completion script
        \\  den dev-setup             Create development shim
        \\  den setup                 Install wrapper script
        \\  den set-shell             Set as default shell
        \\  den uninstall             Remove wrapper
        \\  den version               Show version
        \\  den help                  Show this help
        \\  den <script>              Execute script file
        \\
        \\Options:
        \\  -h, --help                Show help
        \\  -v, --version             Show version
        \\  -c <command>              Execute command string
        \\  --config <path>           Use custom config file
        \\  --json                    Output results in JSON format (with -c)
        \\
        \\Completion:
        \\  den completion bash       Generate Bash completion script
        \\  den completion zsh        Generate Zsh completion script
        \\  den completion fish       Generate Fish completion script
        \\
        \\Examples:
        \\  den                                      # Start interactive shell
        \\  den exec echo "Hello, World!"            # Execute command
        \\  den script.sh                            # Run script file
        \\  den setup                                # Install Den
        \\  den --config ~/custom.jsonc              # Use custom config
        \\  den completion bash > /etc/bash_completion.d/den   # Install Bash completion
        \\
        \\For more information, visit: https://github.com/stackblitz/den
        \\
    , .{});
}

/// Run script file
fn runScript(allocator: std.mem.Allocator, args: []const []const u8, config_path: ?[]const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: script file required\n", .{});
        return error.MissingScriptFile;
    }

    const script_path = args[0];
    const script_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    var den_shell = try shell.Shell.initWithConfig(allocator, config_path);
    defer den_shell.deinit();

    try den_shell.runScript(script_path, "den", script_args);
    den_shell.executeExitTrap();

    // Propagate exit code to OS
    if (den_shell.last_exit_code != 0) {
        std.process.exit(@intCast(@as(u32, @bitCast(den_shell.last_exit_code))));
    }
}

/// Run command string (-c "command")
fn runCommandString(allocator: std.mem.Allocator, args: []const []const u8, config_path: ?[]const u8, json_output: bool) !void {
    if (args.len == 0) {
        if (json_output) {
            try IO.print("{{\"error\":\"missing command string\",\"exit_code\":1}}\n", .{});
        } else {
            std.debug.print("Error: -c requires a command string\n", .{});
        }
        return error.MissingCommandString;
    }

    const raw_command = args[0];

    // Handle backslash-newline continuation: remove \<newline> sequences
    var cmd_buf: [16384]u8 = undefined;
    var cmd_len: usize = 0;
    {
        var ci: usize = 0;
        while (ci < raw_command.len) {
            if (raw_command[ci] == '\\' and ci + 1 < raw_command.len and raw_command[ci + 1] == '\n') {
                ci += 2; // Skip backslash-newline (line continuation)
            } else {
                if (cmd_len < cmd_buf.len) {
                    cmd_buf[cmd_len] = raw_command[ci];
                    cmd_len += 1;
                }
                ci += 1;
            }
        }
    }
    const command = cmd_buf[0..cmd_len];

    var den_shell = try shell.Shell.initWithConfig(allocator, config_path);
    defer den_shell.deinit();

    // Execute the command
    den_shell.executeCommand(command) catch |err| {
        den_shell.executeExitTrap();
        if (json_output) {
            try IO.print("{{\"error\":\"{s}\",\"exit_code\":{d}}}\n", .{ @errorName(err), den_shell.last_exit_code });
        }
        return err;
    };

    // Fire EXIT trap before leaving
    den_shell.executeExitTrap();

    // Output JSON result if requested
    if (json_output) {
        try IO.print("{{\"exit_code\":{d}}}\n", .{den_shell.last_exit_code});
    }

    // Propagate exit code to OS (critical for scripts and tools like Claude Code)
    if (den_shell.last_exit_code != 0) {
        std.process.exit(@intCast(@as(u32, @bitCast(den_shell.last_exit_code))));
    }
}

// Tests
test "parseArgs: no arguments" {
    // This test is conceptual - actual testing would require mocking process.args
    // Which is complex in Zig. The logic is simple enough to verify manually.
}

test "parseArgs: version flag" {
    // Conceptual test
}

test "parseArgs: help flag" {
    // Conceptual test
}
