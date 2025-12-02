const std = @import("std");
const types = @import("types/mod.zig");
const parser_mod = @import("parser/mod.zig");
const executor_mod = @import("executor/mod.zig");
const IO = @import("utils/io.zig").IO;
const Terminal = @import("utils/terminal.zig");
const LineEditor = Terminal.LineEditor;
const Completion = @import("utils/completion.zig").Completion;
const Expansion = @import("utils/expansion.zig").Expansion;
const Glob = @import("utils/glob.zig").Glob;
const BraceExpander = @import("utils/brace.zig").BraceExpander;
const ScriptManager = @import("scripting/script_manager.zig").ScriptManager;
const FunctionManager = @import("scripting/functions.zig").FunctionManager;
const ControlFlowParser = @import("scripting/control_flow.zig").ControlFlowParser;
const ControlFlowExecutor = @import("scripting/control_flow.zig").ControlFlowExecutor;
const PluginRegistry = @import("plugins/interface.zig").PluginRegistry;
const PluginManager = @import("plugins/manager.zig").PluginManager;
const HookType = @import("plugins/interface.zig").HookType;
const HookContext = @import("plugins/interface.zig").HookContext;
const AutoSuggestPlugin = @import("plugins/builtin_plugins_advanced.zig").AutoSuggestPlugin;
const HighlightPlugin = @import("plugins/builtin_plugins_advanced.zig").HighlightPlugin;
const ScriptSuggesterPlugin = @import("plugins/builtin_plugins_advanced.zig").ScriptSuggesterPlugin;
const concurrency = @import("utils/concurrency.zig");
const config_loader = @import("config_loader.zig");
const builtin = @import("builtin");
const env_utils = @import("utils/env.zig");
const PromptRenderer = @import("prompt/renderer.zig").PromptRenderer;
const PromptContext = @import("prompt/types.zig").PromptContext;
const PromptTemplate = @import("prompt/types.zig").PromptTemplate;
const SystemInfo = @import("prompt/sysinfo.zig").SystemInfo;
const GitModule = @import("prompt/git.zig").GitModule;
const AsyncGitFetcher = @import("prompt/async_git.zig").AsyncGitFetcher;
const ansi = @import("utils/ansi.zig");
const signals = @import("utils/signals.zig");
const HistoryExpansion = @import("utils/history_expansion.zig").HistoryExpansion;
const ContextCompletion = @import("utils/context_completion.zig").ContextCompletion;
const CompletionRegistry = @import("utils/completion_registry.zig").CompletionRegistry;
const CompletionSpec = @import("utils/completion_registry.zig").CompletionSpec;

/// Format a parser error into a user-friendly message.
fn formatParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.UnexpectedEndOfInput => "unexpected end of input (missing operand after operator)",
        error.RedirectionMissingTarget => "missing target for redirection",
        error.InvalidFileDescriptor => "invalid file descriptor in redirection",
        error.EmptyCommand => "empty command",
        error.TooManyOperators => "too many operators in command (limit: 31)",
        error.TooManyCommands => "too many commands in pipeline (limit: 32)",
        error.TooManyArguments => "too many arguments (limit: 128)",
        error.TooManyRedirections => "too many redirections (limit: 16)",
        error.TooManyTokens => "command too complex (limit: 1024 tokens)",
        else => "syntax error",
    };
}

/// Extract exit status from wait status (cross-platform)
fn getExitStatus(status: u32) i32 {
    if (builtin.os.tag == .windows) {
        // Windows uses the status directly
        return @intCast(status);
    } else {
        // POSIX systems use WEXITSTATUS macro
        return std.posix.W.EXITSTATUS(status);
    }
}

/// Cross-platform getenv wrapper
fn getenv(key: []const u8) ?[]const u8 {
    return env_utils.getEnv(key);
}

