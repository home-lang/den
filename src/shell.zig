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
const LoadableBuiltins = @import("utils/loadable.zig").LoadableBuiltins;
const History = @import("history/history.zig").History;
const jobs_mod = @import("jobs/mod.zig");
const JobManager = jobs_mod.JobManager;
const JobStatus = jobs_mod.JobStatus;
const ProcessId = jobs_mod.ProcessId;
const BackgroundJob = jobs_mod.BackgroundJob;
const regex = @import("utils/regex.zig");
const matchRegexAt = regex.matchRegexAt;
const config_watch = @import("utils/config_watch.zig");
const getConfigMtime = config_watch.getConfigMtime;
const shell_mod = @import("shell/mod.zig");

/// Hard limit for in-memory history entries.
/// This ensures predictable memory usage regardless of config.history.max_entries.
/// The effective max is min(config.history.max_entries, HISTORY_HARD_LIMIT).
const HISTORY_HARD_LIMIT: usize = 1000;

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

/// Call stack frame for caller builtin
pub const CallFrame = struct {
    line_number: usize,
    function_name: []const u8,
    source_file: []const u8,
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    config: types.DenConfig,
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    global_aliases: std.StringHashMap([]const u8), // zsh-style global aliases (expanded anywhere, not just command position)
    suffix_aliases: std.StringHashMap([]const u8), // extension -> command (zsh-style suffix aliases)
    last_exit_code: i32,
    job_manager: JobManager,
    // History buffer: fixed-size array with effective_max from config
    // Note: max hard limit is 1000 for predictable memory; config.history.max_entries
    // can be smaller but not larger than this.
    history: [HISTORY_HARD_LIMIT]?[]const u8,
    history_count: usize,
    history_max: usize, // Effective max from config (capped at HISTORY_HARD_LIMIT)
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
    // Counter for break statement in loops (0 = no break, N = break N levels)
    break_levels: u32,
    // Counter for continue statement in loops (0 = no continue, N = continue N levels)
    continue_levels: u32,
    // Coprocess tracking
    coproc_pid: ?std.posix.pid_t,
    coproc_read_fd: ?std.posix.fd_t,
    coproc_write_fd: ?std.posix.fd_t,
    // Config hot-reload tracking
    config_source: config_loader.ConfigSource,
    config_last_mtime: i128,
    // Variable attributes (for declare/typeset)
    var_attributes: std.StringHashMap(types.VarAttributes),
    // Associative arrays (declare -A)
    assoc_arrays: std.StringHashMap(std.StringHashMap([]const u8)),
    // Shopt options
    shopt_extglob: bool, // Extended glob patterns
    shopt_nullglob: bool, // Patterns that match nothing expand to empty
    shopt_dotglob: bool, // Patterns match dotfiles
    shopt_nocaseglob: bool, // Case-insensitive globbing
    shopt_globstar: bool, // ** matches recursively
    shopt_failglob: bool, // Failed globs cause error
    shopt_expand_aliases: bool, // Expand aliases in non-interactive shells
    shopt_sourcepath: bool, // Search PATH for source command
    shopt_checkwinsize: bool, // Check window size after each command
    shopt_histappend: bool, // Append to history file
    shopt_cmdhist: bool, // Save multi-line commands in history
    shopt_autocd: bool, // Directory names auto-cd
    // Call stack for caller builtin
    call_stack: [64]CallFrame,
    call_stack_depth: usize,
    // Loadable builtins (dynamically loaded shared libraries)
    loadable_builtins: LoadableBuiltins,

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

        // Build history file path from config (expand ~ to home directory)
        var history_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_history_file = config.history.file;
        const history_path = if (std.mem.startsWith(u8, config_history_file, "~/"))
            try std.fmt.bufPrint(&history_path_buf, "{s}/{s}", .{ home, config_history_file[2..] })
        else if (std.mem.eql(u8, config_history_file, "~"))
            home
        else
            config_history_file;
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
            .global_aliases = std.StringHashMap([]const u8).init(allocator),
            .suffix_aliases = std.StringHashMap([]const u8).init(allocator),
            .last_exit_code = 0,
            .job_manager = JobManager.init(allocator),
            .history = [_]?[]const u8{null} ** HISTORY_HARD_LIMIT,
            .history_count = 0,
            .history_max = @min(config.history.max_entries, HISTORY_HARD_LIMIT),
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
            .highlighter = null, // Initialized on demand
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
            .break_levels = 0,
            .continue_levels = 0,
            .coproc_pid = null,
            .coproc_read_fd = null,
            .coproc_write_fd = null,
            .config_source = config_source,
            .config_last_mtime = config_mtime,
            .var_attributes = std.StringHashMap(types.VarAttributes).init(allocator),
            .assoc_arrays = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .shopt_extglob = true, // Enabled by default (we implemented it)
            .shopt_nullglob = false,
            .shopt_dotglob = false,
            .shopt_nocaseglob = false,
            .shopt_globstar = false,
            .shopt_failglob = false,
            .shopt_expand_aliases = true,
            .shopt_sourcepath = true,
            .shopt_checkwinsize = true,
            .shopt_histappend = false,
            .shopt_cmdhist = true,
            .shopt_autocd = false,
            .call_stack = [_]CallFrame{CallFrame{ .line_number = 0, .function_name = "", .source_file = "" }} ** 64,
            .call_stack_depth = 0,
            .loadable_builtins = LoadableBuiltins.init(allocator),
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
        shell_mod.setCompletionConfig(config.completion);

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

        // Clean up loadable builtins
        self.loadable_builtins.deinit();

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

        // Clean up job manager (kills and frees all background jobs)
        self.job_manager.deinit();

        // Clean up history (only clean up entries that were actually used)
        History.deinit(self.allocator, self.history[0..self.history_max], self.history_file_path);

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

        // Clean up global aliases (keys and values were allocated)
        var global_iter = self.global_aliases.iterator();
        while (global_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.global_aliases.deinit();

        // Clean up suffix aliases (keys and values were allocated)
        var suffix_iter = self.suffix_aliases.iterator();
        while (suffix_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.suffix_aliases.deinit();

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
            try self.job_manager.checkCompleted();

            // Read line from stdin
            const line = blk: {
                if (self.is_interactive) {
                    // Initialize line editor on first use
                    if (self.line_editor == null) {
                        const prompt_str = try self.getPromptString();
                        var editor = LineEditor.init(self.allocator, prompt_str);
                        editor.setHistory(&self.history, &self.history_count);
                        editor.setCompletionFn(shell_mod.tabCompletionFn);
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
        return try shell_mod.checkFunctionDefinitionStart(self, trimmed);
    }

    fn handleMultilineContinuation(self: *Shell, trimmed: []const u8) !void {
        try shell_mod.handleMultilineContinuation(self, trimmed);
    }

    fn finishFunctionDefinition(self: *Shell) !void {
        try shell_mod.finishFunctionDefinition(self);
    }

    fn resetMultilineState(self: *Shell) void {
        shell_mod.resetMultilineState(self);
    }

    fn renderPrompt(self: *Shell) !void {
        try shell_mod.renderPrompt(self);
    }

    fn getPromptString(self: *Shell) ![]const u8 {
        return try shell_mod.getPromptString(self);
    }

    fn updatePromptContext(self: *Shell) !void {
        try shell_mod.updatePromptContext(self);
    }

    pub fn executeCommand(self: *Shell, input: []const u8) !void {
        // Check for array assignment first
        if (shell_mod.isArrayAssignment(input)) {
            try shell_mod.executeArrayAssignment(self, input);
            return;
        }

        // Check for simple variable assignment: VAR=value (no spaces before =)
        // This handles both regular assignments and nameref assignments
        const trimmed_input = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (std.mem.indexOf(u8, trimmed_input, "=")) |eq_pos| {
            // Check if this is a simple assignment (no spaces before =, valid var name)
            const potential_var = trimmed_input[0..eq_pos];
            // Verify it's a valid variable name (no spaces, starts with letter or underscore)
            if (potential_var.len > 0 and
                std.mem.indexOfScalar(u8, potential_var, ' ') == null and
                (std.ascii.isAlphabetic(potential_var[0]) or potential_var[0] == '_'))
            {
                var is_valid_var = true;
                for (potential_var) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '_') {
                        is_valid_var = false;
                        break;
                    }
                }
                // Also verify there's no additional command after the assignment
                // e.g., "VAR=value cmd" should not be handled here
                if (is_valid_var and eq_pos + 1 <= trimmed_input.len) {
                    const rest = trimmed_input[eq_pos + 1 ..];
                    // Check if there are any spaces after the value that indicate more commands
                    // Handle quoted strings and special cases
                    var in_single_quote = false;
                    var in_double_quote = false;
                    var found_space_outside_quotes = false;
                    for (rest) |c| {
                        if (c == '\'' and !in_double_quote) {
                            in_single_quote = !in_single_quote;
                        } else if (c == '"' and !in_single_quote) {
                            in_double_quote = !in_double_quote;
                        } else if (c == ' ' and !in_single_quote and !in_double_quote) {
                            found_space_outside_quotes = true;
                            break;
                        }
                    }
                    if (!found_space_outside_quotes) {
                        // Simple assignment - use setArithVariable which resolves namerefs
                        const value = trimmed_input[eq_pos + 1 ..];
                        shell_mod.setArithVariable(self, potential_var, value);
                        self.last_exit_code = 0;
                        return;
                    }
                }
            }
        }

        // Check for C-style for loop: for ((init; cond; update)); do ... done
        // Skip this check if we're already inside a C-style for loop body to avoid recursion
        if (!self.in_cstyle_for_body and std.mem.startsWith(u8, trimmed_input, "for ((")) {
            try shell_mod.executeCStyleForLoopOneline(self, input);
            return;
        }

        // Check for select loop: select VAR in ITEM1 ITEM2; do ... done
        if (std.mem.startsWith(u8, trimmed_input, "select ")) {
            try shell_mod.executeSelectLoop(self, input);
            return;
        }

        // Check if input contains a C-style for loop after other commands (e.g., "total=0; for ((...")
        // This handles cases like: total=0; for ((i=1; i<=5; i++)); do total=$((total + i)); done; echo $total
        if (!self.in_cstyle_for_body and std.mem.indexOf(u8, trimmed_input, "for ((") != null) {
            try shell_mod.executeWithCStyleForLoop(self, input);
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

        // Fast path for simple commands (no pipes, redirects, operators, or expansions)
        // This avoids the full tokenizer/parser for common cases like "ls", "echo hello", etc.
        if (self.tryFastPath(trimmed_input)) |exit_code| {
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

        // Tokenize
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, input);
        const tokens = tokenizer.tokenize() catch |err| {
            try IO.eprint("den: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer tokenizer.deinitTokens(tokens);

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
            if (try shell_mod.dispatchBuiltin(self, cmd) == .handled) {
                return;
            }
        }

        // Check if this is a background job (last operator is &)
        const is_background = chain.operators.len > 0 and
            chain.operators[chain.operators.len - 1] == .background;

        if (is_background) {
            // Execute in background
            try shell_mod.executeInBackground(self, &chain, input);
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

    /// Try fast path for simple commands.
    /// Returns exit code if handled, null to fall back to full parser.
    fn tryFastPath(self: *Shell, input: []const u8) ?i32 {
        return shell_mod.tryFastPath(self, input);
    }

    pub fn executeErrTrap(self: *Shell) void {
        shell_mod.executeErrTrap(self);
    }

    pub fn expandCommandChain(self: *Shell, chain: *types.CommandChain) !void {
        try shell_mod.expandCommandChain(self, chain);
    }

    /// Add command to history (respects config.history.max_entries)
    fn addToHistory(self: *Shell, command: []const u8) !void {
        try History.add(
            self.allocator,
            self.history[0..self.history_max],
            &self.history_count,
            self.history_file_path,
            command,
        );
    }

    /// Load history from file (respects config.history.max_entries)
    fn loadHistory(self: *Shell) !void {
        try History.load(
            self.allocator,
            self.history[0..self.history_max],
            &self.history_count,
            self.history_file_path,
        );
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

        // Load suffix aliases from config (zsh-style: extension -> command)
        if (self.config.aliases.suffix) |suffix_aliases| {
            for (suffix_aliases) |suffix_entry| {
                const ext_copy = try self.allocator.dupe(u8, suffix_entry.extension);
                const cmd_copy = try self.allocator.dupe(u8, suffix_entry.command);
                try self.suffix_aliases.put(ext_copy, cmd_copy);
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
        try History.save(self.history[0..self.history_max], self.history_file_path);
    }

    /// Append a single command to history file (incremental append)
    fn appendToHistoryFile(self: *Shell, command: []const u8) !void {
        try History.appendToFile(self.history_file_path, command);
    }

    /// Expand aliases in command chain with circular reference detection
    pub fn expandAliases(self: *Shell, chain: *types.CommandChain) !void {
        try shell_mod.expandAliases(self, chain);
    }

    /// Resolve nameref: follow nameref chain to get the actual variable name
    /// Returns the final variable name after following any nameref references
    /// Max depth of 10 to prevent infinite loops
    pub fn resolveNameref(self: *Shell, name: []const u8) []const u8 {
        return shell_mod.resolveNameref(self, name);
    }

    pub fn getVariableValue(self: *Shell, name: []const u8) ?[]const u8 {
        return shell_mod.getVariableValue(self, name);
    }

    pub fn setVariableValue(self: *Shell, name: []const u8, value: []const u8) !void {
        try shell_mod.setVariableValue(self, name, value);
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