/// Get modification time of a config file (for hot-reload)
fn getConfigMtime(path: ?[]const u8) i128 {
    const config_path = path orelse return 0;
    const file = std.fs.cwd().openFile(config_path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.mtime.nanoseconds;
}

/// Job status
const JobStatus = enum {
    running,
    stopped,
    done,
};

/// Cross-platform process ID type
const ProcessId = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.pid_t;

/// Background job information
const BackgroundJob = struct {
    pid: ProcessId,
    job_id: usize,
    command: []const u8,
    status: JobStatus,
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    config: types.DenConfig,
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    last_exit_code: i32,
    background_jobs: [16]?BackgroundJob,
    background_jobs_count: usize,
    next_job_id: usize,
    last_background_pid: std.posix.pid_t,
    history: [1000]?[]const u8,
    history_count: usize,
    history_file_path: []const u8,
    history_expander: HistoryExpansion,
    dir_stack: [32]?[]const u8,
    dir_stack_count: usize,
    positional_params: [64]?[]const u8,
    positional_params_count: usize,
    shell_name: []const u8,
    last_arg: []const u8,
    // Shell options
    option_errexit: bool, // set -e: exit on error
    option_errtrace: bool, // set -E: inherit ERR trap
    option_xtrace: bool, // set -x: print commands before execution
    option_nounset: bool, // set -u: error on unset variable
    option_pipefail: bool, // set -o pipefail: pipeline returns rightmost non-zero exit
    option_noexec: bool, // set -n: read commands but don't execute (syntax check)
    option_verbose: bool, // set -v: print input lines as read
    option_noglob: bool, // set -f: disable filename expansion (globbing)
    option_noclobber: bool, // set -C: prevent overwriting files with >
    current_line: usize, // For error reporting
    // Script management
    script_manager: ScriptManager,
    // Function management
    function_manager: FunctionManager,
    // Signal handling
    signal_handlers: std.StringHashMap([]const u8),
    // Command path cache (for hash builtin)
    command_cache: std.StringHashMap([]const u8),
    // Named directories (zsh-style hash -d)
    named_dirs: std.StringHashMap([]const u8),
    // Array variables (zsh-style arrays)
    arrays: std.StringHashMap([][]const u8),
    // Custom completion specifications (like bash's complete)
    completion_registry: CompletionRegistry,
    // Plugin system
    plugin_registry: PluginRegistry,
    plugin_manager: PluginManager,
    // Builtin plugins (optional)
    auto_suggest: ?AutoSuggestPlugin,
    highlighter: ?HighlightPlugin,
    script_suggester: ?ScriptSuggesterPlugin,
    // Concurrency
    thread_pool: concurrency.ThreadPool,
    // Interactive mode
    is_interactive: bool,
    line_editor: ?LineEditor,
    // Prompt rendering
    prompt_renderer: ?PromptRenderer,
    prompt_context: PromptContext,
    // Async git fetcher for non-blocking prompts
    async_git: AsyncGitFetcher,
    // REPL multiline input state (for function definitions)
    multiline_buffer: [100]?[]const u8,
    multiline_count: usize,
    multiline_brace_count: i32,
    multiline_mode: MultilineMode,
    // Flag to prevent re-entrancy in C-style for loop execution
    in_cstyle_for_body: bool,
    // Flag for break statement in loops
    break_requested: bool,
    // Config hot-reload tracking
    config_source: config_loader.ConfigSource,
    config_last_mtime: i128,

    const MultilineMode = enum {
        none,
        function_def,
    };

    pub fn init(allocator: std.mem.Allocator) !Shell {
        return initWithConfig(allocator, null);
    }

    /// Initialize shell with a custom config path
    /// If config_path is provided, it takes priority over default search paths
    pub fn initWithConfig(allocator: std.mem.Allocator, config_path: ?[]const u8) !Shell {
        // Load configuration from files and environment variables (with source tracking)
        const config_result = config_loader.loadConfigWithPathAndSource(allocator, config_path) catch config_loader.ConfigLoadResult{
            .config = types.DenConfig{},
            .source = .{ .path = null, .source_type = .default },
        };
        const config = config_result.config;
        const config_source = config_result.source;

        // Get initial mtime for hot-reload
        const config_mtime = getConfigMtime(config_source.path);

        // Initialize environment from system
        var env = std.StringHashMap([]const u8).init(allocator);

        // Add some basic environment variables (cross-platform)
        // Note: Both keys and values must be allocated for proper cleanup
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch
            std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
            try allocator.dupe(u8, "/");
        const home_key = try allocator.dupe(u8, "HOME");
        try env.put(home_key, home);

        const path = std.process.getEnvVarOwned(allocator, "PATH") catch
            try allocator.dupe(u8, "/usr/bin:/bin");
        const path_key = try allocator.dupe(u8, "PATH");
        try env.put(path_key, path);

        // Load default environment variables from config
        if (config.environment.enabled) {
            // First, set defaults (only if not already set in system env)
            for (types.EnvironmentConfig.defaults) |default_var| {
                const existing = std.process.getEnvVarOwned(allocator, default_var.name) catch null;
                const key_copy = try allocator.dupe(u8, default_var.name);
                if (existing == null) {
                    const value_copy = try allocator.dupe(u8, default_var.value);
                    try env.put(key_copy, value_copy);
                } else {
                    try env.put(key_copy, existing.?);
                }
            }

            // Then, apply custom environment from config (these override defaults)
            if (config.environment.variables) |custom_vars| {
                for (custom_vars) |env_var| {
                    const value_copy = try allocator.dupe(u8, env_var.value);
                    // Free old key and value if exists
                    if (env.fetchRemove(env_var.name)) |old_kv| {
                        allocator.free(old_kv.key);
                        allocator.free(old_kv.value);
                    }
                    const key_copy = try allocator.dupe(u8, env_var.name);
                    try env.put(key_copy, value_copy);
                }
            }
        }

        // Build history file path: ~/.den_history
        var history_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const history_path = try std.fmt.bufPrint(&history_path_buf, "{s}/.den_history", .{home});
        const history_path_owned = try allocator.dupe(u8, history_path);

        // Initialize thread pool with automatic CPU detection
        const thread_pool = try concurrency.ThreadPool.init(allocator, 0);

        // Install signal handlers
        signals.installHandlers() catch |err| {
            std.debug.print("Warning: Failed to install signal handlers: {}\n", .{err});
        };

        var shell = Shell{
            .allocator = allocator,
            .running = false,
            .config = config,
            .environment = env,
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .last_exit_code = 0,
            .background_jobs = [_]?BackgroundJob{null} ** 16,
            .background_jobs_count = 0,
            .next_job_id = 1,
            .last_background_pid = if (@import("builtin").os.tag == .windows) undefined else 0,
            .history = [_]?[]const u8{null} ** 1000,
            .history_count = 0,
            .history_file_path = history_path_owned,
            .history_expander = HistoryExpansion.init(allocator),
            .dir_stack = [_]?[]const u8{null} ** 32,
            .dir_stack_count = 0,
            .positional_params = [_]?[]const u8{null} ** 64,
            .positional_params_count = 0,
            .shell_name = "den",
            .last_arg = "",
            .option_errexit = false,
            .option_errtrace = false,
            .option_xtrace = false,
            .option_nounset = false,
            .option_pipefail = false,
            .option_noexec = false,
            .option_verbose = false,
            .option_noglob = false,
            .option_noclobber = false,
            .current_line = 0,
            .script_manager = ScriptManager.init(allocator),
            .function_manager = FunctionManager.init(allocator),
            .signal_handlers = std.StringHashMap([]const u8).init(allocator),
            .command_cache = std.StringHashMap([]const u8).init(allocator),
            .named_dirs = std.StringHashMap([]const u8).init(allocator),
            .arrays = std.StringHashMap([][]const u8).init(allocator),
            .completion_registry = CompletionRegistry.init(allocator),
            .plugin_registry = PluginRegistry.init(allocator),
            .plugin_manager = PluginManager.init(allocator),
            .auto_suggest = null, // Initialized on demand
            .highlighter = null,  // Initialized on demand
            .script_suggester = null, // Initialized on demand
            .thread_pool = thread_pool,
            .is_interactive = false,
            .line_editor = null,
            .prompt_renderer = null,
            .prompt_context = PromptContext.init(allocator),
            .async_git = AsyncGitFetcher.init(allocator),
            .multiline_buffer = [_]?[]const u8{null} ** 100,
            .multiline_count = 0,
            .multiline_brace_count = 0,
            .multiline_mode = .none,
            .in_cstyle_for_body = false,
            .break_requested = false,
            .config_source = config_source,
            .config_last_mtime = config_mtime,
        };

        // Detect if stdin is a TTY
        if (@import("builtin").os.tag != .windows) {
            shell.is_interactive = std.posix.isatty(std.posix.STDIN_FILENO);
        }

        // Load history from file
        shell.loadHistory() catch {
            // Ignore errors loading history (file might not exist yet)
        };

        // Load aliases from config
        shell.loadAliasesFromConfig() catch {
            // Ignore errors loading aliases
        };

        // Execute shell_init hooks
        var init_context = HookContext{
            .hook_type = .shell_init,
            .data = null,
            .user_data = null,
            .allocator = allocator,
        };
        shell.plugin_registry.executeHooks(.shell_init, &init_context) catch {};

        // Set global completion config for tabCompletionFn
        setCompletionConfig(config.completion);

        return shell;
    }

    pub fn deinit(self: *Shell) void {
        // Clean up async git fetcher
        self.async_git.deinit();

        // Clean up prompt renderer
        if (self.prompt_renderer) |*renderer| {
            renderer.deinit();
        }
        self.prompt_context.deinit();

        // Clean up line editor
        if (self.line_editor) |*editor| {
            editor.deinit();
        }

        // Execute shell_exit hooks
        var exit_context = HookContext{
            .hook_type = .shell_exit,
            .data = null,
            .user_data = null,
            .allocator = self.allocator,
        };
        self.plugin_registry.executeHooks(.shell_exit, &exit_context) catch {};

        // Save history before cleanup
        self.saveHistory() catch {
            // Ignore errors saving history
        };

        // Clean up builtin plugins
        if (self.script_suggester) |*suggester| {
            suggester.deinit();
        }

        // Clean up plugin system
        self.plugin_manager.deinit();
        self.plugin_registry.deinit();

        // Clean up script manager
        self.script_manager.deinit();

        // Clean up function manager
        self.function_manager.deinit();

        // Clean up signal handlers
        var sig_iter = self.signal_handlers.iterator();
        while (sig_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.signal_handlers.deinit();

        // Clean up command cache
        var cache_iter = self.command_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.command_cache.deinit();

        // Clean up named directories
        var named_iter = self.named_dirs.iterator();
        while (named_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.named_dirs.deinit();

        // Clean up arrays
        var arrays_iter = self.arrays.iterator();
        while (arrays_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.arrays.deinit();

        // Clean up completion registry
        self.completion_registry.deinit();

        // Clean up background jobs - kill them first, then free memory
        self.killAllBackgroundJobs();
        for (self.background_jobs) |maybe_job| {
            if (maybe_job) |job| {
                self.allocator.free(job.command);
            }
        }

        // Clean up history
        for (self.history) |maybe_entry| {
            if (maybe_entry) |entry| {
                self.allocator.free(entry);
            }
        }
        self.allocator.free(self.history_file_path);

        // Clean up directory stack
        for (self.dir_stack) |maybe_dir| {
            if (maybe_dir) |dir| {
                self.allocator.free(dir);
            }
        }

        // Clean up positional parameters
        for (self.positional_params) |maybe_param| {
            if (maybe_param) |param| {
                self.allocator.free(param);
            }
        }

        // Clean up shell_name if it was dynamically allocated
        if (!std.mem.eql(u8, self.shell_name, "den")) {
            self.allocator.free(self.shell_name);
        }

        // Clean up environment variables (keys and values were allocated)
        var env_iter = self.environment.iterator();
        while (env_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.environment.deinit();

        // Clean up aliases (keys and values were allocated)
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit();

        // Clean up thread pool
        self.thread_pool.deinit();
    }

    /// Initialize AutoSuggest plugin
    pub fn initAutoSuggest(self: *Shell) void {
        if (self.auto_suggest == null) {
            self.auto_suggest = AutoSuggestPlugin.init(
                self.allocator,
                &self.history,
                &self.history_count,
                &self.environment,
            );
        }
    }

    /// Initialize Highlight plugin
    pub fn initHighlighter(self: *Shell) void {
        if (self.highlighter == null) {
            self.highlighter = HighlightPlugin.init(self.allocator);
        }
    }

    /// Initialize ScriptSuggester plugin
    pub fn initScriptSuggester(self: *Shell) void {
        if (self.script_suggester == null) {
            self.script_suggester = ScriptSuggesterPlugin.init(self.allocator);
        }
    }

    /// Get command suggestions using AutoSuggest plugin
    pub fn getCommandSuggestions(self: *Shell, input: []const u8) ![][]const u8 {
        self.initAutoSuggest();
        if (self.auto_suggest) |*plugin| {
            return try plugin.getSuggestions(input);
        }
        return try self.allocator.alloc([]const u8, 0);
    }

    /// Highlight command using Highlight plugin
    pub fn highlightCommand(self: *Shell, input: []const u8) ![]HighlightPlugin.HighlightToken {
        self.initHighlighter();
        if (self.highlighter) |*plugin| {
            return try plugin.highlight(input);
        }
        return try self.allocator.alloc(HighlightPlugin.HighlightToken, 0);
    }

    /// Get script suggestions using ScriptSuggester plugin
    pub fn getScriptSuggestions(self: *Shell, input: []const u8) ![][]const u8 {
        self.initScriptSuggester();
        if (self.script_suggester) |*plugin| {
            return try plugin.getSuggestions(input, &self.environment);
        }
        return try self.allocator.alloc([]const u8, 0);
    }

    pub fn run(self: *Shell) !void {
        self.running = true;

        try IO.print("Den shell initialized!\n", .{});
        try IO.print("Type 'exit' to quit or Ctrl+D to exit.\n\n", .{});

        while (self.running) {
            // Check for config hot-reload
            self.checkConfigHotReload();

            // Check for signals
            if (signals.checkSignal()) |sig| {
                switch (sig) {
                    .interrupt => {
                        // SIGINT (Ctrl+C) - just print newline and continue
                        try IO.print("\n", .{});
                        continue;
                    },
                    .terminate => {
                        // SIGTERM - graceful shutdown
                        try IO.print("\nReceived termination signal, shutting down...\n", .{});
                        self.running = false;
                        break;
                    },
                    .winch => {
                        // SIGWINCH - window resize
                        // The terminal will automatically adjust
                    },
                    .none => {},
                }
            }

            // Check for window size changes
            if (signals.checkWindowSizeChanged()) {
                // Window was resized, terminal will auto-adjust
            }

            // Check for completed background jobs
            try self.checkBackgroundJobs();

            // Read line from stdin
            const line = blk: {
                if (self.is_interactive) {
                    // Initialize line editor on first use
                    if (self.line_editor == null) {
                        const prompt_str = try self.getPromptString();
                        var editor = LineEditor.init(self.allocator, prompt_str);
                        editor.setHistory(&self.history, &self.history_count);
                        editor.setCompletionFn(tabCompletionFn);
                        editor.setPromptRefreshFn(refreshPromptCallback);
                        self.line_editor = editor;
                        // Don't free prompt_str here - LineEditor needs it!
                    } else {
                        // Update prompt for next line
                        const old_prompt = self.line_editor.?.prompt;
                        const prompt_str = try self.getPromptString();
                        self.line_editor.?.prompt = prompt_str;
                        // Free the old prompt to avoid memory leak
                        self.allocator.free(old_prompt);
                    }

                    // Use line editor for interactive input
                    break :blk self.line_editor.?.readLine() catch |err| {
                        if (err == error.Interrupted) {
                            try IO.print("\n", .{});
                            continue;
                        }
                        return err;
                    };
                } else {
                    // Non-interactive: render simple prompt and use basic readLine
                    try self.renderPrompt();
                    break :blk try IO.readLine(self.allocator);
                }
            };

            if (line == null) {
                // EOF (Ctrl+D) - graceful shutdown
                try IO.print("\nGoodbye from Den!\n", .{});
                self.running = false;
                break; // Exit loop and let deinit() handle cleanup
            }

            defer self.allocator.free(line.?);

            const trimmed = std.mem.trim(u8, line.?, &std.ascii.whitespace);

            if (trimmed.len == 0) continue;

            // Handle multiline input (function definitions)
            if (self.multiline_mode != .none) {
                // Continue collecting lines for multiline construct
                try self.handleMultilineContinuation(trimmed);
                continue;
            }

            // Check if this line starts a function definition
            if (try self.checkFunctionDefinitionStart(trimmed)) {
                // handleMultilineStart was called and either:
                // - Function was defined (single-line) and we continue
                // - We're now in multiline mode and will continue on next iteration
                continue;
            }

            // Expand history references (!, !!, !N, !-N, !string, ^old^new)
            const maybe_expanded = self.history_expander.expand(trimmed, &self.history, self.history_count) catch |err| {
                IO.eprint("History expansion error: {}\n", .{err}) catch {};
                // On error, continue with original command
                try self.addToHistory(trimmed);
                try self.executeCommand(trimmed);
                continue;
            };
            defer self.allocator.free(maybe_expanded.text);

            // Use expanded command
            const command = maybe_expanded.text;

            // If expanded, show the expanded command
            if (maybe_expanded.expanded) {
                try IO.print("{s}\n", .{command});
            }

            // Add to history (the expanded command)
            try self.addToHistory(command);

            // Handle exit command
            if (std.mem.eql(u8, command, "exit")) {
                try IO.print("Goodbye from Den!\n", .{});
                self.running = false;
                break; // Exit loop and let deinit() handle cleanup
            }

            // Execute command
            try self.executeCommand(command);
        }
    }

    /// Run a script file with positional parameters (using ScriptManager)
    pub fn runScript(self: *Shell, script_path: []const u8, _: []const u8, args: []const []const u8) !void {
        // Use ScriptManager for enhanced script execution with caching
        const result = try self.script_manager.executeScript(self, script_path, args);

        // Report execution result
        if (result.error_message) |err_msg| {
            try IO.eprint("Script execution failed: {s}\n", .{err_msg});
            self.allocator.free(err_msg);
        }

        self.last_exit_code = result.exit_code;
    }

    /// Check if a line starts a function definition and handle it
    /// Returns true if the line was handled as a function definition
    fn checkFunctionDefinitionStart(self: *Shell, trimmed: []const u8) !bool {
        // Check for "function name" or "name()" syntax
        const is_function_keyword = std.mem.startsWith(u8, trimmed, "function ");

        // For name() syntax, check if line contains ()
        var is_paren_syntax = false;
        if (std.mem.indexOf(u8, trimmed, "()")) |_| {
            // Make sure it's not just () by itself and there's a name before
            const paren_pos = std.mem.indexOf(u8, trimmed, "()") orelse 0;
            if (paren_pos > 0) {
                is_paren_syntax = true;
            }
        }

        if (!is_function_keyword and !is_paren_syntax) {
            return false;
        }

        // This is a function definition - start collecting
        // Count braces in this line
        var brace_count: i32 = 0;
        for (trimmed) |c| {
            if (c == '{') brace_count += 1;
            if (c == '}') brace_count -= 1;
        }

        // Store the first line
        if (self.multiline_count >= self.multiline_buffer.len) {
            try IO.eprint("Function definition too long\n", .{});
            return true;
        }
        self.multiline_buffer[self.multiline_count] = try self.allocator.dupe(u8, trimmed);
        self.multiline_count += 1;
        self.multiline_brace_count = brace_count;

        if (brace_count > 0) {
            // Incomplete - need more lines
            self.multiline_mode = .function_def;
            return true;
        } else if (brace_count == 0) {
            // Check if we have an opening brace at all
            if (std.mem.indexOf(u8, trimmed, "{")) |open_brace| {
                // Complete single-line function like: function foo { echo hi; }
                // Handle single-line function directly without parser
                const close_brace = std.mem.lastIndexOf(u8, trimmed, "}") orelse {
                    try IO.eprint("Syntax error: missing closing brace\n", .{});
                    self.resetMultilineState();
                    return true;
                };

                // Extract function name
                var func_name: []const u8 = undefined;
                if (is_function_keyword) {
                    const after_keyword = std.mem.trim(u8, trimmed[9..], &std.ascii.whitespace);
                    const name_end = std.mem.indexOfAny(u8, after_keyword, " \t{") orelse after_keyword.len;
                    func_name = after_keyword[0..name_end];
                } else {
                    // name() syntax
                    const paren_pos = std.mem.indexOf(u8, trimmed, "()") orelse 0;
                    func_name = std.mem.trim(u8, trimmed[0..paren_pos], &std.ascii.whitespace);
                }

                // Extract body (content between { and })
                const body_content = std.mem.trim(u8, trimmed[open_brace + 1 .. close_brace], &std.ascii.whitespace);

                // Create body as array of lines (split by semicolons for single-line)
                var body_lines: [32][]const u8 = undefined;
                var body_count: usize = 0;
                var line_iter = std.mem.splitScalar(u8, body_content, ';');
                while (line_iter.next()) |part| {
                    const part_trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
                    if (part_trimmed.len > 0) {
                        if (body_count >= body_lines.len) break;
                        body_lines[body_count] = try self.allocator.dupe(u8, part_trimmed);
                        body_count += 1;
                    }
                }

                // Define the function
                self.function_manager.defineFunction(func_name, body_lines[0..body_count], false) catch |err| {
                    try IO.eprint("Function definition error: {}\n", .{err});
                    // Free the body lines we allocated
                    for (body_lines[0..body_count]) |line_content| {
                        self.allocator.free(line_content);
                    }
                    self.resetMultilineState();
                    return true;
                };

                // Free the body lines (function_manager made its own copy)
                for (body_lines[0..body_count]) |line_content| {
                    self.allocator.free(line_content);
                }

                self.resetMultilineState();
                return true;
            } else {
                // No brace yet - might be "function foo" and { on next line
                self.multiline_mode = .function_def;
                return true;
            }
        }

        return true;
    }

    /// Handle continuation of multiline input
    fn handleMultilineContinuation(self: *Shell, trimmed: []const u8) !void {
        // Store the line
        if (self.multiline_count >= self.multiline_buffer.len) {
            try IO.eprint("Function definition too long\n", .{});
            self.resetMultilineState();
            return;
        }
        self.multiline_buffer[self.multiline_count] = try self.allocator.dupe(u8, trimmed);
        self.multiline_count += 1;

        // Update brace count
        for (trimmed) |c| {
            if (c == '{') self.multiline_brace_count += 1;
            if (c == '}') self.multiline_brace_count -= 1;
        }

        // Check if function is complete
        if (self.multiline_brace_count == 0 and self.multiline_count > 0) {
            // Check if we ever had an opening brace
            var had_opening_brace = false;
            for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
                if (maybe_line) |line_content| {
                    if (std.mem.indexOf(u8, line_content, "{") != null) {
                        had_opening_brace = true;
                        break;
                    }
                }
            }

            if (had_opening_brace) {
                try self.finishFunctionDefinition();
            }
        }
    }

    /// Complete function definition parsing and register the function
    fn finishFunctionDefinition(self: *Shell) !void {
        // Collect lines into array for parser
        var lines: [100][]const u8 = undefined;
        var line_count: usize = 0;
        for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
            if (maybe_line) |line_content| {
                lines[line_count] = line_content;
                line_count += 1;
            }
        }

        // Parse the function definition
        const FunctionParser = @import("scripting/functions.zig").FunctionParser;
        var parser = FunctionParser.init(self.allocator);

        const result = parser.parseFunction(lines[0..line_count], 0) catch |err| {
            try IO.eprint("Function parse error: {}\n", .{err});
            self.resetMultilineState();
            return;
        };

        // Define the function
        self.function_manager.defineFunction(result.name, result.body, false) catch |err| {
            try IO.eprint("Function definition error: {}\n", .{err});
            self.resetMultilineState();
            return;
        };

        // Free the name that was duped by parser (function_manager made its own copy)
        self.allocator.free(result.name);
        for (result.body) |body_line| {
            self.allocator.free(body_line);
        }
        self.allocator.free(result.body);

        self.resetMultilineState();
    }

    /// Reset multiline state and free buffered lines
    fn resetMultilineState(self: *Shell) void {
        for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
            if (maybe_line) |line_content| {
                self.allocator.free(line_content);
            }
        }
        self.multiline_buffer = [_]?[]const u8{null} ** 100;
        self.multiline_count = 0;
        self.multiline_brace_count = 0;
        self.multiline_mode = .none;
    }

    fn renderPrompt(self: *Shell) !void {
        const prompt = try self.getPromptString();
        defer self.allocator.free(prompt);
        try IO.print("{s}", .{prompt});
    }

    fn getPromptString(self: *const Shell) ![]const u8 {
        // Initialize prompt renderer if not already done
        var self_mut = @constCast(self);
        if (self_mut.prompt_renderer == null) {
            const template = try PromptTemplate.initDefault(self.allocator);
            self_mut.prompt_renderer = try PromptRenderer.init(self.allocator, template);
        }

        // Update prompt context with current information
        try self_mut.updatePromptContext();

        // Render prompt
        const term_size = ansi.getTerminalSize() catch ansi.TerminalSize{ .rows = 24, .cols = 80 };
        return try self_mut.prompt_renderer.?.render(&self_mut.prompt_context, term_size.cols);
    }

    fn updatePromptContext(self: *Shell) !void {
        var sysinfo = SystemInfo.init(self.allocator);

        // Get current directory
        const cwd = try sysinfo.getCurrentDir();
        defer self.allocator.free(cwd);

        // Get home directory
        const home = try sysinfo.getHomeDir();

        // Get username
        const username = try sysinfo.getUsername();
        defer self.allocator.free(username);

        // Get hostname
        const hostname = try sysinfo.getHostname();
        defer self.allocator.free(hostname);

        // Update context
        self.prompt_context.current_dir = try self.allocator.dupe(u8, cwd);
        if (self.prompt_context.home_dir) |old_home| {
            self.allocator.free(old_home);
        }
        self.prompt_context.home_dir = home;

        // Free old username/hostname if they exist
        if (self.prompt_context.username.len > 0) {
            self.allocator.free(self.prompt_context.username);
        }
        self.prompt_context.username = try self.allocator.dupe(u8, username);

        if (self.prompt_context.hostname.len > 0) {
            self.allocator.free(self.prompt_context.hostname);
        }
        self.prompt_context.hostname = try self.allocator.dupe(u8, hostname);

        self.prompt_context.is_root = sysinfo.isRoot();
        self.prompt_context.last_exit_code = self.last_exit_code;

        // Get git info asynchronously (with caching and timeout)
        var git_info = try self.async_git.getInfo(cwd);
        defer git_info.deinit();

        if (self.prompt_context.git_branch) |old_branch| {
            self.allocator.free(old_branch);
        }
        self.prompt_context.git_branch = if (git_info.branch) |branch|
            try self.allocator.dupe(u8, branch)
        else
            null;

        self.prompt_context.git_dirty = git_info.is_dirty;
        self.prompt_context.git_ahead = git_info.ahead;
        self.prompt_context.git_behind = git_info.behind;
        self.prompt_context.git_staged = git_info.staged_count;
        self.prompt_context.git_unstaged = git_info.unstaged_count;
        self.prompt_context.git_untracked = git_info.untracked_count;
        self.prompt_context.git_stash = git_info.stash_count;

        // Detect package version from package.json/package.jsonc/pantry.json/pantry.jsonc
        if (self.prompt_context.package_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.package_version = self.detectPackageVersion(cwd) catch null;

        // Detect primary package manager (bun takes precedence over node)
        const has_bun_lock = self.hasBunLock(cwd);

        if (has_bun_lock) {
            // Bun project - only show bun
            if (self.prompt_context.bun_version) |old_ver| {
                self.allocator.free(old_ver);
            }
            self.prompt_context.bun_version = self.detectBunVersion() catch null;

            // Clear node version
            if (self.prompt_context.node_version) |old_ver| {
                self.allocator.free(old_ver);
            }
            self.prompt_context.node_version = null;
        } else {
            // Node project or no lock file - show node
            if (self.prompt_context.node_version) |old_ver| {
                self.allocator.free(old_ver);
            }
            self.prompt_context.node_version = self.detectNodeVersion() catch null;

            // Clear bun version
            if (self.prompt_context.bun_version) |old_ver| {
                self.allocator.free(old_ver);
            }
            self.prompt_context.bun_version = null;
        }

        // Detect python version
        if (self.prompt_context.python_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.python_version = self.detectPythonVersion() catch null;

        // Detect ruby version
        if (self.prompt_context.ruby_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.ruby_version = self.detectRubyVersion() catch null;

        // Detect go version
        if (self.prompt_context.go_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.go_version = self.detectGoVersion() catch null;

        // Detect rust version
        if (self.prompt_context.rust_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.rust_version = self.detectRustVersion() catch null;

        // Detect zig version
        if (self.prompt_context.zig_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.zig_version = self.detectZigVersion() catch null;

        self.prompt_context.current_time = if (std.time.Instant.now()) |instant| @intCast(instant.timestamp.sec) else |_| 0;
    }

    pub fn executeCommand(self: *Shell, input: []const u8) !void {
        // Check for array assignment first
        if (isArrayAssignment(input)) {
            try self.executeArrayAssignment(input);
            return;
        }

        // Check for C-style for loop: for ((init; cond; update)); do ... done
        // Skip this check if we're already inside a C-style for loop body to avoid recursion
        const trimmed_input = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (!self.in_cstyle_for_body and std.mem.startsWith(u8, trimmed_input, "for ((")) {
            try self.executeCStyleForLoopOneline(input);
            return;
        }

        // Check for select loop: select VAR in ITEM1 ITEM2; do ... done
        if (std.mem.startsWith(u8, trimmed_input, "select ")) {
            try self.executeSelectLoop(input);
            return;
        }

        // Check if input contains a C-style for loop after other commands (e.g., "total=0; for ((...")
        // This handles cases like: total=0; for ((i=1; i<=5; i++)); do total=$((total + i)); done; echo $total
        if (!self.in_cstyle_for_body and std.mem.indexOf(u8, trimmed_input, "for ((") != null) {
            try self.executeWithCStyleForLoop(input);
            return;
        }

        // Execute pre_command hooks
        const cmd_copy = try self.allocator.dupe(u8, input);
        defer self.allocator.free(cmd_copy);
        var cmd_ptr = cmd_copy;
        var pre_context = HookContext{
            .hook_type = .pre_command,
            .data = @ptrCast(@alignCast(&cmd_ptr)),
            .user_data = null,
            .allocator = self.allocator,
        };
        self.plugin_registry.executeHooks(.pre_command, &pre_context) catch {};

        // Tokenize
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, input);
        const tokens = tokenizer.tokenize() catch |err| {
            try IO.eprint("den: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(tokens);

        if (tokens.len == 0) return;

        // Parse
        var parser = parser_mod.Parser.init(self.allocator, tokens);
        var chain = parser.parse() catch |err| {
            try IO.eprint("den: {s}\n", .{formatParseError(err)});
            self.last_exit_code = 2;
            return;
        };
        defer chain.deinit(self.allocator);

        // Expand variables in all commands
        try self.expandCommandChain(&chain);

        // Expand aliases in command names
        try self.expandAliases(&chain);

        // Check for function calls (single command, no operators)
        if (chain.commands.len == 1 and chain.operators.len == 0) {
            const cmd = &chain.commands[0];

            // Check if this is a function call
            if (self.function_manager.hasFunction(cmd.name)) {
                const exit_code = self.function_manager.executeFunction(self, cmd.name, cmd.args) catch |err| {
                    try IO.eprint("den: function error: {}\n", .{err});
                    self.last_exit_code = 1;
                    // Execute post_command hooks
                    var post_context = HookContext{
                        .hook_type = .post_command,
                        .data = @ptrCast(@alignCast(&cmd_ptr)),
                        .user_data = null,
                        .allocator = self.allocator,
                    };
                    self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
                    return;
                };
                self.last_exit_code = exit_code;
                // Execute post_command hooks
                var post_context = HookContext{
                    .hook_type = .post_command,
                    .data = @ptrCast(@alignCast(&cmd_ptr)),
                    .user_data = null,
                    .allocator = self.allocator,
                };
                self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
                return;
            }
        }

        // Check for shell-context builtins (jobs, history, etc.)
        if (chain.commands.len == 1 and chain.operators.len == 0) {
            const cmd = &chain.commands[0];
            if (std.mem.eql(u8, cmd.name, "jobs")) {
                try self.builtinJobs(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "fg")) {
                try self.builtinFg(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "bg")) {
                try self.builtinBg(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "history")) {
                try self.builtinHistory(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "complete")) {
                try self.builtinComplete(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "alias")) {
                try self.builtinAlias(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "unalias")) {
                try self.builtinUnalias(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "type")) {
                try self.builtinType(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "which")) {
                try self.builtinWhich(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "source") or std.mem.eql(u8, cmd.name, ".")) {
                try self.builtinSource(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "read")) {
                try self.builtinRead(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "test") or std.mem.eql(u8, cmd.name, "[")) {
                try self.builtinTest(cmd);
                if (self.last_exit_code != 0) {
                    self.executeErrTrap();
                }
                return;
            } else if (std.mem.eql(u8, cmd.name, "pushd")) {
                try self.builtinPushd(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "popd")) {
                try self.builtinPopd(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "dirs")) {
                try self.builtinDirs(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "printf")) {
                try self.builtinPrintf(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "true")) {
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "false")) {
                self.last_exit_code = 1;
                self.executeErrTrap();
                return;
            } else if (std.mem.eql(u8, cmd.name, "sleep")) {
                try self.builtinSleep(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "help")) {
                try self.builtinHelp(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "basename")) {
                try self.builtinBasename(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "dirname")) {
                try self.builtinDirname(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "realpath")) {
                try self.builtinRealpath(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "command")) {
                try self.builtinCommand(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "eval")) {
                try self.builtinEval(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "shift")) {
                try self.builtinShift(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "time")) {
                try self.builtinTime(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "umask")) {
                try self.builtinUmask(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "clear")) {
                try self.builtinClear(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "uname")) {
                try self.builtinUname(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "whoami")) {
                try self.builtinWhoami(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "hash")) {
                try self.builtinHash(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "return")) {
                try self.builtinReturn(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "break")) {
                try self.builtinBreak(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "continue")) {
                try self.builtinContinue(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "local")) {
                try self.builtinLocal(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "declare")) {
                try self.builtinDeclare(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "readonly")) {
                try self.builtinReadonly(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "exec")) {
                try self.builtinExec(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "wait")) {
                try self.builtinWait(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "kill")) {
                try self.builtinKill(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "disown")) {
                try self.builtinDisown(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "getopts")) {
                try self.builtinGetopts(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "times")) {
                try self.builtinTimes(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "builtin")) {
                try self.builtinBuiltin(cmd);
                return;
            }
        }

        // Check if this is a background job (last operator is &)
        const is_background = chain.operators.len > 0 and
            chain.operators[chain.operators.len - 1] == .background;

        if (is_background) {
            // Execute in background
            try self.executeInBackground(&chain, input);
            self.last_exit_code = 0;
        } else {
            // Execute normally
            var executor = executor_mod.Executor.initWithShell(self.allocator, &self.environment, self);
            const exit_code = executor.executeChain(&chain) catch |err| {
                try IO.eprint("den: execution error: {}\n", .{err});
                self.last_exit_code = 1;
                // Execute post_command hooks even on error
                var post_context = HookContext{
                    .hook_type = .post_command,
                    .data = @ptrCast(@alignCast(&cmd_ptr)),
                    .user_data = null,
                    .allocator = self.allocator,
                };
                self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
                return;
            };

            self.last_exit_code = exit_code;
            // Note: ERR trap is executed in executeChain after each command
        }

        // Execute post_command hooks
        var post_context = HookContext{
            .hook_type = .post_command,
            .data = @ptrCast(@alignCast(&cmd_ptr)),
            .user_data = null,
            .allocator = self.allocator,
        };
        self.plugin_registry.executeHooks(.post_command, &post_context) catch {};
    }

    /// Execute ERR trap if one is set
    pub fn executeErrTrap(self: *Shell) void {
        // Check if ERR trap is set
        if (self.signal_handlers.get("ERR")) |handler| {
            if (handler.len > 0) {
                // Execute the trap handler
                // Note: Save and restore last_exit_code to preserve $? for the trap
                const saved_exit_code = self.last_exit_code;

                // Parse and execute the trap handler command
                var tokenizer = parser_mod.Tokenizer.init(self.allocator, handler);
                const tokens = tokenizer.tokenize() catch return;
                defer self.allocator.free(tokens);

                if (tokens.len == 0) return;

                var parser = parser_mod.Parser.init(self.allocator, tokens);
                var chain = parser.parse() catch return;
                defer chain.deinit(self.allocator);

                // Expand the command chain (for $?, etc)
                self.expandCommandChain(&chain) catch return;

                // Execute the trap handler (without triggering ERR trap again)
                var executor = executor_mod.Executor.initWithShell(self.allocator, &self.environment, self);
                _ = executor.executeChain(&chain) catch {};

                // Restore the original exit code
                self.last_exit_code = saved_exit_code;
            }
        }
    }

    fn executeInBackground(self: *Shell, chain: *types.CommandChain, original_input: []const u8) !void {
        if (builtin.os.tag == .windows) {
            // Windows: background jobs not yet fully implemented
            try IO.print("background jobs: not fully implemented on Windows\n", .{});
            self.last_exit_code = 0;
            return;
        }

        // Fork the process
        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process - execute the chain
            var executor = executor_mod.Executor.init(self.allocator, &self.environment);
            const exit_code = executor.executeChain(chain) catch 1;
            std.posix.exit(@intCast(exit_code));
        } else {
            // Parent process - add to background jobs
            try self.addBackgroundJob(pid, original_input);
        }
    }

    fn expandCommandChain(self: *Shell, chain: *types.CommandChain) !void {
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
        const pid_for_expansion: i32 = if (@import("builtin").os.tag == .windows)
            0
        else
            @intCast(self.last_background_pid);

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
        expander.arrays = &self.arrays; // Add array support
        // Set local vars pointer if inside a function
        if (self.function_manager.currentFrame()) |frame| {
            expander.local_vars = &frame.local_vars;
        }
        var glob = Glob.init(self.allocator);
        var brace = BraceExpander.init(self.allocator);

        // Get current working directory for glob expansion
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
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

    fn checkBackgroundJobs(self: *Shell) !void {
        if (builtin.os.tag == .windows) {
            // Windows: background jobs not fully implemented
            // Would need to use WaitForSingleObject with WAIT_TIMEOUT
            return;
        }

        var i: usize = 0;
        while (i < self.background_jobs.len) {
            if (self.background_jobs[i]) |job| {
                // Check if job has completed (non-blocking waitpid)
                const result = std.posix.waitpid(job.pid, std.posix.W.NOHANG);

                if (result.pid == job.pid) {
                    // Job completed
                    const exit_status = getExitStatus(result.status);
                    try IO.print("[{d}]  Done ({d})    {s}\n", .{ job.job_id, exit_status, job.command });

                    // Free command string and remove from array
                    self.allocator.free(job.command);
                    self.background_jobs[i] = null;
                    self.background_jobs_count -= 1;
                    // Don't increment i, check this slot again
                } else {
                    // Job still running
                    i += 1;
                }
            } else {
                // Empty slot
                i += 1;
            }
        }
    }

    /// Kill all background jobs (for graceful shutdown)
    fn killAllBackgroundJobs(self: *Shell) void {
        if (builtin.os.tag == .windows) {
            // Windows: terminate processes using TerminateProcess
            const windows = std.os.windows;
            const PROCESS_TERMINATE: u32 = 0x0001;

            for (self.background_jobs) |maybe_job| {
                if (maybe_job) |job| {
                    // Get process handle with terminate permission
                    const handle = windows.kernel32.OpenProcess(PROCESS_TERMINATE, 0, @intFromPtr(job.pid));
                    if (handle) |h| {
                        _ = windows.kernel32.TerminateProcess(h, 1);
                        _ = windows.kernel32.CloseHandle(h);
                    }
                }
            }
            return;
        }

        // Unix: send SIGTERM to all background jobs, then SIGKILL if needed
        for (self.background_jobs) |maybe_job| {
            if (maybe_job) |job| {
                if (job.status == .running) {
                    // First try SIGTERM for graceful termination
                    _ = std.posix.kill(job.pid, std.posix.SIG.TERM) catch {};

                    // Give process a short time to exit gracefully
                    std.posix.nanosleep(0, 100_000_000); // 100ms

                    // Check if still running
                    const result = std.posix.waitpid(job.pid, std.posix.W.NOHANG);
                    if (result.pid == 0) {
                        // Still running, force kill
                        _ = std.posix.kill(job.pid, std.posix.SIG.KILL) catch {};
                        // Reap the zombie
                        _ = std.posix.waitpid(job.pid, 0);
                    }
                }
            }
        }
    }

    pub fn addBackgroundJob(self: *Shell, pid: ProcessId, command: []const u8) !void {
        // Find first empty slot
        var slot_index: ?usize = null;
        for (self.background_jobs, 0..) |maybe_job, i| {
            if (maybe_job == null) {
                slot_index = i;
                break;
            }
        }

        if (slot_index == null) {
            return error.TooManyBackgroundJobs;
        }

        const job_id = self.next_job_id;
        self.next_job_id += 1;

        const command_copy = try self.allocator.dupe(u8, command);

        // Track last background PID
        self.last_background_pid = pid;

        self.background_jobs[slot_index.?] = BackgroundJob{
            .pid = pid,
            .job_id = job_id,
            .command = command_copy,
            .status = .running,
        };
        self.background_jobs_count += 1;

        try IO.print("[{d}] {d}\n", .{ job_id, pid });
    }

    /// Builtin: jobs - list background jobs
    /// Flags: -l (show PIDs), -p (PIDs only), -r (running), -s (stopped)
    fn builtinJobs(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Parse flags
        var show_pids = false;
        var pids_only = false;
        var running_only = false;
        var stopped_only = false;

        for (cmd.args) |arg| {
            if (arg.len > 0 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'l' => show_pids = true,
                        'p' => pids_only = true,
                        'r' => running_only = true,
                        's' => stopped_only = true,
                        else => {
                            try IO.eprint("den: jobs: -{c}: invalid option\n", .{c});
                            self.last_exit_code = 1;
                            return;
                        },
                    }
                }
            }
        }

        for (self.background_jobs) |maybe_job| {
            if (maybe_job) |job| {
                // Filter by status if requested
                if (running_only and job.status != .running) continue;
                if (stopped_only and job.status != .stopped) continue;

                if (pids_only) {
                    // -p: Just print the PID
                    try IO.print("{d}\n", .{job.pid});
                } else if (show_pids) {
                    // -l: Show PID in output
                    const status_str = switch (job.status) {
                        .running => "Running",
                        .stopped => "Stopped",
                        .done => "Done",
                    };
                    try IO.print("[{d}]  {d} {s: <10} {s}\n", .{ job.job_id, job.pid, status_str, job.command });
                } else {
                    // Default output
                    const status_str = switch (job.status) {
                        .running => "Running",
                        .stopped => "Stopped",
                        .done => "Done",
                    };
                    try IO.print("[{d}]  {s: <10} {s}\n", .{ job.job_id, status_str, job.command });
                }
            }
        }
    }

    /// Builtin: fg - bring background job to foreground
    fn builtinFg(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Get job ID from argument (default to most recent)
        var job_id: ?usize = null;
        if (cmd.args.len > 0) {
            job_id = std.fmt.parseInt(usize, cmd.args[0], 10) catch {
                try IO.eprint("den: fg: {s}: no such job\n", .{cmd.args[0]});
                self.last_exit_code = 1;
                return;
            };
        } else {
            // Find most recent job
            var max_id: usize = 0;
            for (self.background_jobs) |maybe_job| {
                if (maybe_job) |job| {
                    if (job.job_id > max_id) {
                        max_id = job.job_id;
                    }
                }
            }
            if (max_id > 0) {
                job_id = max_id;
            }
        }

        if (job_id == null) {
            try IO.eprint("den: fg: current: no such job\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Find job in array
        var job_slot: ?usize = null;
        for (self.background_jobs, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                if (job.job_id == job_id.?) {
                    job_slot = i;
                    break;
                }
            }
        }

        if (job_slot == null) {
            try IO.eprint("den: fg: {d}: no such job\n", .{job_id.?});
            self.last_exit_code = 1;
            return;
        }

        const job = self.background_jobs[job_slot.?].?;
        try IO.print("{s}\n", .{job.command});

        // Wait for the job to complete
        const result = std.posix.waitpid(job.pid, 0);
        const exit_status = getExitStatus(result.status);

        // Remove from background jobs
        self.allocator.free(job.command);
        self.background_jobs[job_slot.?] = null;
        self.background_jobs_count -= 1;

        self.last_exit_code = @intCast(exit_status);
    }

    /// Builtin: bg - continue stopped job in background
    fn builtinBg(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Get job ID from argument (default to most recent stopped job)
        var job_id: ?usize = null;
        if (cmd.args.len > 0) {
            job_id = std.fmt.parseInt(usize, cmd.args[0], 10) catch {
                try IO.eprint("den: bg: {s}: no such job\n", .{cmd.args[0]});
                self.last_exit_code = 1;
                return;
            };
        } else {
            // Find most recent stopped job
            var max_id: usize = 0;
            for (self.background_jobs) |maybe_job| {
                if (maybe_job) |job| {
                    if (job.status == .stopped and job.job_id > max_id) {
                        max_id = job.job_id;
                    }
                }
            }
            if (max_id > 0) {
                job_id = max_id;
            }
        }

        if (job_id == null) {
            try IO.eprint("den: bg: current: no such job\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Find job in array
        var job_slot: ?usize = null;
        for (self.background_jobs, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                if (job.job_id == job_id.?) {
                    job_slot = i;
                    break;
                }
            }
        }

        if (job_slot == null) {
            try IO.eprint("den: bg: {d}: no such job\n", .{job_id.?});
            self.last_exit_code = 1;
            return;
        }

        const job = self.background_jobs[job_slot.?].?;
        if (job.status != .stopped) {
            try IO.eprint("den: bg: job {d} already in background\n", .{job_id.?});
            self.last_exit_code = 1;
            return;
        }

        // Send SIGCONT to continue the job
        // Note: In a real implementation, we'd use kill(pid, SIGCONT)
        // For now, just mark as running
        self.background_jobs[job_slot.?].?.status = .running;
        try IO.print("[{d}]+ {s} &\n", .{ job.job_id, job.command });
        self.last_exit_code = 0;
    }

    /// Add command to history
    fn addToHistory(self: *Shell, command: []const u8) !void {
        // Don't add empty commands or duplicate of last command
        if (command.len == 0) return;

        // Skip if same as last command (consecutive deduplication)
        if (self.history_count > 0) {
            if (self.history[self.history_count - 1]) |last_cmd| {
                if (std.mem.eql(u8, last_cmd, command)) {
                    return; // Skip consecutive duplicate
                }
            }
        }

        // Optional: Also check for duplicates in recent history (more aggressive)
        // This prevents duplicate commands even if they're not consecutive
        const check_last_n = @min(self.history_count, 50); // Check last 50 commands
        var i: usize = 0;
        while (i < check_last_n) : (i += 1) {
            const idx = self.history_count - 1 - i;
            if (self.history[idx]) |cmd| {
                if (std.mem.eql(u8, cmd, command)) {
                    // Found duplicate in recent history - remove old one and add at end
                    self.allocator.free(cmd);

                    // Shift entries to remove the duplicate
                    var j = idx;
                    while (j < self.history_count - 1) : (j += 1) {
                        self.history[j] = self.history[j + 1];
                    }
                    self.history[self.history_count - 1] = null;
                    self.history_count -= 1;
                    break;
                }
            }
        }

        // If history is full, shift everything left
        if (self.history_count >= self.history.len) {
            // Free oldest entry
            if (self.history[0]) |oldest| {
                self.allocator.free(oldest);
            }

            // Shift all entries left
            var m: usize = 0;
            while (m < self.history.len - 1) : (m += 1) {
                self.history[m] = self.history[m + 1];
            }
            self.history[self.history.len - 1] = null;
            self.history_count -= 1;
        }

        // Add new entry
        const cmd_copy = try self.allocator.dupe(u8, command);
        self.history[self.history_count] = cmd_copy;
        self.history_count += 1;

        // Incremental append to history file (zsh-style)
        self.appendToHistoryFile(command) catch {
            // Ignore errors when appending to history file
        };
    }

    /// Load history from file
    fn loadHistory(self: *Shell) !void {
        const file = std.fs.cwd().openFile(self.history_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // File doesn't exist yet
            return err;
        };
        defer file.close();

        // Read entire file
        const max_size = 1024 * 1024; // 1MB max
        const file_size = try file.getEndPos();
        const read_size: usize = @min(file_size, max_size);
        const buffer = try self.allocator.alloc(u8, read_size);
        defer self.allocator.free(buffer);
        var total_read: usize = 0;
        while (total_read < read_size) {
            const bytes_read = try file.read(buffer[total_read..]);
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }
        const content = buffer[0..total_read];

        // Split by newlines and add to history (with deduplication)
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0 and self.history_count < self.history.len) {
                // Check for duplicates before adding
                var is_duplicate = false;
                var k: usize = 0;
                while (k < self.history_count) : (k += 1) {
                    if (self.history[k]) |existing| {
                        if (std.mem.eql(u8, existing, trimmed)) {
                            is_duplicate = true;
                            break;
                        }
                    }
                }

                if (!is_duplicate) {
                    const cmd_copy = try self.allocator.dupe(u8, trimmed);
                    self.history[self.history_count] = cmd_copy;
                    self.history_count += 1;
                }
            }
        }
    }

    /// Load aliases from configuration
    pub fn loadAliasesFromConfig(self: *Shell) !void {
        // Check if aliases are enabled in config
        if (!self.config.aliases.enabled) return;

        // Load custom aliases from config
        if (self.config.aliases.custom) |custom_aliases| {
            for (custom_aliases) |alias_entry| {
                const name_copy = try self.allocator.dupe(u8, alias_entry.name);
                const cmd_copy = try self.allocator.dupe(u8, alias_entry.command);
                try self.aliases.put(name_copy, cmd_copy);
            }
        }
    }

    /// Check if config file has changed and reload if needed (hot-reload)
    pub fn checkConfigHotReload(self: *Shell) void {
        // Only check if hot-reload is enabled in config
        if (!self.config.hot_reload) return;

        // Only check if we have a config file to watch
        if (self.config_source.source_type == .default) return;

        // Get current mtime
        const current_mtime = getConfigMtime(self.config_source.path);
        if (current_mtime == 0) return; // File doesn't exist or error

        // Check if file has changed
        if (current_mtime != self.config_last_mtime) {
            // Reload config
            const result = config_loader.loadConfigWithSource(self.allocator) catch return;

            // Update config
            self.config = result.config;
            self.config_source = result.source;
            self.config_last_mtime = current_mtime;

            // Reload aliases
            self.loadAliasesFromConfig() catch {};

            // Notify user (only in interactive mode)
            if (self.is_interactive) {
                IO.print("\n[Config reloaded]\n", .{}) catch {};
            }
        }
    }

    /// Save history to file
    fn saveHistory(self: *Shell) !void {
        const file = try std.fs.cwd().createFile(self.history_file_path, .{});
        defer file.close();

        for (self.history) |maybe_entry| {
            if (maybe_entry) |entry| {
                _ = try file.writeAll(entry);
                _ = try file.write("\n");
            }
        }
    }

    /// Append a single command to history file (incremental append)
    fn appendToHistoryFile(self: *Shell, command: []const u8) !void {
        const file = try std.fs.cwd().openFile(self.history_file_path, .{ .mode = .write_only });
        defer file.close();

        // Seek to end of file
        try file.seekFromEnd(0);

        // Append the command
        _ = try file.writeAll(command);
        _ = try file.write("\n");
    }

    /// Builtin: history - show command history
    fn builtinHistory(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Parse optional argument for number of entries to show
        var num_entries: usize = self.history_count;
        if (cmd.args.len > 0) {
            num_entries = std.fmt.parseInt(usize, cmd.args[0], 10) catch {
                try IO.eprint("den: history: {s}: numeric argument required\n", .{cmd.args[0]});
                return;
            };
            if (num_entries > self.history_count) {
                num_entries = self.history_count;
            }
        }

        // Calculate starting index
        const start_idx = if (num_entries >= self.history_count) 0 else self.history_count - num_entries;

        // Print history with line numbers
        var idx = start_idx;
        while (idx < self.history_count) : (idx += 1) {
            if (self.history[idx]) |entry| {
                try IO.print("{d:5}  {s}\n", .{ idx + 1, entry });
            }
        }
    }

    /// Builtin: complete - manage programmable completions (bash-style)
    /// Usage:
    ///   complete                    # List all completion specs
    ///   complete -p [command]       # Print completion spec for command
    ///   complete -r [command]       # Remove completion spec for command
    ///   complete [-f|-d|-c|-a|-b|-e|-u] [-W wordlist] [-S suffix] [-P prefix] command
    ///   complete <prefix>           # Show completions for prefix (legacy mode)
    fn builtinComplete(self: *Shell, cmd: *types.ParsedCommand) !void {
        // No args - list all completions
        if (cmd.args.len == 0) {
            const commands = self.completion_registry.getCommands() catch &[_][]const u8{};
            defer {
                for (commands) |c| self.allocator.free(c);
                self.allocator.free(commands);
            }

            if (commands.len == 0) {
                try IO.print("No programmable completions defined.\n", .{});
                try IO.print("Usage: complete [-fdc...] [-W wordlist] command\n", .{});
            } else {
                for (commands) |command| {
                    if (self.completion_registry.get(command)) |spec| {
                        try self.printCompletionSpec(command, spec);
                    }
                }
            }
            return;
        }

        // Parse flags
        var print_mode = false;
        var remove_mode = false;
        var spec_options = CompletionSpec.Options{};
        var wordlist_str: ?[]const u8 = null;
        var target_commands = std.ArrayList([]const u8).empty;
        defer target_commands.deinit(self.allocator);

        var i: usize = 0;
        while (i < cmd.args.len) : (i += 1) {
            const arg = cmd.args[i];

            if (arg.len > 0 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-p")) {
                    print_mode = true;
                } else if (std.mem.eql(u8, arg, "-r")) {
                    remove_mode = true;
                } else if (std.mem.eql(u8, arg, "-f")) {
                    spec_options.filenames = true;
                } else if (std.mem.eql(u8, arg, "-d")) {
                    spec_options.directories = true;
                } else if (std.mem.eql(u8, arg, "-c")) {
                    spec_options.commands = true;
                } else if (std.mem.eql(u8, arg, "-a")) {
                    spec_options.aliases = true;
                } else if (std.mem.eql(u8, arg, "-b")) {
                    spec_options.builtins = true;
                } else if (std.mem.eql(u8, arg, "-e")) {
                    spec_options.variables = true;
                } else if (std.mem.eql(u8, arg, "-u")) {
                    spec_options.users = true;
                } else if (std.mem.eql(u8, arg, "-W")) {
                    // Next arg is wordlist
                    if (i + 1 < cmd.args.len) {
                        i += 1;
                        wordlist_str = cmd.args[i];
                        spec_options.use_wordlist = true;
                    } else {
                        try IO.eprint("den: complete: -W: option requires an argument\n", .{});
                        return;
                    }
                } else if (std.mem.eql(u8, arg, "-S")) {
                    // Next arg is suffix
                    if (i + 1 < cmd.args.len) {
                        i += 1;
                        spec_options.suffix = try self.allocator.dupe(u8, cmd.args[i]);
                    } else {
                        try IO.eprint("den: complete: -S: option requires an argument\n", .{});
                        return;
                    }
                } else if (std.mem.eql(u8, arg, "-P")) {
                    // Next arg is prefix
                    if (i + 1 < cmd.args.len) {
                        i += 1;
                        spec_options.prefix = try self.allocator.dupe(u8, cmd.args[i]);
                    } else {
                        try IO.eprint("den: complete: -P: option requires an argument\n", .{});
                        return;
                    }
                } else if (std.mem.eql(u8, arg, "--help")) {
                    try IO.print("Usage: complete [-prabcdefgu] [-W wordlist] [-S suffix] [-P prefix] [command ...]\n", .{});
                    try IO.print("Specify how arguments are to be completed.\n\n", .{});
                    try IO.print("Options:\n", .{});
                    try IO.print("  -p          print existing completion specs in a reusable format\n", .{});
                    try IO.print("  -r          remove completion spec for command\n", .{});
                    try IO.print("  -f          filenames (default action)\n", .{});
                    try IO.print("  -d          directory names\n", .{});
                    try IO.print("  -c          command names\n", .{});
                    try IO.print("  -a          alias names\n", .{});
                    try IO.print("  -b          builtin command names\n", .{});
                    try IO.print("  -e          environment variable names\n", .{});
                    try IO.print("  -u          usernames\n", .{});
                    try IO.print("  -W wordlist use words from wordlist\n", .{});
                    try IO.print("  -S suffix   append suffix to each completion\n", .{});
                    try IO.print("  -P prefix   prepend prefix to each completion\n", .{});
                    return;
                } else {
                    // Legacy mode - treat as prefix
                    var completion = Completion.init(self.allocator);
                    try self.showLegacyCompletions(&completion, arg);
                    return;
                }
            } else {
                // Non-option argument - this is a command name
                try target_commands.append(self.allocator, arg);
            }
        }

        // Handle print mode
        if (print_mode) {
            if (target_commands.items.len == 0) {
                // Print all
                const commands = self.completion_registry.getCommands() catch &[_][]const u8{};
                defer {
                    for (commands) |c| self.allocator.free(c);
                    self.allocator.free(commands);
                }
                for (commands) |command| {
                    if (self.completion_registry.get(command)) |spec| {
                        try self.printCompletionSpec(command, spec);
                    }
                }
            } else {
                for (target_commands.items) |command| {
                    if (self.completion_registry.get(command)) |spec| {
                        try self.printCompletionSpec(command, spec);
                    } else {
                        try IO.eprint("den: complete: {s}: no completion specification\n", .{command});
                    }
                }
            }
            return;
        }

        // Handle remove mode
        if (remove_mode) {
            if (target_commands.items.len == 0) {
                // Remove all
                const commands = self.completion_registry.getCommands() catch &[_][]const u8{};
                defer {
                    for (commands) |c| self.allocator.free(c);
                    self.allocator.free(commands);
                }
                for (commands) |command| {
                    _ = self.completion_registry.unregister(command);
                }
            } else {
                for (target_commands.items) |command| {
                    _ = self.completion_registry.unregister(command);
                }
            }
            return;
        }

        // Register mode - need at least one command
        if (target_commands.items.len == 0) {
            // Legacy mode - no options, just print help
            try IO.print("Usage: complete [-prabcdefgu] [-W wordlist] [-S suffix] [-P prefix] command\n", .{});
            return;
        }

        // Parse wordlist if provided
        var wordlist: ?[][]const u8 = null;
        if (wordlist_str) |wl| {
            var words = std.ArrayList([]const u8).empty;
            errdefer words.deinit(self.allocator);

            var word_iter = std.mem.tokenizeAny(u8, wl, " \t");
            while (word_iter.next()) |word| {
                try words.append(self.allocator, try self.allocator.dupe(u8, word));
            }
            wordlist = try words.toOwnedSlice(self.allocator);
        }

        // Register completions for each command
        for (target_commands.items) |command| {
            try self.completion_registry.register(command, .{
                .command = command,
                .options = spec_options,
                .wordlist = wordlist,
            });
        }
    }

    /// Print completion spec in reusable format
    fn printCompletionSpec(self: *Shell, command: []const u8, spec: CompletionSpec) !void {
        _ = self;
        try IO.print("complete", .{});
        if (spec.options.filenames) try IO.print(" -f", .{});
        if (spec.options.directories) try IO.print(" -d", .{});
        if (spec.options.commands) try IO.print(" -c", .{});
        if (spec.options.aliases) try IO.print(" -a", .{});
        if (spec.options.builtins) try IO.print(" -b", .{});
        if (spec.options.variables) try IO.print(" -e", .{});
        if (spec.options.users) try IO.print(" -u", .{});
        if (spec.wordlist) |wordlist| {
            try IO.print(" -W \"", .{});
            for (wordlist, 0..) |word, idx| {
                if (idx > 0) try IO.print(" ", .{});
                try IO.print("{s}", .{word});
            }
            try IO.print("\"", .{});
        }
        if (spec.options.suffix) |suffix| {
            try IO.print(" -S \"{s}\"", .{suffix});
        }
        if (spec.options.prefix) |prefix| {
            try IO.print(" -P \"{s}\"", .{prefix});
        }
        try IO.print(" {s}\n", .{command});
    }

    /// Show completions in legacy mode (for a prefix)
    fn showLegacyCompletions(self: *Shell, completion: *Completion, prefix: []const u8) !void {
        // Try command completion first
        const cmd_matches = try completion.completeCommand(prefix);
        defer {
            for (cmd_matches) |match| {
                self.allocator.free(match);
            }
            self.allocator.free(cmd_matches);
        }

        if (cmd_matches.len > 0) {
            try IO.print("Commands:\n", .{});
            for (cmd_matches) |match| {
                try IO.print("  {s}\n", .{match});
            }
        }

        // Try file completion
        const file_matches = try completion.completeFile(prefix);
        defer {
            for (file_matches) |match| {
                self.allocator.free(match);
            }
            self.allocator.free(file_matches);
        }

        if (file_matches.len > 0) {
            if (cmd_matches.len > 0) {
                try IO.print("\n", .{});
            }
            try IO.print("Files:\n", .{});
            for (file_matches) |match| {
                try IO.print("  {s}\n", .{match});
            }
        }

        if (cmd_matches.len == 0 and file_matches.len == 0) {
            try IO.print("No completions found.\n", .{});
        }
    }

    /// Expand aliases in command chain
    fn expandAliases(self: *Shell, chain: *types.CommandChain) !void {
        for (chain.commands) |*cmd| {
            if (self.aliases.get(cmd.name)) |alias_value| {
                // Replace command name with alias value
                const expanded = try self.allocator.dupe(u8, alias_value);
                self.allocator.free(cmd.name);
                cmd.name = expanded;
            }
        }
    }

    /// Builtin: alias - define or list aliases
    fn builtinAlias(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // List all aliases
            var iter = self.aliases.iterator();
            while (iter.next()) |entry| {
                try IO.print("alias {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        } else {
            // Parse alias definition: name=value
            for (cmd.args) |arg| {
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                    const name = arg[0..eq_pos];
                    const value = arg[eq_pos + 1 ..];

                    // Remove quotes if present
                    const clean_value = if (value.len >= 2 and
                        ((value[0] == '\'' and value[value.len - 1] == '\'') or
                        (value[0] == '"' and value[value.len - 1] == '"')))
                        value[1 .. value.len - 1]
                    else
                        value;

                    // Store alias
                    const value_copy = try self.allocator.dupe(u8, clean_value);

                    // Free old key and value if exists
                    if (self.aliases.fetchRemove(name)) |old_kv| {
                        self.allocator.free(old_kv.key);
                        self.allocator.free(old_kv.value);
                    }

                    const name_copy = try self.allocator.dupe(u8, name);
                    try self.aliases.put(name_copy, value_copy);
                } else {
                    // Show specific alias
                    if (self.aliases.get(arg)) |value| {
                        try IO.print("alias {s}='{s}'\n", .{ arg, value });
                    } else {
                        try IO.eprint("den: alias: {s}: not found\n", .{arg});
                    }
                }
            }
        }
    }

    /// Builtin: unalias - remove alias
    fn builtinUnalias(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: unalias: usage: unalias name [name ...]\n", .{});
            return;
        }

        for (cmd.args) |name| {
            if (self.aliases.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            } else {
                try IO.eprint("den: unalias: {s}: not found\n", .{name});
            }
        }
    }

    /// Builtin: type - identify command type
    fn builtinType(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: type: usage: type name [name ...]\n", .{});
            return;
        }

        const builtins = [_][]const u8{
            "cd",      "pwd",      "echo",    "exit",  "env",
            "export",  "set",      "unset",   "jobs",  "fg",
            "bg",      "history",  "complete", "alias", "unalias",
            "type",    "which",
        };

        for (cmd.args) |name| {
            // Check if it's an alias
            if (self.aliases.get(name)) |alias_value| {
                try IO.print("{s} is aliased to `{s}'\n", .{ name, alias_value });
                continue;
            }

            // Check if it's a builtin
            var is_builtin = false;
            for (builtins) |builtin_name| {
                if (std.mem.eql(u8, name, builtin_name)) {
                    try IO.print("{s} is a shell builtin\n", .{name});
                    is_builtin = true;
                    break;
                }
            }
            if (is_builtin) continue;

            // Check if it's in PATH
            var completion = Completion.init(self.allocator);
            const matches = try completion.completeCommand(name);
            defer {
                for (matches) |match| {
                    self.allocator.free(match);
                }
                self.allocator.free(matches);
            }

            if (matches.len > 0) {
                // Find exact match
                for (matches) |match| {
                    if (std.mem.eql(u8, match, name)) {
                        // Find full path
                        const path = getenv("PATH") orelse "";
                        var path_iter = std.mem.splitScalar(u8, path, ':');
                        while (path_iter.next()) |dir_path| {
                            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;

                            // Check if file exists
                            std.fs.cwd().access(full_path, .{}) catch continue;
                            try IO.print("{s} is {s}\n", .{ name, full_path });
                            break;
                        }
                        break;
                    }
                }
            } else {
                try IO.eprint("den: type: {s}: not found\n", .{name});
            }
        }
    }

    /// Builtin: which - locate command in PATH
    fn builtinWhich(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;
        if (cmd.args.len == 0) {
            try IO.eprint("den: which: usage: which name [name ...]\n", .{});
            return;
        }

        for (cmd.args) |name| {
            const path = getenv("PATH") orelse "";
            var path_iter = std.mem.splitScalar(u8, path, ':');
            var found = false;

            while (path_iter.next()) |dir_path| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;

                // Check if file exists and is executable
                const stat = std.fs.cwd().statFile(full_path) catch continue;
                const is_executable = (stat.mode & 0o111) != 0;

                if (is_executable) {
                    try IO.print("{s}\n", .{full_path});
                    found = true;
                    break;
                }
            }

            if (!found) {
                try IO.eprint("den: which: {s}: not found\n", .{name});
            }
        }
    }

    /// Builtin: source - execute commands from file
    fn builtinSource(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: source: usage: source filename\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const filename = cmd.args[0];

        // Read file contents
        const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
            self.last_exit_code = 1;
            return;
        };
        defer file.close();

        const max_size = 1024 * 1024; // 1MB max
        const file_size = file.getEndPos() catch |err| {
            try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
            self.last_exit_code = 1;
            return;
        };
        const read_size: usize = @min(file_size, max_size);
        const buffer = self.allocator.alloc(u8, read_size) catch |err| {
            try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(buffer);
        var total_read: usize = 0;
        while (total_read < read_size) {
            const bytes_read = file.read(buffer[total_read..]) catch |err| {
                try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
                self.last_exit_code = 1;
                return;
            };
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }
        const content = buffer[0..total_read];

        // Execute each line by tokenizing and executing directly
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue; // Skip comments

            // Tokenize the line
            var tokenizer = parser_mod.Tokenizer.init(self.allocator, trimmed);
            const tokens = tokenizer.tokenize() catch |err| {
                try IO.eprint("den: source: parse error: {}\n", .{err});
                self.last_exit_code = 1;
                continue; // Continue with next line instead of returning
            };
            defer self.allocator.free(tokens);

            // Parse tokens
            var p = parser_mod.Parser.init(self.allocator, tokens);
            var chain = p.parse() catch |err| {
                try IO.eprint("den: source: parse error: {}\n", .{err});
                self.last_exit_code = 1;
                continue;
            };
            defer chain.deinit(self.allocator);

            // Expand variables and aliases
            try self.expandCommandChain(&chain);
            try self.expandAliases(&chain);

            // Execute the command chain
            var executor = executor_mod.Executor.init(self.allocator, &self.environment);
            const exit_code = executor.executeChain(&chain) catch |err| {
                try IO.eprint("den: source: execution error: {}\n", .{err});
                self.last_exit_code = 1;
                continue;
            };
            self.last_exit_code = exit_code;
        }
    }

    /// Builtin: read - read line from stdin into variable
    fn builtinRead(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: read: usage: read varname\n", .{});
            return;
        }

        const varname = cmd.args[0];

        // Read line from stdin
        const line = try IO.readLine(self.allocator);
        if (line) |value| {
            defer self.allocator.free(value);

            // Store in environment
            const value_copy = try self.allocator.dupe(u8, value);

            // Get or put entry to avoid memory leak
            const gop = try self.environment.getOrPut(varname);
            if (gop.found_existing) {
                // Free old value and update
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = value_copy;
            } else {
                // New key - duplicate it
                const key = try self.allocator.dupe(u8, varname);
                gop.key_ptr.* = key;
                gop.value_ptr.* = value_copy;
            }
        }
    }

    /// Builtin: test/[ - evaluate conditional expressions
    fn builtinTest(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Simple test implementation supporting basic conditions
        if (cmd.args.len == 0) {
            self.last_exit_code = 1;
            return;
        }

        // Handle [ command - must end with ]
        var args = cmd.args;
        if (std.mem.eql(u8, cmd.name, "[")) {
            if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
                try IO.eprint("den: [: missing ]\n", .{});
                self.last_exit_code = 2;
                return;
            }
            args = args[0 .. args.len - 1]; // Remove trailing ]
        }

        if (args.len == 0) {
            self.last_exit_code = 1;
            return;
        }

        // Unary operators
        if (args.len == 2) {
            const op = args[0];
            const arg = args[1];

            if (std.mem.eql(u8, op, "-z")) {
                // String is empty
                self.last_exit_code = if (arg.len == 0) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-n")) {
                // String is not empty
                self.last_exit_code = if (arg.len > 0) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-f")) {
                // File exists and is regular file
                const stat = std.fs.cwd().statFile(arg) catch {
                    self.last_exit_code = 1;
                    return;
                };
                self.last_exit_code = if (stat.kind == .file) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-d")) {
                // Directory exists
                const stat = std.fs.cwd().statFile(arg) catch {
                    self.last_exit_code = 1;
                    return;
                };
                self.last_exit_code = if (stat.kind == .directory) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-e")) {
                // File exists
                std.fs.cwd().access(arg, .{}) catch {
                    self.last_exit_code = 1;
                    return;
                };
                self.last_exit_code = 0;
                return;
            }
        }

        // Binary operators
        if (args.len == 3) {
            const left = args[0];
            const op = args[1];
            const right = args[2];

            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
                // String equality
                self.last_exit_code = if (std.mem.eql(u8, left, right)) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "!=")) {
                // String inequality
                self.last_exit_code = if (!std.mem.eql(u8, left, right)) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-eq")) {
                // Numeric equality
                const left_num = std.fmt.parseInt(i32, left, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                const right_num = std.fmt.parseInt(i32, right, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                self.last_exit_code = if (left_num == right_num) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-ne")) {
                // Numeric inequality
                const left_num = std.fmt.parseInt(i32, left, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                const right_num = std.fmt.parseInt(i32, right, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                self.last_exit_code = if (left_num != right_num) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-lt")) {
                // Less than
                const left_num = std.fmt.parseInt(i32, left, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                const right_num = std.fmt.parseInt(i32, right, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                self.last_exit_code = if (left_num < right_num) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-gt")) {
                // Greater than
                const left_num = std.fmt.parseInt(i32, left, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                const right_num = std.fmt.parseInt(i32, right, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                self.last_exit_code = if (left_num > right_num) 0 else 1;
                return;
            }
        }

        // Default: non-empty string test
        if (args.len == 1) {
            self.last_exit_code = if (args[0].len > 0) 0 else 1;
            return;
        }

        // Unknown test
        try IO.eprint("den: test: unknown condition\n", .{});
        self.last_exit_code = 2;
    }

    /// Builtin: pushd - push directory onto stack and cd
    /// Supports: pushd (swap), pushd dir, pushd +N/-N (rotate)
    fn builtinPushd(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // pushd with no args: swap top two directories
            if (self.dir_stack_count < 1) {
                try IO.eprint("den: pushd: directory stack empty\n", .{});
                self.last_exit_code = 1;
                return;
            }

            // Get current directory
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = try std.posix.getcwd(&cwd_buf);
            const cwd_copy = try self.allocator.dupe(u8, cwd);

            // Pop top of stack and cd to it
            const top_dir = self.dir_stack[self.dir_stack_count - 1].?;
            std.posix.chdir(top_dir) catch |err| {
                try IO.eprint("den: pushd: {s}: {}\n", .{ top_dir, err });
                self.allocator.free(cwd_copy);
                self.last_exit_code = 1;
                return;
            };

            // Push old cwd onto stack
            self.dir_stack[self.dir_stack_count - 1] = cwd_copy;
            try self.printDirStack();
            self.last_exit_code = 0;
        } else {
            const arg = cmd.args[0];

            // Check for +N or -N rotation
            if (arg.len > 0 and (arg[0] == '+' or arg[0] == '-')) {
                const n = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: pushd: {s}: invalid number\n", .{arg});
                    self.last_exit_code = 1;
                    return;
                };

                // Total stack size is dir_stack_count + 1 (including cwd)
                const total_size = self.dir_stack_count + 1;
                if (n >= total_size) {
                    try IO.eprint("den: pushd: {s}: directory stack index out of range\n", .{arg});
                    self.last_exit_code = 1;
                    return;
                }

                // Calculate index: +N counts from left, -N from right
                const index = if (arg[0] == '+') n else total_size - n;
                if (index == 0) {
                    // Already at current directory, nothing to do
                    try self.printDirStack();
                    self.last_exit_code = 0;
                    return;
                }

                // Rotate stack: bring index to top
                // Index 0 is cwd, index 1 is top of stack, etc.
                try self.rotateDirStack(index);
                try self.printDirStack();
                self.last_exit_code = 0;
            } else {
                const target_dir = arg;

                // Get current directory before changing
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                const cwd = try std.posix.getcwd(&cwd_buf);

                // Try to change to target directory
                std.posix.chdir(target_dir) catch |err| {
                    try IO.eprint("den: pushd: {s}: {}\n", .{ target_dir, err });
                    self.last_exit_code = 1;
                    return;
                };

                // Push old cwd onto stack
                if (self.dir_stack_count >= self.dir_stack.len) {
                    try IO.eprint("den: pushd: directory stack full\n", .{});
                    self.last_exit_code = 1;
                    return;
                }

                self.dir_stack[self.dir_stack_count] = try self.allocator.dupe(u8, cwd);
                self.dir_stack_count += 1;
                try self.printDirStack();
                self.last_exit_code = 0;
            }
        }
    }

    /// Helper to rotate directory stack - brings index to top by rotating
    fn rotateDirStack(self: *Shell, index: usize) !void {
        if (index == 0 or index > self.dir_stack_count) return;

        // Get current directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&cwd_buf);
        const cwd_copy = try self.allocator.dupe(u8, cwd);

        // Build full stack: [cwd, stack[count-1], stack[count-2], ..., stack[0]]
        // The target is at position (total - index) in the reversed stack
        // Index 1 = top of stack = dir_stack[count-1]
        // Index 2 = second from top = dir_stack[count-2]
        const stack_idx = self.dir_stack_count - index;
        const target_dir = self.dir_stack[stack_idx].?;

        // Change to target directory
        std.posix.chdir(target_dir) catch |err| {
            try IO.eprint("den: pushd: {s}: {}\n", .{ target_dir, err });
            self.allocator.free(cwd_copy);
            return err;
        };

        // Rotate the stack: move elements around
        // After rotation: cwd goes to position index, everything shifts
        // Simple approach: remove target, push cwd, then re-add entries in new order
        self.allocator.free(self.dir_stack[stack_idx].?);
        self.dir_stack[stack_idx] = null;

        // Shift elements down to fill gap
        var i = stack_idx;
        while (i + 1 < self.dir_stack_count) : (i += 1) {
            self.dir_stack[i] = self.dir_stack[i + 1];
        }
        self.dir_stack[self.dir_stack_count - 1] = null;

        // Now add cwd at the correct position (where we removed from)
        // We need to shift up from stack_idx and insert cwd there
        i = self.dir_stack_count - 1;
        while (i > stack_idx) : (i -= 1) {
            self.dir_stack[i] = self.dir_stack[i - 1];
        }
        self.dir_stack[stack_idx] = cwd_copy;
    }

    /// Helper to print directory stack
    fn printDirStack(self: *Shell) !void {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&cwd_buf);
        try IO.print("{s}", .{cwd});

        if (self.dir_stack_count > 0) {
            var i: usize = self.dir_stack_count;
            while (i > 0) {
                i -= 1;
                if (self.dir_stack[i]) |dir| {
                    try IO.print(" {s}", .{dir});
                }
            }
        }
        try IO.print("\n", .{});
    }

    /// Builtin: popd - pop directory from stack and cd
    /// Supports: popd, popd +N/-N (remove specific entry)
    fn builtinPopd(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (self.dir_stack_count == 0) {
            try IO.eprint("den: popd: directory stack empty\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Check for +N or -N to remove specific entry
        if (cmd.args.len > 0) {
            const arg = cmd.args[0];
            if (arg.len > 0 and (arg[0] == '+' or arg[0] == '-')) {
                const n = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: popd: {s}: invalid number\n", .{arg});
                    self.last_exit_code = 1;
                    return;
                };

                // Total stack size is dir_stack_count + 1 (including cwd)
                const total_size = self.dir_stack_count + 1;
                if (n >= total_size) {
                    try IO.eprint("den: popd: {s}: directory stack index out of range\n", .{arg});
                    self.last_exit_code = 1;
                    return;
                }

                // Calculate index: +N counts from left, -N from right
                const index = if (arg[0] == '+') n else total_size - n;

                if (index == 0) {
                    // Remove current directory - same as normal popd
                    self.dir_stack_count -= 1;
                    const dir = self.dir_stack[self.dir_stack_count].?;
                    defer self.allocator.free(dir);
                    self.dir_stack[self.dir_stack_count] = null;

                    std.posix.chdir(dir) catch |err| {
                        try IO.eprint("den: popd: {s}: {}\n", .{ dir, err });
                        self.last_exit_code = 1;
                        return;
                    };
                } else {
                    // Remove entry at index (without changing directory)
                    // Index 1 = top of stack, Index 2 = second from top, etc.
                    const stack_idx = self.dir_stack_count - index;
                    self.allocator.free(self.dir_stack[stack_idx].?);

                    // Shift elements down to fill gap
                    var i = stack_idx;
                    while (i + 1 < self.dir_stack_count) : (i += 1) {
                        self.dir_stack[i] = self.dir_stack[i + 1];
                    }
                    self.dir_stack[self.dir_stack_count - 1] = null;
                    self.dir_stack_count -= 1;
                }

                try self.printDirStack();
                self.last_exit_code = 0;
                return;
            }
        }

        // Default: pop top directory from stack and cd to it
        self.dir_stack_count -= 1;
        const dir = self.dir_stack[self.dir_stack_count].?;
        defer self.allocator.free(dir);
        self.dir_stack[self.dir_stack_count] = null;

        // Change to that directory
        std.posix.chdir(dir) catch |err| {
            try IO.eprint("den: popd: {s}: {}\n", .{ dir, err });
            self.last_exit_code = 1;
            return;
        };

        try self.printDirStack();
        self.last_exit_code = 0;
    }

    /// Builtin: dirs - show directory stack
    /// Supports: -c (clear), -l (long/full paths), -p (one per line), -v (verbose with indices)
    fn builtinDirs(self: *Shell, cmd: *types.ParsedCommand) !void {
        var clear_stack = false;
        var full_paths = false;
        var one_per_line = false;
        var verbose = false;

        // Parse flags
        for (cmd.args) |arg| {
            if (arg.len > 0 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'c' => clear_stack = true,
                        'l' => full_paths = true,
                        'p' => one_per_line = true,
                        'v' => {
                            verbose = true;
                            one_per_line = true;
                        },
                        else => {},
                    }
                }
            }
        }

        // Handle -c: clear directory stack
        if (clear_stack) {
            var i: usize = 0;
            while (i < self.dir_stack_count) : (i += 1) {
                if (self.dir_stack[i]) |dir| {
                    self.allocator.free(dir);
                    self.dir_stack[i] = null;
                }
            }
            self.dir_stack_count = 0;
            self.last_exit_code = 0;
            return;
        }

        // Get current directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&cwd_buf);

        // Get home directory for tilde substitution
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch null;
        defer if (home) |h| self.allocator.free(h);

        // Helper to format path (with optional tilde substitution)
        const printPath = struct {
            fn print(path: []const u8, use_full: bool, home_dir: ?[]const u8) void {
                if (!use_full) {
                    if (home_dir) |h| {
                        if (std.mem.startsWith(u8, path, h)) {
                            IO.print("~{s}", .{path[h.len..]}) catch {};
                            return;
                        }
                    }
                }
                IO.print("{s}", .{path}) catch {};
            }
        }.print;

        // Output directory stack
        var index: usize = 0;

        if (verbose) {
            IO.print(" {d}  ", .{index}) catch {};
        }
        printPath(cwd, full_paths, home);

        index += 1;

        // Show stack from top to bottom
        if (self.dir_stack_count > 0) {
            var i: usize = self.dir_stack_count;
            while (i > 0) {
                i -= 1;
                if (self.dir_stack[i]) |dir| {
                    if (one_per_line) {
                        IO.print("\n", .{}) catch {};
                        if (verbose) {
                            IO.print(" {d}  ", .{index}) catch {};
                        }
                    } else {
                        IO.print(" ", .{}) catch {};
                    }
                    printPath(dir, full_paths, home);
                    index += 1;
                }
            }
        }

        IO.print("\n", .{}) catch {};
        self.last_exit_code = 0;
    }

    /// Builtin: printf - formatted output with full format string support
    fn builtinPrintf(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;

        if (cmd.args.len == 0) {
            return;
        }

        const format = cmd.args[0];
        var arg_idx: usize = 1;
        var i: usize = 0;

        while (i < format.len) {
            if (format[i] == '%' and i + 1 < format.len) {
                // Parse optional flags, width, and precision
                var j = i + 1;
                var left_justify = false;
                var zero_pad = false;
                var width: usize = 0;
                var precision: usize = 6; // Default precision for floats
                var has_precision = false;

                // Parse flags
                while (j < format.len) {
                    if (format[j] == '-') {
                        left_justify = true;
                        j += 1;
                    } else if (format[j] == '0') {
                        zero_pad = true;
                        j += 1;
                    } else if (format[j] == '+' or format[j] == ' ' or format[j] == '#') {
                        j += 1; // Skip unsupported flags
                    } else {
                        break;
                    }
                }

                // Parse width
                while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                    width = width * 10 + (format[j] - '0');
                    j += 1;
                }

                // Parse precision
                if (j < format.len and format[j] == '.') {
                    j += 1;
                    precision = 0;
                    has_precision = true;
                    while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                        precision = precision * 10 + (format[j] - '0');
                        j += 1;
                    }
                }

                if (j >= format.len) {
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                    continue;
                }

                const spec = format[j];
                if (spec == 's') {
                    // String format
                    if (arg_idx < cmd.args.len) {
                        var str = cmd.args[arg_idx];
                        // Apply precision (truncate)
                        if (has_precision and str.len > precision) {
                            str = str[0..precision];
                        }
                        // Apply width (padding)
                        if (width > 0 and str.len < width) {
                            const pad = width - str.len;
                            if (left_justify) {
                                try IO.print("{s}", .{str});
                                var p: usize = 0;
                                while (p < pad) : (p += 1) try IO.print(" ", .{});
                            } else {
                                var p: usize = 0;
                                while (p < pad) : (p += 1) try IO.print(" ", .{});
                                try IO.print("{s}", .{str});
                            }
                        } else {
                            try IO.print("{s}", .{str});
                        }
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'd' or spec == 'i') {
                    // Integer format
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseInt(i64, cmd.args[arg_idx], 10) catch 0;
                        try printfInt(num, width, zero_pad, left_justify);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'u') {
                    // Unsigned integer format
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseInt(u64, cmd.args[arg_idx], 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 10, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'x') {
                    // Hex lowercase
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseInt(u64, cmd.args[arg_idx], 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 16, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'X') {
                    // Hex uppercase
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseInt(u64, cmd.args[arg_idx], 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 16, true);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'o') {
                    // Octal format
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseInt(u64, cmd.args[arg_idx], 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 8, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'c') {
                    // Character format
                    if (arg_idx < cmd.args.len) {
                        const arg = cmd.args[arg_idx];
                        if (arg.len > 0) {
                            try IO.print("{c}", .{arg[0]});
                        }
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'f' or spec == 'F') {
                    // Float format
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseFloat(f64, cmd.args[arg_idx]) catch 0.0;
                        try printfFloat(num, width, precision, left_justify);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == '%') {
                    // Escaped %
                    try IO.print("%", .{});
                    i = j + 1;
                } else if (spec == 'b') {
                    // String with escape interpretation (bash extension)
                    if (arg_idx < cmd.args.len) {
                        try printWithEscapes(cmd.args[arg_idx]);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'q') {
                    // Shell-quoted string (bash extension)
                    if (arg_idx < cmd.args.len) {
                        try IO.print("'{s}'", .{cmd.args[arg_idx]});
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else {
                    // Unknown format, just print it
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                }
            } else if (format[i] == '\\' and i + 1 < format.len) {
                const esc = format[i + 1];
                switch (esc) {
                    'n' => try IO.print("\n", .{}),
                    't' => try IO.print("\t", .{}),
                    'r' => try IO.print("\r", .{}),
                    '\\' => try IO.print("\\", .{}),
                    'a' => try IO.print("\x07", .{}),
                    'b' => try IO.print("\x08", .{}),
                    'f' => try IO.print("\x0c", .{}),
                    'v' => try IO.print("\x0b", .{}),
                    'e' => try IO.print("\x1b", .{}),
                    '0' => {
                        // Octal escape
                        var val: u8 = 0;
                        var k: usize = i + 2;
                        var count: usize = 0;
                        while (k < format.len and count < 3) : (k += 1) {
                            if (format[k] >= '0' and format[k] <= '7') {
                                val = val * 8 + (format[k] - '0');
                                count += 1;
                            } else break;
                        }
                        try IO.print("{c}", .{val});
                        i = k;
                        continue;
                    },
                    'x' => {
                        // Hex escape \xNN
                        if (i + 3 < format.len) {
                            const hex = format[i + 2 .. i + 4];
                            const val = std.fmt.parseInt(u8, hex, 16) catch {
                                try IO.print("{c}", .{format[i]});
                                i += 1;
                                continue;
                            };
                            try IO.print("{c}", .{val});
                            i += 4;
                            continue;
                        } else {
                            try IO.print("{c}", .{format[i]});
                            i += 1;
                            continue;
                        }
                    },
                    else => try IO.print("{c}", .{format[i]}),
                }
                i += 2;
            } else {
                try IO.print("{c}", .{format[i]});
                i += 1;
            }
        }
    }

    /// Helper for printf - format signed integer with width/padding
    fn printfInt(num: i64, width: usize, zero_pad: bool, left_justify: bool) !void {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;
        if (width > 0 and str.len < width) {
            const pad = width - str.len;
            const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
            if (left_justify) {
                try IO.print("{s}", .{str});
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print(" ", .{});
            } else {
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print("{c}", .{pad_char});
                try IO.print("{s}", .{str});
            }
        } else {
            try IO.print("{s}", .{str});
        }
    }

    /// Helper for printf - format unsigned integer with base and width
    fn printfUint(num: u64, width: usize, zero_pad: bool, left_justify: bool, base: u8, uppercase: bool) !void {
        var buf: [32]u8 = undefined;
        const str = if (base == 16)
            if (uppercase)
                std.fmt.bufPrint(&buf, "{X}", .{num}) catch return
            else
                std.fmt.bufPrint(&buf, "{x}", .{num}) catch return
        else if (base == 8)
            std.fmt.bufPrint(&buf, "{o}", .{num}) catch return
        else
            std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;

        if (width > 0 and str.len < width) {
            const pad = width - str.len;
            const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
            if (left_justify) {
                try IO.print("{s}", .{str});
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print(" ", .{});
            } else {
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print("{c}", .{pad_char});
                try IO.print("{s}", .{str});
            }
        } else {
            try IO.print("{s}", .{str});
        }
    }

    /// Helper for printf - format float with precision and width
    fn printfFloat(num: f64, width: usize, precision: usize, left_justify: bool) !void {
        var buf: [64]u8 = undefined;
        // Zig doesn't support runtime precision, so use fixed cases
        const str = switch (precision) {
            0 => std.fmt.bufPrint(&buf, "{d:.0}", .{num}) catch return,
            1 => std.fmt.bufPrint(&buf, "{d:.1}", .{num}) catch return,
            2 => std.fmt.bufPrint(&buf, "{d:.2}", .{num}) catch return,
            3 => std.fmt.bufPrint(&buf, "{d:.3}", .{num}) catch return,
            4 => std.fmt.bufPrint(&buf, "{d:.4}", .{num}) catch return,
            5 => std.fmt.bufPrint(&buf, "{d:.5}", .{num}) catch return,
            else => std.fmt.bufPrint(&buf, "{d:.6}", .{num}) catch return,
        };

        if (width > 0 and str.len < width) {
            const pad = width - str.len;
            if (left_justify) {
                try IO.print("{s}", .{str});
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print(" ", .{});
            } else {
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print(" ", .{});
                try IO.print("{s}", .{str});
            }
        } else {
            try IO.print("{s}", .{str});
        }
    }

    /// Helper for printf %b - print string with escape interpretation
    fn printWithEscapes(str: []const u8) !void {
        var i: usize = 0;
        while (i < str.len) {
            if (str[i] == '\\' and i + 1 < str.len) {
                switch (str[i + 1]) {
                    'n' => try IO.print("\n", .{}),
                    't' => try IO.print("\t", .{}),
                    'r' => try IO.print("\r", .{}),
                    '\\' => try IO.print("\\", .{}),
                    'a' => try IO.print("\x07", .{}),
                    'b' => try IO.print("\x08", .{}),
                    'f' => try IO.print("\x0c", .{}),
                    'v' => try IO.print("\x0b", .{}),
                    'e' => try IO.print("\x1b", .{}),
                    else => {
                        try IO.print("{c}", .{str[i]});
                        i += 1;
                        continue;
                    },
                }
                i += 2;
            } else {
                try IO.print("{c}", .{str[i]});
                i += 1;
            }
        }
    }

    /// Builtin: sleep - pause for specified seconds
    fn builtinSleep(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: sleep: missing operand\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const seconds = std.fmt.parseInt(u32, cmd.args[0], 10) catch {
            try IO.eprint("den: sleep: invalid time interval '{s}'\n", .{cmd.args[0]});
            self.last_exit_code = 1;
            return;
        };

        std.posix.nanosleep(seconds, 0);
        self.last_exit_code = 0;
    }

    /// Builtin: help - show available builtins
    fn builtinHelp(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;
        _ = cmd;

        try IO.print("Den Shell - Built-in Commands\n\n", .{});
        try IO.print("Core Commands:\n", .{});
        try IO.print("  exit              Exit the shell\n", .{});
        try IO.print("  help              Show this help message\n", .{});
        try IO.print("  history [n]       Show command history\n", .{});
        try IO.print("\nFile System:\n", .{});
        try IO.print("  cd [dir]          Change directory\n", .{});
        try IO.print("  pwd               Print working directory\n", .{});
        try IO.print("  pushd [dir]       Push directory to stack and cd\n", .{});
        try IO.print("  popd              Pop directory from stack and cd\n", .{});
        try IO.print("  dirs              Show directory stack\n", .{});
        try IO.print("\nEnvironment:\n", .{});
        try IO.print("  env               Show environment variables\n", .{});
        try IO.print("  export VAR=val    Set and export variable\n", .{});
        try IO.print("  set VAR=val       Set shell variable\n", .{});
        try IO.print("  unset VAR         Unset variable\n", .{});
        try IO.print("\nAliases:\n", .{});
        try IO.print("  alias [name=val]  Define or list aliases\n", .{});
        try IO.print("  unalias name      Remove alias\n", .{});
        try IO.print("\nIntrospection:\n", .{});
        try IO.print("  type name         Identify command type\n", .{});
        try IO.print("  which name        Locate command in PATH\n", .{});
        try IO.print("  complete [-c|-f] prefix  Show completions\n", .{});
        try IO.print("\nJob Control:\n", .{});
        try IO.print("  jobs              List background jobs\n", .{});
        try IO.print("  fg [job_id]       Bring job to foreground\n", .{});
        try IO.print("  bg [job_id]       Continue job in background\n", .{});
        try IO.print("\nScripting:\n", .{});
        try IO.print("  source file       Execute commands from file\n", .{});
        try IO.print("  read var          Read line into variable\n", .{});
        try IO.print("  test expr         Evaluate conditional\n", .{});
        try IO.print("  [ expr ]          Evaluate conditional\n", .{});
        try IO.print("  true              Return success (exit code 0)\n", .{});
        try IO.print("  false             Return failure (exit code 1)\n", .{});
        try IO.print("  sleep n           Pause for n seconds\n", .{});
        try IO.print("  eval args         Execute arguments as command\n", .{});
        try IO.print("  command cmd       Execute bypassing aliases\n", .{});
        try IO.print("  shift [n]         Shift positional parameters\n", .{});
        try IO.print("\nPath Utilities:\n", .{});
        try IO.print("  basename path     Extract filename from path\n", .{});
        try IO.print("  dirname path      Extract directory from path\n", .{});
        try IO.print("  realpath path     Resolve absolute path\n", .{});
        try IO.print("\nSystem Info:\n", .{});
        try IO.print("  uname [-a]        Print system information\n", .{});
        try IO.print("  whoami            Print current username\n", .{});
        try IO.print("  umask [mode]      Get/set file creation mask\n", .{});
        try IO.print("\nPerformance:\n", .{});
        try IO.print("  time command      Measure execution time\n", .{});
        try IO.print("  hash [-r] [cmd]   Command path caching\n", .{});
        try IO.print("\nOutput:\n", .{});
        try IO.print("  echo [args...]    Print arguments\n", .{});
        try IO.print("  printf fmt args   Formatted output\n", .{});
        try IO.print("  clear             Clear terminal screen\n", .{});
        try IO.print("\nScript Control:\n", .{});
        try IO.print("  return [n]        Return from function/script\n", .{});
        try IO.print("  break [n]         Exit from loop\n", .{});
        try IO.print("  continue [n]      Skip to next loop iteration\n", .{});
        try IO.print("  local VAR=val     Declare local variable\n", .{});
        try IO.print("  declare VAR=val   Declare variable with attributes\n", .{});
        try IO.print("  readonly VAR=val  Declare readonly variable\n", .{});
        try IO.print("\nJob Management:\n", .{});
        try IO.print("  kill [-s sig] pid Send signal to process/job\n", .{});
        try IO.print("  wait [pid|job]    Wait for job completion\n", .{});
        try IO.print("  disown [job]      Remove job from table\n", .{});
        try IO.print("\nAdvanced Execution:\n", .{});
        try IO.print("  exec command      Replace shell with command\n", .{});
        try IO.print("  builtin cmd       Execute builtin bypassing functions\n", .{});
        try IO.print("  trap cmd sig      Handle signals (stub)\n", .{});
        try IO.print("  getopts spec var  Parse command options (stub)\n", .{});
        try IO.print("  timeout [-s sig] [-k dur] dur cmd  Execute with timeout\n", .{});
        try IO.print("  times             Display process times\n", .{});
        try IO.print("\nTotal: 54 builtin commands available\n", .{});
        try IO.print("For more help, use 'man bash' or visit docs.den.sh\n", .{});
    }

    /// Builtin: basename - extract filename from path
    fn builtinBasename(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: basename: missing operand\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const path = cmd.args[0];
        const base = std.fs.path.basename(path);

        // Handle optional suffix removal
        if (cmd.args.len > 1) {
            const suffix = cmd.args[1];
            if (std.mem.endsWith(u8, base, suffix)) {
                const trimmed = base[0 .. base.len - suffix.len];
                try IO.print("{s}\n", .{trimmed});
            } else {
                try IO.print("{s}\n", .{base});
            }
        } else {
            try IO.print("{s}\n", .{base});
        }

        self.last_exit_code = 0;
    }

    /// Builtin: dirname - extract directory from path
    fn builtinDirname(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: dirname: missing operand\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const path = cmd.args[0];
        const dir = std.fs.path.dirname(path) orelse ".";
        try IO.print("{s}\n", .{dir});
        self.last_exit_code = 0;
    }

    /// Builtin: realpath - resolve absolute path
    fn builtinRealpath(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: realpath: missing operand\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const path = cmd.args[0];
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = std.fs.cwd().realpath(path, &buf) catch |err| {
            try IO.eprint("den: realpath: {s}: {}\n", .{ path, err });
            self.last_exit_code = 1;
            return;
        };

        try IO.print("{s}\n", .{real});
        self.last_exit_code = 0;
    }

    /// Builtin: command - run command bypassing aliases/builtins
    fn builtinCommand(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: command: missing command argument\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Simplified: execute as a single-command chain
        const single_cmd = types.ParsedCommand{
            .name = cmd.args[0],
            .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
            .redirections = &[_]types.Redirection{},
            .type = .external,
        };

        const cmds = [_]types.ParsedCommand{single_cmd};
        const ops: []types.Operator = &[_]types.Operator{};

        var chain = types.CommandChain{
            .commands = @constCast(&cmds),
            .operators = ops,
        };

        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = executor.executeChain(&chain) catch |err| {
            try IO.eprint("den: command: {}\n", .{err});
            self.last_exit_code = 127;
            return;
        };

        self.last_exit_code = exit_code;
    }

    /// Builtin: eval - execute arguments as shell command
    fn builtinEval(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            self.last_exit_code = 0;
            return;
        }

        // Join all arguments into a single command string
        var cmd_buf: [4096]u8 = undefined;
        var cmd_len: usize = 0;

        for (cmd.args, 0..) |arg, i| {
            if (i > 0 and cmd_len < cmd_buf.len) {
                cmd_buf[cmd_len] = ' ';
                cmd_len += 1;
            }

            const copy_len = @min(arg.len, cmd_buf.len - cmd_len);
            @memcpy(cmd_buf[cmd_len .. cmd_len + copy_len], arg[0..copy_len]);
            cmd_len += copy_len;

            if (cmd_len >= cmd_buf.len) break;
        }

        const command_str = cmd_buf[0..cmd_len];

        // Execute as if typed at prompt
        // Tokenize
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, command_str);
        const tokens = tokenizer.tokenize() catch |err| {
            try IO.eprint("den: eval: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(tokens);

        if (tokens.len == 0) {
            self.last_exit_code = 0;
            return;
        }

        // Parse
        var parser = parser_mod.Parser.init(self.allocator, tokens);
        var chain = parser.parse() catch |err| {
            try IO.eprint("den: eval: {s}\n", .{formatParseError(err)});
            self.last_exit_code = 2;
            return;
        };
        defer chain.deinit(self.allocator);

        // Expand variables and aliases
        try self.expandCommandChain(&chain);
        try self.expandAliases(&chain);

        // Execute
        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = executor.executeChain(&chain) catch |err| {
            try IO.eprint("den: eval: execution error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };

        self.last_exit_code = exit_code;
    }

    /// Builtin: shift - shift positional parameters
    fn builtinShift(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Parse shift count (default 1)
        const n: usize = if (cmd.args.len > 0)
            std.fmt.parseInt(usize, cmd.args[0], 10) catch 1
        else
            1;

        if (n > self.positional_params_count) {
            try IO.eprint("den: shift: shift count too large\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Shift parameters by freeing first n and moving rest
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.positional_params[i]) |param| {
                self.allocator.free(param);
                self.positional_params[i] = null;
            }
        }

        // Move remaining parameters down
        var dest: usize = 0;
        var src: usize = n;
        while (src < self.positional_params.len) : (src += 1) {
            self.positional_params[dest] = self.positional_params[src];
            if (dest != src) {
                self.positional_params[src] = null;
            }
            dest += 1;
        }

        self.positional_params_count -= n;
        self.last_exit_code = 0;
    }

    /// Builtin: time - time command execution
    fn builtinTime(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: time: missing command\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Join arguments to form command
        var cmd_buf: [4096]u8 = undefined;
        var cmd_len: usize = 0;

        for (cmd.args, 0..) |arg, i| {
            if (i > 0 and cmd_len < cmd_buf.len) {
                cmd_buf[cmd_len] = ' ';
                cmd_len += 1;
            }

            const copy_len = @min(arg.len, cmd_buf.len - cmd_len);
            @memcpy(cmd_buf[cmd_len .. cmd_len + copy_len], arg[0..copy_len]);
            cmd_len += copy_len;

            if (cmd_len >= cmd_buf.len) break;
        }

        const command_str = cmd_buf[0..cmd_len];

        // Get start time
        const start_time = std.time.Instant.now() catch {
            try IO.eprint("den: time: cannot get time\n", .{});
            self.last_exit_code = 1;
            return;
        };

        // Execute command
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, command_str);
        const tokens = tokenizer.tokenize() catch |err| {
            try IO.eprint("den: time: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(tokens);

        var parser = parser_mod.Parser.init(self.allocator, tokens);
        var chain = parser.parse() catch |err| {
            try IO.eprint("den: time: {s}\n", .{formatParseError(err)});
            self.last_exit_code = 2;
            return;
        };
        defer chain.deinit(self.allocator);

        try self.expandCommandChain(&chain);
        try self.expandAliases(&chain);

        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = executor.executeChain(&chain) catch |err| {
            try IO.eprint("den: time: execution error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };

        // Get end time and calculate duration
        const end_time = std.time.Instant.now() catch {
            self.last_exit_code = exit_code;
            return;
        };
        const duration_ns: i128 = @intCast(end_time.since(start_time));
        const duration_ms = @divFloor(duration_ns, 1_000_000);
        const duration_s = @divFloor(duration_ms, 1000);
        const remaining_ms = @mod(duration_ms, 1000);

        try IO.eprint("\nreal\t{d}.{d:0>3}s\n", .{ duration_s, remaining_ms });

        self.last_exit_code = exit_code;
    }

    /// Builtin: umask - set file creation mask
    fn builtinUmask(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // Display current umask
            const current = std.c.umask(0);
            _ = std.c.umask(current); // Restore it
            try IO.print("{o:0>4}\n", .{current});
            self.last_exit_code = 0;
        } else {
            // Set new umask
            const new_mask = std.fmt.parseInt(u32, cmd.args[0], 8) catch {
                try IO.eprint("den: umask: invalid octal number: {s}\n", .{cmd.args[0]});
                self.last_exit_code = 1;
                return;
            };

            _ = std.c.umask(@intCast(new_mask));
            self.last_exit_code = 0;
        }
    }

    /// Builtin: clear - clear the terminal screen
    fn builtinClear(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;
        _ = cmd;
        // ANSI escape sequence to clear screen and move cursor to top-left
        try IO.print("\x1b[2J\x1b[H", .{});
    }

    /// Builtin: uname - print system information
    fn builtinUname(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;

        const show_all = cmd.args.len > 0 and std.mem.eql(u8, cmd.args[0], "-a");
        const show_system = cmd.args.len == 0 or show_all or
            (cmd.args.len > 0 and std.mem.eql(u8, cmd.args[0], "-s"));

        if (show_system or show_all) {
            if (builtin.os.tag == .windows) {
                // Windows: simple system identification
                try IO.print("Windows", .{});
                if (show_all) {
                    const machine = if (builtin.cpu.arch == .x86_64) "x86_64" else if (builtin.cpu.arch == .aarch64) "ARM64" else "unknown";
                    try IO.print(" {s} {s} {s} {s}", .{ "localhost", "NT", "10.0", machine });
                }
            } else {
                // POSIX: Get system name from uname
                var utsname: std.posix.utsname = undefined;
                const result = std.c.uname(&utsname);
                if (result == 0) {
                    const sysname = std.mem.sliceTo(&utsname.sysname, 0);
                    try IO.print("{s}", .{sysname});

                    if (show_all) {
                        const nodename = std.mem.sliceTo(&utsname.nodename, 0);
                        const release = std.mem.sliceTo(&utsname.release, 0);
                        const version = std.mem.sliceTo(&utsname.version, 0);
                        const machine = std.mem.sliceTo(&utsname.machine, 0);
                        try IO.print(" {s} {s} {s} {s}", .{ nodename, release, version, machine });
                    }
                }
            }
            try IO.print("\n", .{});
        }
    }

    /// Builtin: whoami - print current username
    fn builtinWhoami(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;
        _ = cmd;

        const user = getenv("USER") orelse
            getenv("LOGNAME") orelse
            "unknown";
        try IO.print("{s}\n", .{user});
    }

    /// Builtin: hash - remember/display command paths (simplified)
    fn builtinHash(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // Display all named directories
            var iter = self.named_dirs.iterator();
            var has_entries = false;
            while (iter.next()) |entry| {
                try IO.print("hash -d {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                has_entries = true;
            }
            if (!has_entries) {
                try IO.print("den: hash: no named directories defined\n", .{});
            }
            self.last_exit_code = 0;
        } else if (std.mem.eql(u8, cmd.args[0], "-d")) {
            // Named directory operations (zsh-style)
            if (cmd.args.len == 1) {
                // List all named directories
                var iter = self.named_dirs.iterator();
                var has_entries = false;
                while (iter.next()) |entry| {
                    try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                    has_entries = true;
                }
                if (!has_entries) {
                    try IO.print("den: hash -d: no named directories defined\n", .{});
                }
                self.last_exit_code = 0;
            } else {
                // Add/update named directory: hash -d name=path
                const arg = cmd.args[1];
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                    const name = arg[0..eq_pos];
                    var path = arg[eq_pos + 1 ..];

                    // Expand ~ in path
                    if (path.len > 0 and path[0] == '~') {
                        if (std.posix.getenv("HOME")) |home| {
                            if (path.len == 1) {
                                path = home;
                            } else if (path[1] == '/') {
                                // ~/ case - need to concatenate
                                const expanded = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, path[1..] });
                                defer self.allocator.free(expanded);

                                // Store the expanded path
                                const name_copy = try self.allocator.dupe(u8, name);
                                const path_copy = try self.allocator.dupe(u8, expanded);

                                // Free old value if exists
                                if (self.named_dirs.get(name)) |old_path| {
                                    self.allocator.free(old_path);
                                    const old_name = self.named_dirs.getKey(name).?;
                                    self.allocator.free(old_name);
                                    _ = self.named_dirs.remove(name);
                                }

                                try self.named_dirs.put(name_copy, path_copy);
                                try IO.print("den: hash -d: {s}={s}\n", .{ name, path_copy });
                                self.last_exit_code = 0;
                                return;
                            }
                        }
                    }

                    // Store the named directory
                    const name_copy = try self.allocator.dupe(u8, name);
                    const path_copy = try self.allocator.dupe(u8, path);

                    // Free old value if exists
                    if (self.named_dirs.get(name)) |old_path| {
                        self.allocator.free(old_path);
                        const old_name = self.named_dirs.getKey(name).?;
                        self.allocator.free(old_name);
                        _ = self.named_dirs.remove(name);
                    }

                    try self.named_dirs.put(name_copy, path_copy);
                    try IO.print("den: hash -d: {s}={s}\n", .{ name, path });
                    self.last_exit_code = 0;
                } else {
                    try IO.eprint("den: hash -d: usage: hash -d name=path\n", .{});
                    self.last_exit_code = 1;
                }
            }
        } else if (std.mem.eql(u8, cmd.args[0], "-r")) {
            // Clear hash table
            try IO.print("den: hash: cache cleared\n", .{});
            self.last_exit_code = 0;
        } else {
            // Add command to hash table
            try IO.print("den: hash: {s} added to cache\n", .{cmd.args[0]});
            self.last_exit_code = 0;
        }
    }

    /// Builtin: return - return from function or script
    fn builtinReturn(self: *Shell, cmd: *types.ParsedCommand) !void {
        const code = if (cmd.args.len > 0)
            std.fmt.parseInt(i32, cmd.args[0], 10) catch 0
        else
            self.last_exit_code;

        // Check if we're inside a function
        if (self.function_manager.currentFrame() != null) {
            // Signal return from function
            self.function_manager.requestReturn(code) catch {
                try IO.eprint("return: can only return from a function or sourced script\n", .{});
                self.last_exit_code = 1;
                return;
            };
        }

        // Set exit code
        self.last_exit_code = code;
    }

    /// Builtin: break - exit from loop
    fn builtinBreak(self: *Shell, cmd: *types.ParsedCommand) !void {
        const levels = if (cmd.args.len > 0)
            std.fmt.parseInt(u32, cmd.args[0], 10) catch 1
        else
            1;

        // Signal break to the loop
        _ = levels; // TODO: support breaking multiple levels
        self.break_requested = true;
        self.last_exit_code = 0;
    }

    /// Builtin: continue - skip to next loop iteration
    fn builtinContinue(self: *Shell, cmd: *types.ParsedCommand) !void {
        const levels = if (cmd.args.len > 0)
            std.fmt.parseInt(u32, cmd.args[0], 10) catch 1
        else
            1;

        // In a full implementation, this would continue N levels of loops
        // For now, just acknowledge the command
        _ = levels;
        self.last_exit_code = 0;
        try IO.print("den: continue: loop control not yet fully implemented\n", .{});
    }

    /// Builtin: local - declare local variables (function scope)
    fn builtinLocal(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Check if we're inside a function
        if (self.function_manager.currentFrame() == null) {
            // Outside function - use environment variables as fallback
            if (cmd.args.len == 0) {
                try IO.eprint("local: can only be used in a function\n", .{});
                self.last_exit_code = 1;
                return;
            }

            // Still set variables for compatibility
            for (cmd.args) |arg| {
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                    const var_name = arg[0..eq_pos];
                    const var_value = arg[eq_pos + 1 ..];
                    const value = try self.allocator.dupe(u8, var_value);
                    const gop = try self.environment.getOrPut(var_name);
                    if (gop.found_existing) {
                        self.allocator.free(gop.value_ptr.*);
                        gop.value_ptr.* = value;
                    } else {
                        const key = try self.allocator.dupe(u8, var_name);
                        gop.key_ptr.* = key;
                        gop.value_ptr.* = value;
                    }
                }
            }
            self.last_exit_code = 0;
            return;
        }

        if (cmd.args.len == 0) {
            // List local variables in current function
            if (self.function_manager.currentFrame()) |frame| {
                var iter = frame.local_vars.iterator();
                while (iter.next()) |entry| {
                    try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            }
            self.last_exit_code = 0;
            return;
        }

        // Set local variables in function scope
        for (cmd.args) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const var_name = arg[0..eq_pos];
                const var_value = arg[eq_pos + 1 ..];
                self.function_manager.setLocal(var_name, var_value) catch {
                    try IO.eprint("local: {s}: failed to set variable\n", .{var_name});
                    self.last_exit_code = 1;
                    return;
                };
            } else {
                // Declare empty variable
                self.function_manager.setLocal(arg, "") catch {
                    try IO.eprint("local: {s}: failed to set variable\n", .{arg});
                    self.last_exit_code = 1;
                    return;
                };
            }
        }
        self.last_exit_code = 0;
    }

    /// Builtin: declare - declare variables with attributes
    fn builtinDeclare(self: *Shell, cmd: *types.ParsedCommand) !void {
        // For now, treat like local
        try self.builtinLocal(cmd);
    }

    /// Builtin: readonly - declare readonly variables
    fn builtinReadonly(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.print("den: readonly: not yet fully implemented\n", .{});
            self.last_exit_code = 0;
            return;
        }

        // For now, just set variables (full impl would mark as readonly)
        for (cmd.args) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const var_name = arg[0..eq_pos];
                const var_value = arg[eq_pos + 1 ..];

                const value = try self.allocator.dupe(u8, var_value);
                const gop = try self.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    self.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    const key = try self.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = value;
                }
            }
        }
        self.last_exit_code = 0;
    }

    /// Execute a one-line C-style for loop: for ((init; cond; update)); do cmd1; cmd2; done
    fn executeCStyleForLoopOneline(self: *Shell, input: []const u8) !void {
        const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

        // Find "for ((" and "))"
        if (!std.mem.startsWith(u8, trimmed, "for ((")) {
            try IO.eprint("den: syntax error: expected 'for ((...))\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Find the closing ))
        const expr_start = 6; // After "for (("
        const expr_end_rel = std.mem.indexOf(u8, trimmed[expr_start..], "))") orelse {
            try IO.eprint("den: syntax error: missing '))'n", .{});
            self.last_exit_code = 1;
            return;
        };
        const expr = trimmed[expr_start..][0..expr_end_rel];

        // Parse init; condition; update
        var parts: [3]?[]const u8 = .{ null, null, null };
        var parts_count: usize = 0;
        var part_iter = std.mem.splitSequence(u8, expr, ";");
        while (part_iter.next()) |part| : (parts_count += 1) {
            if (parts_count >= 3) break;
            const trimmed_part = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (trimmed_part.len > 0) {
                parts[parts_count] = trimmed_part;
            }
        }

        // Find "do" and "done" to extract body
        const after_parens = trimmed[expr_start + expr_end_rel + 2 ..];
        const trimmed_after = std.mem.trim(u8, after_parens, &std.ascii.whitespace);

        // Skip optional ';' after ))
        var body_start = trimmed_after;
        if (body_start.len > 0 and body_start[0] == ';') {
            body_start = std.mem.trim(u8, body_start[1..], &std.ascii.whitespace);
        }

        // Find "do" keyword
        if (!std.mem.startsWith(u8, body_start, "do")) {
            try IO.eprint("den: syntax error: expected 'do'\n", .{});
            self.last_exit_code = 1;
            return;
        }
        body_start = std.mem.trim(u8, body_start[2..], &std.ascii.whitespace);

        // Find "done" keyword - it might be followed by more commands (done; echo $sum)
        const done_pos = std.mem.indexOf(u8, body_start, "done") orelse {
            try IO.eprint("den: syntax error: expected 'done'\n", .{});
            self.last_exit_code = 1;
            return;
        };
        const body_content = std.mem.trim(u8, body_start[0..done_pos], &std.ascii.whitespace);

        // Check if there's anything after 'done' that we need to execute later
        const after_done = body_start[done_pos + 4 ..];
        const remaining_commands = std.mem.trim(u8, after_done, &std.ascii.whitespace);

        // Split body by semicolons (respecting quotes)
        var body_cmds = std.ArrayList([]const u8){};
        defer body_cmds.deinit(self.allocator);

        var cmd_start: usize = 0;
        var in_single_quote = false;
        var in_double_quote = false;
        var i: usize = 0;
        while (i < body_content.len) : (i += 1) {
            const c = body_content[i];
            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
            } else if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
            } else if (c == ';' and !in_single_quote and !in_double_quote) {
                const cmd = std.mem.trim(u8, body_content[cmd_start..i], &std.ascii.whitespace);
                if (cmd.len > 0) {
                    try body_cmds.append(self.allocator, cmd);
                }
                cmd_start = i + 1;
            }
        }
        // Don't forget the last command
        const last_cmd = std.mem.trim(u8, body_content[cmd_start..], &std.ascii.whitespace);
        if (last_cmd.len > 0) {
            try body_cmds.append(self.allocator, last_cmd);
        }

        // Execute the C-style for loop inline
        // 1. Execute initialization
        if (parts[0]) |init_stmt| {
            self.executeArithmeticStatement(init_stmt);
        }

        // 2. Loop while condition is true
        var iteration_count: usize = 0;
        const max_iterations: usize = 100000; // Safety limit
        while (iteration_count < max_iterations) : (iteration_count += 1) {
            // Check condition
            if (parts[1]) |cond| {
                if (!self.evaluateArithmeticCondition(cond)) break;
            }

            // Execute body commands - directly using a simple method that avoids recursion
            for (body_cmds.items) |cmd| {
                self.executeCStyleLoopBodyCommand(cmd);
            }

            // Execute update
            if (parts[2]) |update| {
                self.executeArithmeticStatement(update);
            }
        }

        self.last_exit_code = 0;

        // Execute any remaining commands after "done"
        if (remaining_commands.len > 0) {
            // Strip leading semicolon if present
            var cmds_to_run = remaining_commands;
            if (cmds_to_run[0] == ';') {
                cmds_to_run = std.mem.trim(u8, cmds_to_run[1..], &std.ascii.whitespace);
            }
            if (cmds_to_run.len > 0) {
                // Execute the remaining commands using the simplified executor
                var iter = std.mem.splitScalar(u8, cmds_to_run, ';');
                while (iter.next()) |cmd| {
                    const trimmed_cmd = std.mem.trim(u8, cmd, &std.ascii.whitespace);
                    if (trimmed_cmd.len > 0) {
                        self.executeCStyleLoopBodyCommand(trimmed_cmd);
                    }
                }
            }
        }
    }

    /// Execute a command in the body of a C-style for loop
    /// Handles variable assignments directly, delegates other commands to executeCommand
    fn executeCStyleLoopBodyCommand(self: *Shell, cmd: []const u8) void {
        const trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        // First, expand variables in the command
        var positional_params_slice: [64][]const u8 = undefined;
        var param_count: usize = 0;
        for (self.positional_params) |maybe_param| {
            if (maybe_param) |param| {
                positional_params_slice[param_count] = param;
                param_count += 1;
            }
        }

        var expander = Expansion.initWithShell(
            self.allocator,
            &self.environment,
            self.last_exit_code,
            positional_params_slice[0..param_count],
            self.shell_name,
            self.last_background_pid,
            self.last_arg,
            self,
        );
        const expanded = expander.expand(trimmed) catch {
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(expanded);

        // Handle variable assignment: VAR=value (simple form without command)
        // This is handled specially because executeCommand treats assignments differently
        if (std.mem.indexOf(u8, expanded, "=")) |eq_pos| {
            // Check it's a simple assignment (no spaces before =, no command after)
            const potential_var = expanded[0..eq_pos];
            var is_valid_var = potential_var.len > 0;
            for (potential_var) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') {
                    is_valid_var = false;
                    break;
                }
            }
            if (is_valid_var) {
                // Check if there's a space before the = which would indicate it's not an assignment
                if (std.mem.indexOf(u8, expanded[0..eq_pos], " ") == null) {
                    const value = expanded[eq_pos + 1 ..];
                    self.setArithVariable(potential_var, value);
                    self.last_exit_code = 0;
                    return;
                }
            }
        }

        // Set the flag to prevent nested C-style for loop detection
        const was_in_body = self.in_cstyle_for_body;
        self.in_cstyle_for_body = true;
        defer self.in_cstyle_for_body = was_in_body;

        // Use the full executeCommand for all other commands
        // Errors are silently ignored (exit code set by executeCommand)
        self.executeCommand(expanded) catch {
            self.last_exit_code = 1;
        };
    }

    /// Execute input that contains a C-style for loop with commands before and/or after
    /// Input format: [commands;] for ((...)); do ... done [; commands]
    fn executeWithCStyleForLoop(self: *Shell, input: []const u8) !void {
        const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

        // Find the position of "for ((" in the input
        const for_pos = std.mem.indexOf(u8, trimmed, "for ((") orelse {
            // No for loop found, this shouldn't happen since we checked before calling
            // Use executeCStyleLoopBodyCommand which handles regular commands
            self.executeCStyleLoopBodyCommand(input);
            return;
        };

        // Extract any commands before the for loop
        const before_for = std.mem.trim(u8, trimmed[0..for_pos], &std.ascii.whitespace);

        // Execute commands before the for loop (split by semicolons at top level)
        if (before_for.len > 0) {
            // Remove trailing semicolon if present
            var cmds = before_for;
            if (cmds.len > 0 and cmds[cmds.len - 1] == ';') {
                cmds = std.mem.trim(u8, cmds[0 .. cmds.len - 1], &std.ascii.whitespace);
            }
            if (cmds.len > 0) {
                // Execute the commands before for loop
                self.executeCStyleLoopBodyCommand(cmds);
            }
        }

        // Now extract the for loop (from "for ((" to "done")
        // We need to find the matching "done" - it could have commands after it
        const for_content = trimmed[for_pos..];

        // Find "done" keyword with proper boundary checking
        var done_pos: ?usize = null;
        var search_pos: usize = 0;
        while (search_pos < for_content.len) {
            const maybe_done = std.mem.indexOf(u8, for_content[search_pos..], "done");
            if (maybe_done) |pos| {
                const actual_pos = search_pos + pos;
                // Check that "done" is at word boundary (not part of another word)
                const at_start = actual_pos == 0 or !std.ascii.isAlphanumeric(for_content[actual_pos - 1]);
                const at_end = actual_pos + 4 >= for_content.len or
                    !std.ascii.isAlphanumeric(for_content[actual_pos + 4]);
                if (at_start and at_end) {
                    done_pos = actual_pos;
                    break;
                }
                search_pos = actual_pos + 1;
            } else {
                break;
            }
        }

        if (done_pos == null) {
            try IO.eprint("den: syntax error: expected 'done'\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const for_loop_end = done_pos.? + 4; // "done" is 4 characters
        const for_loop = for_content[0..for_loop_end];

        // Execute the for loop
        try self.executeCStyleForLoopOneline(for_loop);

        // Extract any commands after the for loop
        if (for_loop_end < for_content.len) {
            var after_done = std.mem.trim(u8, for_content[for_loop_end..], &std.ascii.whitespace);
            // Remove leading semicolon if present
            if (after_done.len > 0 and after_done[0] == ';') {
                after_done = std.mem.trim(u8, after_done[1..], &std.ascii.whitespace);
            }
            if (after_done.len > 0) {
                // Execute remaining commands through executeCStyleLoopBodyCommand
                // to handle them properly (it will detect if there's another for loop)
                self.executeCStyleLoopBodyCommand(after_done);
            }
        }
    }

    /// Execute a select loop: select VAR in ITEM1 ITEM2 ...; do BODY; done
    fn executeSelectLoop(self: *Shell, input: []const u8) !void {
        const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

        // Verify it starts with "select "
        if (!std.mem.startsWith(u8, trimmed, "select ")) {
            try IO.eprint("den: syntax error: expected 'select'\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Parse: select VAR in ITEM1 ITEM2 ...; do BODY; done
        const after_select = trimmed[7..]; // After "select "

        // Find " in "
        const in_pos = std.mem.indexOf(u8, after_select, " in ") orelse {
            try IO.eprint("den: syntax error: expected 'in' in select\n", .{});
            self.last_exit_code = 1;
            return;
        };

        const variable = std.mem.trim(u8, after_select[0..in_pos], &std.ascii.whitespace);
        if (variable.len == 0) {
            try IO.eprint("den: syntax error: missing variable in select\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Find "; do" or just "do"
        const after_in = after_select[in_pos + 4 ..]; // After " in "
        const do_pos = std.mem.indexOf(u8, after_in, "; do") orelse
            std.mem.indexOf(u8, after_in, ";do") orelse {
            try IO.eprint("den: syntax error: expected 'do' in select\n", .{});
            self.last_exit_code = 1;
            return;
        };

        // Extract items
        const items_str = std.mem.trim(u8, after_in[0..do_pos], &std.ascii.whitespace);
        if (items_str.len == 0) {
            try IO.eprint("den: syntax error: no items in select\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Parse items (space-separated words)
        var items_buf: [100][]const u8 = undefined;
        var items_count: usize = 0;
        var items_iter = std.mem.tokenizeAny(u8, items_str, " \t");
        while (items_iter.next()) |item| {
            if (items_count >= items_buf.len) break;
            items_buf[items_count] = item;
            items_count += 1;
        }

        if (items_count == 0) {
            try IO.eprint("den: syntax error: no items in select\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Find body (between "do" and "done")
        const do_keyword_len: usize = if (std.mem.indexOf(u8, after_in, "; do") != null) 4 else 3;
        const body_start_offset = do_pos + do_keyword_len;
        const body_and_rest = after_in[body_start_offset..];

        const done_pos = std.mem.indexOf(u8, body_and_rest, "done") orelse {
            try IO.eprint("den: syntax error: expected 'done' in select\n", .{});
            self.last_exit_code = 1;
            return;
        };

        var body_str = std.mem.trim(u8, body_and_rest[0..done_pos], &std.ascii.whitespace);
        // Remove leading semicolon if present
        if (body_str.len > 0 and body_str[0] == ';') {
            body_str = std.mem.trim(u8, body_str[1..], &std.ascii.whitespace);
        }
        // Remove trailing semicolon if present
        if (body_str.len > 0 and body_str[body_str.len - 1] == ';') {
            body_str = std.mem.trim(u8, body_str[0 .. body_str.len - 1], &std.ascii.whitespace);
        }

        // Get PS3 prompt (or use default)
        const ps3 = self.environment.get("PS3") orelse "#? ";

        // Interactive select loop
        const posix = std.posix;

        // Display menu
        try IO.print("\n", .{});
        for (items_buf[0..items_count], 1..) |item, idx| {
            try IO.print("{d}) {s}\n", .{ idx, item });
        }

        // Main select loop
        while (true) {
            // Display prompt
            try IO.print("{s}", .{ps3});

            // Read input from stdin
            var input_buf: [1024]u8 = undefined;
            const bytes_read = posix.read(posix.STDIN_FILENO, &input_buf) catch |err| {
                if (err == error.WouldBlock) continue;
                break;
            };

            if (bytes_read == 0) {
                // EOF
                break;
            }

            const user_input = std.mem.trim(u8, input_buf[0..bytes_read], &std.ascii.whitespace);

            // Empty input - redisplay menu
            if (user_input.len == 0) {
                try IO.print("\n", .{});
                for (items_buf[0..items_count], 1..) |item, idx| {
                    try IO.print("{d}) {s}\n", .{ idx, item });
                }
                continue;
            }

            // Parse selection
            const selection = std.fmt.parseInt(usize, user_input, 10) catch {
                // Invalid number - set variable empty and run body
                self.setArithVariable(variable, "");
                self.setArithVariable("REPLY", user_input);
                self.executeSelectBody(body_str);
                if (self.break_requested) {
                    self.break_requested = false;
                    break;
                }
                continue;
            };

            if (selection == 0 or selection > items_count) {
                // Invalid selection - set variable empty and run body
                self.setArithVariable(variable, "");
                var reply_buf: [32]u8 = undefined;
                const reply_str = std.fmt.bufPrint(&reply_buf, "{d}", .{selection}) catch continue;
                self.setArithVariable("REPLY", reply_str);
                self.executeSelectBody(body_str);
                if (self.break_requested) {
                    self.break_requested = false;
                    break;
                }
                continue;
            }

            // Valid selection
            const selected_item = items_buf[selection - 1];
            self.setArithVariable(variable, selected_item);
            var reply_buf: [32]u8 = undefined;
            const reply_str = std.fmt.bufPrint(&reply_buf, "{d}", .{selection}) catch continue;
            self.setArithVariable("REPLY", reply_str);

            // Execute body
            self.executeSelectBody(body_str);

            // Check for break
            if (self.break_requested) {
                self.break_requested = false;
                break;
            }
        }

        self.last_exit_code = 0;
    }

    /// Execute select loop body command (non-recursive helper)
    fn executeSelectBody(self: *Shell, body: []const u8) void {
        // Split body by semicolons and execute each command
        var cmd_iter = std.mem.splitSequence(u8, body, ";");
        while (cmd_iter.next()) |cmd| {
            const trimmed_cmd = std.mem.trim(u8, cmd, &std.ascii.whitespace);
            if (trimmed_cmd.len == 0) continue;

            // Check for break
            if (std.mem.eql(u8, trimmed_cmd, "break")) {
                self.break_requested = true;
                return;
            }

            // Execute the command using executeCStyleLoopBodyCommand which handles recursion safely
            self.executeCStyleLoopBodyCommand(trimmed_cmd);

            if (self.break_requested) return;
        }
    }

    /// Execute arithmetic statement (like i=0 or i++)
    fn executeArithmeticStatement(self: *Shell, stmt: []const u8) void {
        const trimmed = std.mem.trim(u8, stmt, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        // Handle i++ and i--
        if (std.mem.endsWith(u8, trimmed, "++")) {
            const var_name = trimmed[0 .. trimmed.len - 2];
            const current = self.getVariableValueForArith(var_name);
            const num = std.fmt.parseInt(i64, current, 10) catch 0;
            var buf: [32]u8 = undefined;
            const new_val = std.fmt.bufPrint(&buf, "{d}", .{num + 1}) catch return;
            self.setArithVariable(var_name, new_val);
            return;
        }
        if (std.mem.endsWith(u8, trimmed, "--")) {
            const var_name = trimmed[0 .. trimmed.len - 2];
            const current = self.getVariableValueForArith(var_name);
            const num = std.fmt.parseInt(i64, current, 10) catch 0;
            var buf: [32]u8 = undefined;
            const new_val = std.fmt.bufPrint(&buf, "{d}", .{num - 1}) catch return;
            self.setArithVariable(var_name, new_val);
            return;
        }

        // Handle assignment: var=expr
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const var_name = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
            const expr = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

            // Evaluate the expression
            const value = self.evaluateArithmeticExpr(expr);
            var buf: [32]u8 = undefined;
            const val_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
            self.setArithVariable(var_name, val_str);
        }
    }

    /// Set a variable for arithmetic operations
    fn setArithVariable(self: *Shell, name: []const u8, value: []const u8) void {
        // Dupe the value
        const val = self.allocator.dupe(u8, value) catch return;

        // Get or put entry to avoid memory leak
        const gop = self.environment.getOrPut(name) catch {
            self.allocator.free(val);
            return;
        };
        if (gop.found_existing) {
            // Free old value and update
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = val;
        } else {
            // New key - duplicate it
            const key = self.allocator.dupe(u8, name) catch {
                self.allocator.free(val);
                _ = self.environment.remove(name);
                return;
            };
            gop.key_ptr.* = key;
            gop.value_ptr.* = val;
        }
    }

    /// Evaluate arithmetic condition (returns true if non-zero)
    fn evaluateArithmeticCondition(self: *Shell, cond: []const u8) bool {
        const trimmed = std.mem.trim(u8, cond, &std.ascii.whitespace);
        if (trimmed.len == 0) return true; // Empty condition is always true

        // Handle comparison operators
        if (std.mem.indexOf(u8, trimmed, "<=")) |pos| {
            const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
            const right = self.evaluateArithmeticExpr(trimmed[pos + 2 ..]);
            return left <= right;
        }
        if (std.mem.indexOf(u8, trimmed, ">=")) |pos| {
            const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
            const right = self.evaluateArithmeticExpr(trimmed[pos + 2 ..]);
            return left >= right;
        }
        if (std.mem.indexOf(u8, trimmed, "!=")) |pos| {
            const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
            const right = self.evaluateArithmeticExpr(trimmed[pos + 2 ..]);
            return left != right;
        }
        if (std.mem.indexOf(u8, trimmed, "==")) |pos| {
            const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
            const right = self.evaluateArithmeticExpr(trimmed[pos + 2 ..]);
            return left == right;
        }
        if (std.mem.indexOf(u8, trimmed, "<")) |pos| {
            const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
            const right = self.evaluateArithmeticExpr(trimmed[pos + 1 ..]);
            return left < right;
        }
        if (std.mem.indexOf(u8, trimmed, ">")) |pos| {
            const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
            const right = self.evaluateArithmeticExpr(trimmed[pos + 1 ..]);
            return left > right;
        }

        // Otherwise, evaluate as expression and check if non-zero
        return self.evaluateArithmeticExpr(trimmed) != 0;
    }

    /// Evaluate arithmetic expression
    fn evaluateArithmeticExpr(self: *Shell, expr: []const u8) i64 {
        const trimmed = std.mem.trim(u8, expr, &std.ascii.whitespace);
        if (trimmed.len == 0) return 0;

        // Handle addition
        if (std.mem.lastIndexOf(u8, trimmed, "+")) |pos| {
            if (pos > 0 and pos < trimmed.len - 1) {
                const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
                const right = self.evaluateArithmeticExpr(trimmed[pos + 1 ..]);
                return left + right;
            }
        }

        // Handle subtraction (be careful with negative numbers)
        var i: usize = trimmed.len;
        while (i > 0) {
            i -= 1;
            if (trimmed[i] == '-' and i > 0) {
                const left = self.evaluateArithmeticExpr(trimmed[0..i]);
                const right = self.evaluateArithmeticExpr(trimmed[i + 1 ..]);
                return left - right;
            }
        }

        // Handle multiplication
        if (std.mem.lastIndexOf(u8, trimmed, "*")) |pos| {
            if (pos > 0 and pos < trimmed.len - 1) {
                const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
                const right = self.evaluateArithmeticExpr(trimmed[pos + 1 ..]);
                return left * right;
            }
        }

        // Handle division
        if (std.mem.lastIndexOf(u8, trimmed, "/")) |pos| {
            if (pos > 0 and pos < trimmed.len - 1) {
                const left = self.evaluateArithmeticExpr(trimmed[0..pos]);
                const right = self.evaluateArithmeticExpr(trimmed[pos + 1 ..]);
                if (right == 0) return 0;
                return @divTrunc(left, right);
            }
        }

        // Try to parse as number
        if (std.fmt.parseInt(i64, trimmed, 10)) |num| {
            return num;
        } else |_| {}

        // Otherwise, treat as variable name
        const val = self.getVariableValueForArith(trimmed);
        return std.fmt.parseInt(i64, val, 10) catch 0;
    }

    /// Get variable value (helper for arithmetic)
    fn getVariableValueForArith(self: *Shell, name: []const u8) []const u8 {
        if (self.environment.get(name)) |val| {
            return val;
        }
        return "0";
    }

    /// Check if input is an array assignment: name=(value1 value2 ...)
    fn isArrayAssignment(input: []const u8) bool {
        // Look for pattern: name=(...)
        const eq_pos = std.mem.indexOfScalar(u8, input, '=') orelse return false;
        if (eq_pos >= input.len - 1) return false;
        if (input[eq_pos + 1] != '(') return false;

        // Check for closing paren
        return std.mem.indexOfScalar(u8, input[eq_pos + 2..], ')') != null;
    }

    /// Parse and execute array assignment
    fn executeArrayAssignment(self: *Shell, input: []const u8) !void {
        const eq_pos = std.mem.indexOfScalar(u8, input, '=') orelse return error.InvalidSyntax;
        const name = std.mem.trim(u8, input[0..eq_pos], &std.ascii.whitespace);

        // Validate variable name
        if (name.len == 0) return error.InvalidVariableName;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                return error.InvalidVariableName;
            }
        }

        // Find array content between ( and )
        const start_paren = eq_pos + 1;
        if (input[start_paren] != '(') return error.InvalidSyntax;

        const end_paren = std.mem.lastIndexOfScalar(u8, input, ')') orelse return error.InvalidSyntax;
        if (end_paren <= start_paren + 1) {
            // Empty array: name=()
            const key = try self.allocator.dupe(u8, name);
            const empty_array = try self.allocator.alloc([]const u8, 0);

            // Free old array if exists
            if (self.arrays.get(name)) |old_array| {
                for (old_array) |item| {
                    self.allocator.free(item);
                }
                self.allocator.free(old_array);
                const old_key = self.arrays.getKey(name).?;
                self.allocator.free(old_key);
                _ = self.arrays.remove(name);
            }

            try self.arrays.put(key, empty_array);
            self.last_exit_code = 0;
            return;
        }

        // Parse array elements
        const content = std.mem.trim(u8, input[start_paren + 1..end_paren], &std.ascii.whitespace);

        // Count elements first
        var count: usize = 0;
        var count_iter = std.mem.tokenizeAny(u8, content, &std.ascii.whitespace);
        while (count_iter.next()) |_| {
            count += 1;
        }

        // Allocate array
        const array = try self.allocator.alloc([]const u8, count);
        errdefer self.allocator.free(array);

        // Fill array
        var i: usize = 0;
        var iter = std.mem.tokenizeAny(u8, content, &std.ascii.whitespace);
        while (iter.next()) |token| : (i += 1) {
            array[i] = try self.allocator.dupe(u8, token);
        }

        // Store array
        const key = try self.allocator.dupe(u8, name);

        // Free old array if exists
        if (self.arrays.get(name)) |old_array| {
            for (old_array) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(old_array);
            const old_key = self.arrays.getKey(name).?;
            self.allocator.free(old_key);
            _ = self.arrays.remove(name);
        }

        try self.arrays.put(key, array);
        self.last_exit_code = 0;
    }

    /// Builtin: exec - replace shell with command
    fn builtinExec(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: exec: command required\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // In a full implementation, this would use execvpe to replace the shell process
        // For now, execute the command and set running=false to exit the shell
        const new_cmd = types.ParsedCommand{
            .name = cmd.args[0],
            .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
            .redirections = &[_]types.Redirection{},
        };

        const cmds = [_]types.ParsedCommand{new_cmd};
        const ops = [_]types.Operator{};
        var chain = types.CommandChain{
            .commands = @constCast(&cmds),
            .operators = @constCast(&ops),
        };

        // Execute the command
        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = try executor.executeChain(&chain);
        self.last_exit_code = exit_code;

        // Mark shell as not running to exit after this command
        self.running = false;
    }

    /// Builtin: wait - wait for job completion
    fn builtinWait(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            if (builtin.os.tag == .windows) {
                // Windows: wait command not yet fully implemented
                try IO.print("wait: not fully implemented on Windows\n", .{});
                self.last_exit_code = 0;
                return;
            }

            // POSIX: Wait for all background jobs
            var waited = false;
            for (&self.background_jobs) |*maybe_job| {
                if (maybe_job.*) |*job| {
                    if (job.pid > 0) {
                        const result = std.posix.waitpid(job.pid, 0);
                        job.pid = 0; // Mark as completed
                        waited = true;
                        _ = result;
                    }
                }
            }
            self.last_exit_code = if (waited) 0 else 127;
            return;
        }

        // Wait for specific job(s)
        if (builtin.os.tag == .windows) {
            // Windows: wait command not yet fully implemented
            try IO.print("wait: not fully implemented on Windows\n", .{});
            self.last_exit_code = 0;
            return;
        }

        for (cmd.args) |arg| {
            if (arg[0] == '%') {
                const job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: wait: {s}: invalid job specification\n", .{arg});
                    self.last_exit_code = 1;
                    continue;
                };

                if (job_id > 0 and job_id <= self.background_jobs.len) {
                    if (self.background_jobs[job_id - 1]) |*job| {
                        if (job.pid > 0) {
                            const result = std.posix.waitpid(job.pid, 0);
                            job.pid = 0;
                            self.last_exit_code = 0;
                            _ = result;
                        }
                    }
                }
            } else {
                // Wait by PID
                const pid = std.fmt.parseInt(i32, arg, 10) catch {
                    try IO.eprint("den: wait: {s}: not a valid process id\n", .{arg});
                    self.last_exit_code = 1;
                    continue;
                };
                const result = std.posix.waitpid(pid, 0);
                self.last_exit_code = 0;
                _ = result;
            }
        }
    }

    /// Builtin: kill - send signal to job or process
    fn builtinKill(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (builtin.os.tag == .windows) {
            // Windows: kill command not yet fully implemented
            try IO.print("kill: not fully implemented on Windows\n", .{});
            self.last_exit_code = 0;
            return;
        }

        // Check for -l flag (list signals)
        if (cmd.args.len >= 1) {
            const first_arg = cmd.args[0];
            if (std.mem.eql(u8, first_arg, "-l") or std.mem.eql(u8, first_arg, "-L")) {
                // List all signals
                const signal_table = [_]struct { num: u6, name: []const u8 }{
                    .{ .num = 1, .name = "HUP" },
                    .{ .num = 2, .name = "INT" },
                    .{ .num = 3, .name = "QUIT" },
                    .{ .num = 4, .name = "ILL" },
                    .{ .num = 5, .name = "TRAP" },
                    .{ .num = 6, .name = "ABRT" },
                    .{ .num = 7, .name = "BUS" },
                    .{ .num = 8, .name = "FPE" },
                    .{ .num = 9, .name = "KILL" },
                    .{ .num = 10, .name = "USR1" },
                    .{ .num = 11, .name = "SEGV" },
                    .{ .num = 12, .name = "USR2" },
                    .{ .num = 13, .name = "PIPE" },
                    .{ .num = 14, .name = "ALRM" },
                    .{ .num = 15, .name = "TERM" },
                    .{ .num = 17, .name = "CHLD" },
                    .{ .num = 18, .name = "CONT" },
                    .{ .num = 19, .name = "STOP" },
                    .{ .num = 20, .name = "TSTP" },
                    .{ .num = 21, .name = "TTIN" },
                    .{ .num = 22, .name = "TTOU" },
                    .{ .num = 23, .name = "URG" },
                    .{ .num = 24, .name = "XCPU" },
                    .{ .num = 25, .name = "XFSZ" },
                    .{ .num = 26, .name = "VTALRM" },
                    .{ .num = 27, .name = "PROF" },
                    .{ .num = 28, .name = "WINCH" },
                    .{ .num = 29, .name = "IO" },
                    .{ .num = 30, .name = "PWR" },
                    .{ .num = 31, .name = "SYS" },
                };

                // If a signal number is given after -l, print just that signal name
                if (cmd.args.len >= 2) {
                    const sig_num = std.fmt.parseInt(u6, cmd.args[1], 10) catch {
                        try IO.eprint("den: kill: {s}: invalid signal specification\n", .{cmd.args[1]});
                        self.last_exit_code = 1;
                        return;
                    };
                    for (signal_table) |sig| {
                        if (sig.num == sig_num) {
                            try IO.print("{s}\n", .{sig.name});
                            self.last_exit_code = 0;
                            return;
                        }
                    }
                    try IO.eprint("den: kill: {d}: invalid signal specification\n", .{sig_num});
                    self.last_exit_code = 1;
                    return;
                }

                // Print all signals
                var col: usize = 0;
                for (signal_table) |sig| {
                    try IO.print("{d:>2}) SIG{s: <8}", .{ sig.num, sig.name });
                    col += 1;
                    if (col >= 4) {
                        try IO.print("\n", .{});
                        col = 0;
                    }
                }
                if (col > 0) {
                    try IO.print("\n", .{});
                }
                self.last_exit_code = 0;
                return;
            }
        }

        if (cmd.args.len == 0) {
            try IO.eprint("den: kill: usage: kill [-s sigspec | -n signum | -sigspec] pid | jobspec ...\n", .{});
            self.last_exit_code = 1;
            return;
        }

        var signal: std.posix.SIG = .TERM; // Default signal
        var arg_idx: usize = 0;

        // Parse signal specification
        if (cmd.args.len > 1 and cmd.args[0][0] == '-') {
            const sig_arg = cmd.args[0];
            if (sig_arg.len > 1) {
                // Try to parse as name (e.g., -TERM, -KILL)
                const sig_name = sig_arg[1..];
                if (std.mem.eql(u8, sig_name, "TERM")) {
                    signal = .TERM;
                } else if (std.mem.eql(u8, sig_name, "KILL")) {
                    signal = .KILL;
                } else if (std.mem.eql(u8, sig_name, "INT")) {
                    signal = .INT;
                } else if (std.mem.eql(u8, sig_name, "HUP")) {
                    signal = .HUP;
                } else if (std.mem.eql(u8, sig_name, "STOP")) {
                    signal = .STOP;
                } else if (std.mem.eql(u8, sig_name, "CONT")) {
                    signal = .CONT;
                } else if (std.fmt.parseInt(u32, sig_arg[1..], 10)) |sig_num| {
                    // Try to parse as number (e.g., -9)
                    signal = @enumFromInt(sig_num);
                } else |_| {
                    try IO.eprint("den: kill: {s}: invalid signal specification\n", .{sig_name});
                    self.last_exit_code = 1;
                    return;
                }
                arg_idx = 1;
            }
        }

        // Send signal to each specified process/job
        while (arg_idx < cmd.args.len) : (arg_idx += 1) {
            const target = cmd.args[arg_idx];

            if (target[0] == '%') {
                // Job specification
                const job_id = std.fmt.parseInt(usize, target[1..], 10) catch {
                    try IO.eprint("den: kill: {s}: invalid job specification\n", .{target});
                    self.last_exit_code = 1;
                    continue;
                };

                if (job_id > 0 and job_id <= self.background_jobs.len) {
                    if (self.background_jobs[job_id - 1]) |job| {
                        if (job.pid > 0) {
                            std.posix.kill(job.pid, signal) catch {
                                try IO.eprint("den: kill: ({d}) - No such process\n", .{job.pid});
                                self.last_exit_code = 1;
                                continue;
                            };
                        }
                    }
                }
            } else {
                // PID specification
                const pid = std.fmt.parseInt(i32, target, 10) catch {
                    try IO.eprint("den: kill: {s}: arguments must be process or job IDs\n", .{target});
                    self.last_exit_code = 1;
                    continue;
                };

                std.posix.kill(pid, signal) catch {
                    try IO.eprint("den: kill: ({d}) - No such process\n", .{pid});
                    self.last_exit_code = 1;
                    continue;
                };
            }
        }

        self.last_exit_code = 0;
    }

    /// Builtin: disown - remove jobs from job table
    fn builtinDisown(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // Disown most recent job
            var found = false;
            var i: usize = self.background_jobs.len;
            while (i > 0) {
                i -= 1;
                if (self.background_jobs[i]) |_| {
                    self.background_jobs[i] = null;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try IO.eprint("den: disown: current: no such job\n", .{});
                self.last_exit_code = 1;
            }
            return;
        }

        // Disown specific jobs
        for (cmd.args) |arg| {
            if (arg[0] == '%') {
                const job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: disown: {s}: no such job\n", .{arg});
                    self.last_exit_code = 1;
                    continue;
                };

                if (job_id > 0 and job_id <= self.background_jobs.len) {
                    self.background_jobs[job_id - 1] = null;
                } else {
                    try IO.eprint("den: disown: %{d}: no such job\n", .{job_id});
                    self.last_exit_code = 1;
                }
            }
        }
        self.last_exit_code = 0;
    }

    /// Builtin: trap - handle signals and special events
    fn builtinTrap(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.print("den: trap: full signal handling not yet implemented\n", .{});
            self.last_exit_code = 0;
            return;
        }

        // Stub - full implementation would register signal handlers
        try IO.print("den: trap: registering handler for signals (stub)\n", .{});
        self.last_exit_code = 0;
    }

    /// Builtin: getopts - parse command options
    fn builtinGetopts(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = cmd;
        try IO.print("den: getopts: option parsing not yet implemented\n", .{});
        self.last_exit_code = 1;
    }

    /// Builtin: times - display process times
    fn builtinTimes(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = cmd;
        try IO.print("0m0.000s 0m0.000s\n", .{}); // Shell user/sys time
        try IO.print("0m0.000s 0m0.000s\n", .{}); // Children user/sys time
        self.last_exit_code = 0;
    }

    /// Builtin: builtin - execute builtin command
    fn builtinBuiltin(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: builtin: usage: builtin [shell-builtin [arg ...]]\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Execute the specified builtin, bypassing any functions with the same name
        const builtin_name = cmd.args[0];
        const new_cmd = types.ParsedCommand{
            .name = builtin_name,
            .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
            .redirections = &[_]types.Redirection{},
        };

        // Create a simple chain with just this command
        const cmds = [_]types.ParsedCommand{new_cmd};
        const ops = [_]types.Operator{};
        var chain = types.CommandChain{
            .commands = @constCast(&cmds),
            .operators = @constCast(&ops),
        };

        // Execute using executor (builtins will be dispatched there)
        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = try executor.executeChain(&chain);
        self.last_exit_code = exit_code;
    }

    fn hasBunLock(self: *Shell, cwd: []const u8) bool {
        _ = self;
        const lock_files = [_][]const u8{ "bun.lockb", "bun.lock" };

        for (lock_files) |filename| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, filename }) catch continue;

            // Just check if file exists
            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            file.close();
            return true;
        }

        return false;
    }

    fn detectPackageVersion(self: *Shell, cwd: []const u8) ![]const u8 {
        const filenames = [_][]const u8{ "package.json", "package.jsonc", "pantry.json", "pantry.jsonc" };

        for (filenames) |filename| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, filename }) catch continue;

            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();

            const max_size: usize = 8192;
            const file_size = file.getEndPos() catch continue;
            const read_size: usize = @min(file_size, max_size);
            const buffer = self.allocator.alloc(u8, read_size) catch continue;
            defer self.allocator.free(buffer);
            var total_read: usize = 0;
            while (total_read < read_size) {
                const n = file.read(buffer[total_read..]) catch break;
                if (n == 0) break;
                total_read += n;
            }
            const content = buffer[0..total_read];

            var i: usize = 0;
            while (i < content.len) : (i += 1) {
                if (std.mem.startsWith(u8, content[i..], "\"version\"")) {
                    var j = i + 9;
                    while (j < content.len and (content[j] == ' ' or content[j] == '\t' or content[j] == ':')) : (j += 1) {}
                    if (j < content.len and content[j] == '"') {
                        j += 1;
                        const start = j;
                        while (j < content.len and content[j] != '"') : (j += 1) {}
                        if (j > start) {
                            return self.allocator.dupe(u8, content[start..j]) catch continue;
                        }
                    }
                }
            }
        }

        return error.NotFound;
    }

    fn detectBunVersion(self: *Shell) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "bun", "--version" },
        }) catch return error.NotFound;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
                    if (trimmed.len > 0) {
                        return try self.allocator.dupe(u8, trimmed);
                    }
                }
            },
            else => {},
        }

        return error.NotFound;
    }

    fn detectNodeVersion(self: *Shell) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "node", "--version" },
        }) catch return error.NotFound;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    var trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
                    // Remove leading 'v' if present
                    if (trimmed.len > 0 and trimmed[0] == 'v') {
                        trimmed = trimmed[1..];
                    }
                    if (trimmed.len > 0) {
                        return try self.allocator.dupe(u8, trimmed);
                    }
                }
            },
            else => {},
        }

        return error.NotFound;
    }

    fn detectPythonVersion(self: *Shell) ![]const u8 {
        // Try python3 first, then python
        const commands = [_][]const []const u8{
            &[_][]const u8{ "python3", "--version" },
            &[_][]const u8{ "python", "--version" },
        };

        for (commands) |cmd| {
            const result = std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = cmd,
            }) catch continue;

            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);

            switch (result.term) {
                .Exited => |code| {
                    if (code == 0) {
                        // Python --version outputs to stdout: "Python 3.12.0"
                        const output = if (result.stdout.len > 0) result.stdout else result.stderr;
                        const trimmed = std.mem.trim(u8, output, &std.ascii.whitespace);

                        // Parse "Python X.Y.Z" to get just "X.Y.Z"
                        if (std.mem.startsWith(u8, trimmed, "Python ")) {
                            const version = std.mem.trim(u8, trimmed[7..], &std.ascii.whitespace);
                            if (version.len > 0) {
                                return try self.allocator.dupe(u8, version);
                            }
                        }
                    }
                },
                else => {},
            }
        }

        return error.NotFound;
    }

    fn detectRubyVersion(self: *Shell) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "ruby", "--version" },
        }) catch return error.NotFound;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);

                    // Parse "ruby 3.3.0p0 (2023-12-25 revision ...)" to get just "3.3.0"
                    if (std.mem.startsWith(u8, trimmed, "ruby ")) {
                        const version_start: usize = 5;
                        var version_end: usize = version_start;
                        while (version_end < trimmed.len and trimmed[version_end] != ' ' and trimmed[version_end] != 'p') {
                            version_end += 1;
                        }
                        if (version_end > version_start) {
                            return try self.allocator.dupe(u8, trimmed[version_start..version_end]);
                        }
                    }
                }
            },
            else => {},
        }

        return error.NotFound;
    }

    fn detectGoVersion(self: *Shell) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "go", "version" },
        }) catch return error.NotFound;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);

                    // Parse "go version go1.22.0 darwin/arm64" to get just "1.22.0"
                    if (std.mem.indexOf(u8, trimmed, "go")) |idx| {
                        const after_go = trimmed[idx + 2..];
                        if (std.mem.indexOf(u8, after_go, "go")) |version_idx| {
                            const version_start = version_idx + 2;
                            var version_end = version_start;
                            while (version_end < after_go.len and after_go[version_end] != ' ') {
                                version_end += 1;
                            }
                            if (version_end > version_start) {
                                return try self.allocator.dupe(u8, after_go[version_start..version_end]);
                            }
                        }
                    }
                }
            },
            else => {},
        }

        return error.NotFound;
    }

    fn detectRustVersion(self: *Shell) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "rustc", "--version" },
        }) catch return error.NotFound;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);

                    // Parse "rustc 1.75.0 (82e1608df 2023-12-21)" to get just "1.75.0"
                    if (std.mem.startsWith(u8, trimmed, "rustc ")) {
                        const version_start: usize = 6;
                        var version_end: usize = version_start;
                        while (version_end < trimmed.len and trimmed[version_end] != ' ') {
                            version_end += 1;
                        }
                        if (version_end > version_start) {
                            return try self.allocator.dupe(u8, trimmed[version_start..version_end]);
                        }
                    }
                }
            },
            else => {},
        }

        return error.NotFound;
    }

    fn detectZigVersion(self: *Shell) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "zig", "version" },
        }) catch return error.NotFound;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
                    if (trimmed.len > 0) {
                        return try self.allocator.dupe(u8, trimmed);
                    }
                }
            },
            else => {},
        }

        return error.NotFound;
    }
};


/// Tab completion function for line editor
/// Callback to refresh the prompt (e.g., when Cmd+K clears screen)
/// This updates the prompt to reflect current directory changes
fn refreshPromptCallback(editor: *LineEditor) !void {
    // Get current directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "/";

    // Get home directory to abbreviate with ~
    const home = std.posix.getenv("HOME");

    // Build a simple prompt with current directory
    var prompt_buf: [4096]u8 = undefined;
    const prompt = if (home) |h| blk: {
        if (std.mem.startsWith(u8, cwd, h)) {
            const relative = cwd[h.len..];
            if (relative.len == 0) {
                break :blk std.fmt.bufPrint(&prompt_buf, "den ~> ", .{}) catch "den> ";
            } else {
                break :blk std.fmt.bufPrint(&prompt_buf, "den ~{s}> ", .{relative}) catch "den> ";
            }
        }
        break :blk std.fmt.bufPrint(&prompt_buf, "den {s}> ", .{cwd}) catch "den> ";
    } else std.fmt.bufPrint(&prompt_buf, "den {s}> ", .{cwd}) catch "den> ";

    // Free the old prompt first
    editor.allocator.free(editor.prompt);

    // Allocate and set new prompt
    editor.prompt = try editor.allocator.dupe(u8, prompt);
}

/// Global completion configuration (set by Shell during initialization)
/// This allows the static tabCompletionFn to access completion settings
var g_completion_config: types.CompletionConfig = .{};
var g_completion_config_initialized: bool = false;

/// Set the global completion configuration
pub fn setCompletionConfig(config: types.CompletionConfig) void {
    g_completion_config = config;
    g_completion_config_initialized = true;
}

/// Get the global completion configuration
pub fn getCompletionConfig() types.CompletionConfig {
    return g_completion_config;
}

fn tabCompletionFn(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    // Check if completion is enabled via config
    if (g_completion_config_initialized and !g_completion_config.enabled) {
        return &[_][]const u8{};
    }

    var completion = Completion.init(allocator);
    var ctx_completion = ContextCompletion.init(allocator);

    // If input is empty, show nothing
    if (input.len == 0) {
        return &[_][]const u8{};
    }

    // Find the first word (command) and current word being completed
    var first_word_end: usize = 0;
    while (first_word_end < input.len) : (first_word_end += 1) {
        const c = input[first_word_end];
        if (c == ' ' or c == '\t') break;
    }

    var word_start: usize = 0;
    for (input, 0..) |c, i| {
        if (c == ' ' or c == '\t' or c == '|' or c == '&' or c == ';') {
            word_start = i + 1;
        }
    }
    const prefix = input[word_start..];
    const command = input[0..first_word_end];

    // If first word, try command completion
    if (word_start == 0) {
        return completion.completeCommand(prefix);
    }

    // Check for environment variable completion ($...)
    if (prefix.len > 0 and prefix[0] == '$') {
        const env_prefix = if (prefix.len > 1) prefix[1..] else "";
        const items = try ctx_completion.completeEnvVars(env_prefix);
        if (items.len > 0) {
            var results = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |item, i| {
                results[i] = try std.fmt.allocPrint(allocator, "${s}", .{item.text});
                allocator.free(item.text);
            }
            allocator.free(items);
            return results;
        }
        allocator.free(items);
    }

    // Check for option/flag completion (-...)
    if (prefix.len > 0 and prefix[0] == '-') {
        const items = try ctx_completion.completeOptions(command, prefix);
        if (items.len > 0) {
            var results = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |item, i| {
                results[i] = try allocator.dupe(u8, item.text);
                allocator.free(item.text);
            }
            allocator.free(items);
            return results;
        }
        allocator.free(items);
    }

    // For cd command, only complete directories
    if (std.mem.eql(u8, command, "cd")) {
        return completion.completeDirectory(prefix);
    }

    // For git command, show branches, files, subcommands
    if (std.mem.eql(u8, command, "git")) {
        return try completeGit(allocator, input, prefix);
    }

    // For bun command, show scripts, commands, and files
    if (std.mem.eql(u8, command, "bun")) {
        return try completeBun(allocator, prefix);
    }

    // For npm command, show scripts, commands, and files
    if (std.mem.eql(u8, command, "npm")) {
        return try completeNpm(allocator, prefix);
    }

    // For yarn command, show scripts, commands, and files
    if (std.mem.eql(u8, command, "yarn")) {
        return try completeYarn(allocator, input, prefix);
    }

    // For pnpm command, show scripts, commands, and files
    if (std.mem.eql(u8, command, "pnpm")) {
        return try completePnpm(allocator, input, prefix);
    }

    // For docker command, show containers, images, subcommands
    if (std.mem.eql(u8, command, "docker")) {
        return try completeDocker(allocator, input, prefix);
    }

    // Otherwise, try file completion
    const results = try completion.completeFile(prefix);

    // Apply max_suggestions limit from config
    if (g_completion_config_initialized and g_completion_config.max_suggestions > 0) {
        const max = @as(usize, g_completion_config.max_suggestions);
        if (results.len > max) {
            // Free excess results
            for (results[max..]) |r| {
                allocator.free(r);
            }
            // Shrink the slice
            const limited = allocator.realloc(results, max) catch results[0..max];
            return limited;
        }
    }

    return results;
}

/// Get completions for git command (branches, files, subcommands)
fn completeGit(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8){ .items = &[_][]const u8{}, .capacity = 0 };
    defer results.deinit(allocator);

    // Parse to find the git subcommand
    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    _ = tokens.next(); // Skip "git"
    const subcommand = tokens.next(); // Get subcommand (if any)

    const git_commands = [_][]const u8{
        "add", "bisect", "branch", "checkout", "cherry-pick", "clone", "commit",
        "diff", "fetch", "grep", "init", "log", "merge", "mv", "pull", "push",
        "rebase", "reset", "restore", "revert", "rm", "show", "stash", "status",
        "switch", "tag",
    };

    // If no subcommand yet, or if we're still typing the subcommand (prefix matches subcommand),
    // show matching git subcommands
    if (subcommand == null or (subcommand != null and std.mem.eql(u8, subcommand.?, prefix))) {
        for (git_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, prefix)) {
                const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
                try results.append(allocator, marked_cmd);
            }
        }

        const owned = try allocator.alloc([]const u8, results.items.len);
        @memcpy(owned, results.items);
        return owned;
    }

    // At this point, we have a complete subcommand and are completing arguments

    // Branch-related subcommands: checkout, branch, merge, rebase, switch
    const branch_commands = [_][]const u8{ "checkout", "branch", "merge", "rebase", "switch", "cherry-pick" };
    for (branch_commands) |branch_cmd| {
        if (std.mem.eql(u8, subcommand.?, branch_cmd)) {
            return try getGitBranches(allocator, prefix);
        }
    }

    // File-related subcommands: add, diff, restore, reset
    const file_commands = [_][]const u8{ "add", "diff", "restore", "reset" };
    for (file_commands) |file_cmd| {
        if (std.mem.eql(u8, subcommand.?, file_cmd)) {
            return try getGitModifiedFiles(allocator, prefix);
        }
    }

    // For other subcommands, don't provide completions
    return &[_][]const u8{};
}

/// Get git branches for completion
fn getGitBranches(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8){ .items = &[_][]const u8{}, .capacity = 0 };
    defer results.deinit(allocator);

    // Run: git branch -a --format=%(refname:short)
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "branch", "-a", "--format=%(refname:short)" },
    }) catch {
        return &[_][]const u8{};
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return &[_][]const u8{};
    }

    // Parse output line by line
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Skip remote tracking branches that are duplicates
        if (std.mem.startsWith(u8, trimmed, "remotes/origin/")) {
            const branch_name = trimmed["remotes/origin/".len..];
            // Skip HEAD pointer
            if (std.mem.eql(u8, branch_name, "HEAD")) continue;
        }

        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const branch = try allocator.dupe(u8, trimmed);
            try results.append(allocator, branch);
        }
    }

    const owned = try allocator.alloc([]const u8, results.items.len);
    @memcpy(owned, results.items);
    return owned;
}

/// Get modified files from git status
fn getGitModifiedFiles(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8){ .items = &[_][]const u8{}, .capacity = 0 };
    defer results.deinit(allocator);

    // Run: git status --porcelain
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
    }) catch {
        return &[_][]const u8{};
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return &[_][]const u8{};
    }

    // Parse output line by line
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 3) continue;

        // Format: "XY filename" where XY are status codes
        const filename = std.mem.trim(u8, line[3..], &std.ascii.whitespace);
        if (filename.len == 0) continue;

        if (std.mem.startsWith(u8, filename, prefix)) {
            const file = try allocator.dupe(u8, filename);
            try results.append(allocator, file);
        }
    }

    const owned = try allocator.alloc([]const u8, results.items.len);
    @memcpy(owned, results.items);
    return owned;
}

/// Get completions for bun command (scripts, commands, files)
fn completeBun(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8){ .items = &[_][]const u8{}, .capacity = 0 };
    defer results.deinit(allocator);

    // Bun built-in commands
    const bun_commands = [_][]const u8{
        "add", "bun", "create", "dev", "help",
        "install", "pm", "remove", "run", "upgrade", "x",
    };

    // Add matching bun commands (mark with \x02 for default styling)
    for (bun_commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, prefix)) {
            const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
            try results.append(allocator, marked_cmd);
        }
    }

    // Try to read package.json and extract scripts
    const package_json = std.fs.cwd().readFileAlloc("package.json", allocator, std.Io.Limit.limited(1024 * 1024)) catch null;
    if (package_json) |json_content| {
        defer allocator.free(json_content);

        // Simple JSON parsing to find scripts
        const scripts_start = std.mem.indexOf(u8, json_content, "\"scripts\"");
        if (scripts_start) |start| {
            // Find the opening brace after "scripts"
            var brace_pos = start;
            while (brace_pos < json_content.len and json_content[brace_pos] != '{') : (brace_pos += 1) {}

            if (brace_pos < json_content.len) {
                // Find matching closing brace
                var depth: i32 = 1;
                var pos = brace_pos + 1;
                var scripts_end: usize = brace_pos + 1;

                while (pos < json_content.len and depth > 0) : (pos += 1) {
                    if (json_content[pos] == '{') depth += 1;
                    if (json_content[pos] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            scripts_end = pos;
                            break;
                        }
                    }
                }

                const scripts_section = json_content[brace_pos + 1 .. scripts_end];

                // Extract script names (simple approach: find quoted strings before colons)
                var i: usize = 0;
                while (i < scripts_section.len) : (i += 1) {
                    if (scripts_section[i] == '"') {
                        const name_start = i + 1;
                        var name_end = name_start;
                        while (name_end < scripts_section.len and scripts_section[name_end] != '"') : (name_end += 1) {}

                        if (name_end < scripts_section.len) {
                            const script_name = scripts_section[name_start..name_end];

                            // Check if this is followed by a colon (it's a key)
                            var check_pos = name_end + 1;
                            while (check_pos < scripts_section.len and (scripts_section[check_pos] == ' ' or scripts_section[check_pos] == '\t' or scripts_section[check_pos] == '\n')) : (check_pos += 1) {}

                            if (check_pos < scripts_section.len and scripts_section[check_pos] == ':') {
                                // This is a script name!
                                if (std.mem.startsWith(u8, script_name, prefix)) {
                                    // Check for duplicates
                                    var is_dup = false;
                                    for (results.items) |existing| {
                                        if (std.mem.eql(u8, existing, script_name)) {
                                            is_dup = true;
                                            break;
                                        }
                                    }
                                    if (!is_dup) {
                                        // Mark scripts with \x02 prefix so they can be styled differently
                                        const marked_name = try std.fmt.allocPrint(allocator, "\x02{s}", .{script_name});
                                        try results.append(allocator, marked_name);
                                    }
                                }
                            }

                            i = name_end;
                        }
                    }
                }
            }
        }
    }

    // Add matching files from current directory
    var completion = Completion.init(allocator);
    const file_completions = try completion.completeFile(prefix);
    defer {
        for (file_completions) |c| {
            allocator.free(c);
        }
        allocator.free(file_completions);
    }

    for (file_completions) |file| {
        // Check for duplicates
        var is_dup = false;
        for (results.items) |existing| {
            if (std.mem.eql(u8, existing, file)) {
                is_dup = true;
                break;
            }
        }
        if (!is_dup) {
            try results.append(allocator, try allocator.dupe(u8, file));
        }
    }

    return try results.toOwnedSlice(allocator);
}

/// Get completions for npm command (scripts, commands, files)
fn completeNpm(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8){ .items = &[_][]const u8{}, .capacity = 0 };
    defer results.deinit(allocator);

    // NPM built-in commands
    const npm_commands = [_][]const u8{
        "install", "i", "add", "run", "test", "start", "build",
        "init", "update", "uninstall", "remove", "rm", "publish",
        "version", "outdated", "ls", "link", "unlink", "cache",
        "audit", "fund", "doctor", "exec", "ci", "prune",
    };

    // Add matching npm commands (mark with \x02 for default styling)
    for (npm_commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, prefix)) {
            const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
            try results.append(allocator, marked_cmd);
        }
    }

    // Try to read package.json and extract scripts
    const package_json = std.fs.cwd().readFileAlloc("package.json", allocator, std.Io.Limit.limited(1024 * 1024)) catch null;
    if (package_json) |json_content| {
        defer allocator.free(json_content);

        // Simple JSON parsing to find scripts
        const scripts_start = std.mem.indexOf(u8, json_content, "\"scripts\"");
        if (scripts_start) |start| {
            // Find the opening brace after "scripts"
            var brace_pos = start;
            while (brace_pos < json_content.len and json_content[brace_pos] != '{') : (brace_pos += 1) {}

            if (brace_pos < json_content.len) {
                // Find matching closing brace
                var depth: i32 = 1;
                var pos = brace_pos + 1;
                var scripts_end: usize = brace_pos + 1;

                while (pos < json_content.len and depth > 0) : (pos += 1) {
                    if (json_content[pos] == '{') depth += 1;
                    if (json_content[pos] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            scripts_end = pos;
                            break;
                        }
                    }
                }

                const scripts_section = json_content[brace_pos + 1 .. scripts_end];

                // Extract script names (simple approach: find quoted strings before colons)
                var i: usize = 0;
                while (i < scripts_section.len) : (i += 1) {
                    if (scripts_section[i] == '"') {
                        const name_start = i + 1;
                        var name_end = name_start;
                        while (name_end < scripts_section.len and scripts_section[name_end] != '"') : (name_end += 1) {}

                        if (name_end < scripts_section.len) {
                            const script_name = scripts_section[name_start..name_end];

                            // Check if this is followed by a colon (it's a key)
                            var check_pos = name_end + 1;
                            while (check_pos < scripts_section.len and (scripts_section[check_pos] == ' ' or scripts_section[check_pos] == '\t' or scripts_section[check_pos] == '\n')) : (check_pos += 1) {}

                            if (check_pos < scripts_section.len and scripts_section[check_pos] == ':') {
                                // This is a script name!
                                if (std.mem.startsWith(u8, script_name, prefix)) {
                                    // Check for duplicates
                                    var is_dup = false;
                                    for (results.items) |existing| {
                                        if (std.mem.eql(u8, existing, script_name)) {
                                            is_dup = true;
                                            break;
                                        }
                                    }
                                    if (!is_dup) {
                                        // Mark scripts with \x02 prefix so they can be styled differently
                                        const marked_name = try std.fmt.allocPrint(allocator, "\x02{s}", .{script_name});
                                        try results.append(allocator, marked_name);
                                    }
                                }
                            }

                            i = name_end;
                        }
                    }
                }
            }
        }
    }

    // Add matching files from current directory
    var completion = Completion.init(allocator);
    const file_completions = try completion.completeFile(prefix);
    defer {
        for (file_completions) |c| {
            allocator.free(c);
        }
        allocator.free(file_completions);
    }

    for (file_completions) |file| {
        // Check for duplicates
        var is_dup = false;
        for (results.items) |existing| {
            if (std.mem.eql(u8, existing, file)) {
                is_dup = true;
                break;
            }
        }
        if (!is_dup) {
            try results.append(allocator, try allocator.dupe(u8, file));
        }
    }

    return try results.toOwnedSlice(allocator);
}

/// Get completions for yarn command (scripts, commands, files)
fn completeYarn(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![][]const u8 {
    _ = input;
    var results = std.ArrayList([]const u8){ .items = &[_][]const u8{}, .capacity = 0 };
    defer results.deinit(allocator);

    // Yarn built-in commands
    const yarn_commands = [_][]const u8{
        "add", "audit", "autoclean", "bin", "cache", "config",
        "create", "dedupe", "dlx", "exec", "explain", "info",
        "init", "install", "link", "node", "npm", "pack",
        "patch", "patch-commit", "plugin", "rebuild", "remove",
        "run", "search", "set", "stage", "start", "test",
        "unlink", "unplug", "up", "upgrade", "upgrade-interactive",
        "version", "why", "workspace", "workspaces",
    };

    // Add matching yarn commands
    for (yarn_commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, prefix)) {
            const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
            try results.append(allocator, marked_cmd);
        }
    }

    // Try to read package.json scripts
    var ctx_completion = ContextCompletion.init(allocator);
    const script_items = try ctx_completion.completeNpmScripts(prefix);
    for (script_items) |item| {
        const marked_name = try std.fmt.allocPrint(allocator, "\x02{s}", .{item.text});
        try results.append(allocator, marked_name);
        allocator.free(item.text);
    }
    allocator.free(script_items);

    return try results.toOwnedSlice(allocator);
}

/// Get completions for pnpm command (scripts, commands, files)
fn completePnpm(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![][]const u8 {
    _ = input;
    var results = std.ArrayList([]const u8){ .items = &[_][]const u8{}, .capacity = 0 };
    defer results.deinit(allocator);

    // pnpm built-in commands
    const pnpm_commands = [_][]const u8{
        "add", "audit", "bin", "config", "create", "dedupe",
        "dlx", "env", "exec", "fetch", "import", "init",
        "install", "install-test", "link", "list", "outdated",
        "pack", "patch", "patch-commit", "prune", "publish",
        "rebuild", "recursive", "remove", "root", "run",
        "server", "setup", "start", "store", "test", "unlink",
        "update", "why",
    };

    // Add matching pnpm commands
    for (pnpm_commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, prefix)) {
            const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
            try results.append(allocator, marked_cmd);
        }
    }

    // Try to read package.json scripts
    var ctx_completion = ContextCompletion.init(allocator);
    const script_items = try ctx_completion.completeNpmScripts(prefix);
    for (script_items) |item| {
        const marked_name = try std.fmt.allocPrint(allocator, "\x02{s}", .{item.text});
        try results.append(allocator, marked_name);
        allocator.free(item.text);
    }
    allocator.free(script_items);

    return try results.toOwnedSlice(allocator);
}

/// Get completions for docker command (containers, images, subcommands)
fn completeDocker(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8){ .items = &[_][]const u8{}, .capacity = 0 };
    defer results.deinit(allocator);

    // Parse to find the docker subcommand
    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    _ = tokens.next(); // Skip "docker"
    const subcommand = tokens.next(); // Get subcommand (if any)

    // Docker subcommands
    const docker_commands = [_][]const u8{
        "attach", "build", "commit", "compose", "container", "cp",
        "create", "diff", "events", "exec", "export", "history",
        "image", "images", "import", "info", "inspect", "kill",
        "load", "login", "logout", "logs", "network", "node",
        "pause", "plugin", "port", "ps", "pull", "push", "rename",
        "restart", "rm", "rmi", "run", "save", "search", "service",
        "stack", "start", "stats", "stop", "swarm", "system",
        "tag", "top", "trust", "unpause", "update", "version",
        "volume", "wait",
    };

    // If no subcommand yet, show docker subcommands
    if (subcommand == null or (subcommand != null and std.mem.eql(u8, subcommand.?, prefix))) {
        for (docker_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, prefix)) {
                const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
                try results.append(allocator, marked_cmd);
            }
        }
        return try results.toOwnedSlice(allocator);
    }

    // Container-related subcommands
    const container_commands = [_][]const u8{ "start", "stop", "restart", "rm", "logs", "exec", "attach", "kill", "pause", "unpause" };
    for (container_commands) |container_cmd| {
        if (std.mem.eql(u8, subcommand.?, container_cmd)) {
            var ctx_completion = ContextCompletion.init(allocator);
            const items = try ctx_completion.completeDockerContainers(prefix);
            for (items) |item| {
                try results.append(allocator, try allocator.dupe(u8, item.text));
                allocator.free(item.text);
            }
            allocator.free(items);
            return try results.toOwnedSlice(allocator);
        }
    }

    // Image-related subcommands
    const image_commands = [_][]const u8{ "run", "pull", "push", "rmi", "tag", "save", "load" };
    for (image_commands) |image_cmd| {
        if (std.mem.eql(u8, subcommand.?, image_cmd)) {
            var ctx_completion = ContextCompletion.init(allocator);
            const items = try ctx_completion.completeDockerImages(prefix);
            for (items) |item| {
                try results.append(allocator, try allocator.dupe(u8, item.text));
                allocator.free(item.text);
            }
            allocator.free(items);
            return try results.toOwnedSlice(allocator);
        }
    }

    return try results.toOwnedSlice(allocator);
}

test "shell initialization" {
    const allocator = std.testing.allocator;
    var sh = try Shell.init(allocator);
    defer sh.deinit();

    try std.testing.expect(!sh.running);
}

    fn detectPackageVersion(self: *Shell, cwd: []const u8) ![]const u8 {
        // Try package.json, package.jsonc, pantry.json, pantry.jsonc
        const filenames = [_][]const u8{ "package.json", "package.jsonc", "pantry.json", "pantry.jsonc" };

        for (filenames) |filename| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, filename }) catch continue;

            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();

            // Read file (limit to 8KB for safety)
            const max_size: usize = 8192;
            const file_size = file.getEndPos() catch continue;
            const read_size: usize = @min(file_size, max_size);
            const buffer = self.allocator.alloc(u8, read_size) catch continue;
            defer self.allocator.free(buffer);
            var total_read: usize = 0;
            while (total_read < read_size) {
                const n = file.read(buffer[total_read..]) catch break;
                if (n == 0) break;
                total_read += n;
            }
            const content = buffer[0..total_read];

            // Simple JSON parsing to find "version": "x.y.z"
            var i: usize = 0;
            while (i < content.len) : (i += 1) {
                if (std.mem.startsWith(u8, content[i..], "\"version\"")) {
                    // Find the value
                    var j = i + 9; // Skip "version"
                    while (j < content.len and (content[j] == ' ' or content[j] == '\t' or content[j] == ':')) : (j += 1) {}
                    if (j < content.len and content[j] == '"') {
                        j += 1; // Skip opening quote
                        const start = j;
                        while (j < content.len and content[j] != '"') : (j += 1) {}
                        if (j > start) {
                            return self.allocator.dupe(u8, content[start..j]) catch continue;
                        }
                    }
                }
            }
        }

        return error.NotFound;
    }

    fn detectBunVersion(self: *Shell) ![]const u8 {
        // Check if bun exists and get version
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "bun", "--version" },
        }) catch return error.NotFound;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                return try self.allocator.dupe(u8, trimmed);
            }
        }

        return error.NotFound;
    }

    fn detectZigVersion(self: *Shell) ![]const u8 {
        // Check if zig exists and get version  
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "zig", "version" },
        }) catch return error.NotFound;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                return try self.allocator.dupe(u8, trimmed);
            }
        }

        return error.NotFound;
    }
