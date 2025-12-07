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
                        self.setArithVariable(potential_var, value);
                        self.last_exit_code = 0;
                        return;
                    }
                }
            }
        }

        // Check for C-style for loop: for ((init; cond; update)); do ... done
        // Skip this check if we're already inside a C-style for loop body to avoid recursion
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
            if (std.mem.eql(u8, cmd.name, "jobs")) {
                self.last_exit_code = try self.job_manager.builtinJobs(cmd.args);
                return;
            } else if (std.mem.eql(u8, cmd.name, "fg")) {
                self.last_exit_code = try self.job_manager.builtinFg(cmd.args);
                return;
            } else if (std.mem.eql(u8, cmd.name, "bg")) {
                self.last_exit_code = try self.job_manager.builtinBg(cmd.args);
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
            } else if (std.mem.eql(u8, cmd.name, "test") or std.mem.eql(u8, cmd.name, "[") or std.mem.eql(u8, cmd.name, "[[")) {
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
            } else if (std.mem.eql(u8, cmd.name, "typeset")) {
                try self.builtinTypeset(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "let")) {
                try self.builtinLet(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "shopt")) {
                try self.builtinShopt(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "mapfile") or std.mem.eql(u8, cmd.name, "readarray")) {
                try self.builtinMapfile(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "caller")) {
                try self.builtinCaller(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "compgen")) {
                try self.builtinCompgen(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "enable")) {
                try self.builtinEnable(cmd);
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

    /// Try fast path for simple commands.
    /// Returns exit code if handled, null to fall back to full parser.
    fn tryFastPath(self: *Shell, input: []const u8) ?i32 {
        // Quick check: use OptimizedParser's simple command check
        if (!parser_mod.OptimizedParser.isSimpleCommand(input)) {
            return null;
        }

        // Additional checks for features that require full parser
        for (input) |c| {
            switch (c) {
                // Variable expansion
                '$' => return null,
                // Command substitution
                '`' => return null,
                // Process substitution, grouping
                '(' => return null,
                ')' => return null,
                // Glob patterns
                '*' => return null,
                '?' => return null,
                '[' => return null,
                // Brace expansion
                '{' => return null,
                '}' => return null,
                // Escape sequences
                '\\' => return null,
                else => {},
            }
        }

        // Parse with optimized parser
        var opt_parser = parser_mod.OptimizedParser.init(self.allocator, input);
        const simple_cmd = opt_parser.parseSimpleCommand() catch return null;
        if (simple_cmd == null) return null;
        const cmd = simple_cmd.?;

        // Skip empty commands
        if (cmd.name.len == 0) return null;

        // Check if this is an alias - fall back to full parser for alias expansion
        if (self.aliases.contains(cmd.name)) {
            return null;
        }

        // Check if this is a function - fall back to full parser for function calls
        if (self.function_manager.hasFunction(cmd.name)) {
            return null;
        }

        // Handle trivial builtins directly (no I/O, no state changes except exit)
        if (std.mem.eql(u8, cmd.name, "true")) {
            return 0;
        }

        if (std.mem.eql(u8, cmd.name, "false")) {
            return 1;
        }

        if (std.mem.eql(u8, cmd.name, ":")) {
            // Bash no-op command
            return 0;
        }

        if (std.mem.eql(u8, cmd.name, "exit")) {
            const args = cmd.getArgs();
            if (args.len > 0) {
                self.last_exit_code = std.fmt.parseInt(i32, args[0], 10) catch 0;
            }
            self.running = false;
            return self.last_exit_code;
        }

        // For all other commands (cd, echo, externals, etc.)
        // fall back to full parser to ensure correct handling
        return null;
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
                defer tokenizer.deinitTokens(tokens);

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
            try self.job_manager.add(pid, original_input);
        }
    }

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
        const pid_for_expansion: i32 = if (@import("builtin").os.tag == .windows)
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

    /// Builtin: history - show command history
    fn builtinHistory(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinHistory(self, cmd);
    }

    /// Builtin: complete - manage programmable completions
    fn builtinComplete(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinComplete(self, cmd);
    }

    /// Show completions in legacy mode (for a prefix)
    fn showLegacyCompletions(self: *Shell, completion: *Completion, prefix: []const u8) !void {
        try shell_mod.showLegacyCompletions(self, completion, prefix);
    }

    /// Expand aliases in command chain with circular reference detection
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

                // Check if first word is also an alias
                current_name = first_word;
            }
        }
    }

    /// Builtin: alias - define or list aliases
    /// Supports -s flag for suffix aliases (zsh-style): alias -s ts='bun'
    fn builtinAlias(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinAlias(self, cmd);
    }

    /// Builtin: unalias - remove alias
    /// Supports -s flag for suffix aliases: unalias -s ts
    fn builtinUnalias(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinUnalias(self, cmd);
    }

    /// Builtin: type - identify command type
    fn builtinType(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinType(self, cmd);
    }

    /// Builtin: which - locate command in PATH
    fn builtinWhich(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinWhich(self, cmd);
    }

    /// Builtin: source - execute commands from file
    fn builtinSource(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinSource(self, cmd);
    }

    /// Builtin: read - read line from stdin into variable
    fn builtinRead(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinRead(self, cmd);
    }

    /// Builtin: test/[ - evaluate conditional expressions
    fn builtinTest(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinTest(self, cmd);
    }

    /// Builtin: pushd - push directory onto stack and cd
    fn builtinPushd(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinPushd(self, cmd);
    }

    /// Helper to rotate directory stack
    fn rotateDirStack(self: *Shell, index: usize) !void {
        try shell_mod.rotateDirStack(self, index);
    }

    /// Helper to print directory stack
    fn printDirStack(self: *Shell) !void {
        try shell_mod.printDirStack(self);
    }

    /// Builtin: popd - pop directory from stack and cd
    fn builtinPopd(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinPopd(self, cmd);
    }

    /// Builtin: dirs - show directory stack
    fn builtinDirs(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinDirs(self, cmd);
    }

    /// Builtin: printf - formatted output with full format string support
    fn builtinPrintf(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinPrintf(self, cmd);
    }

    /// Builtin: sleep - pause for specified seconds
    fn builtinSleep(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinSleep(self, cmd);
    }

    /// Builtin: help - show available builtins
    fn builtinHelp(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinHelp(self, cmd);
    }

    /// Builtin: basename - extract filename from path
    fn builtinBasename(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinBasename(self, cmd);
    }

    /// Builtin: dirname - extract directory from path
    fn builtinDirname(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinDirname(self, cmd);
    }

    /// Builtin: realpath - resolve absolute path
    fn builtinRealpath(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinRealpath(self, cmd);
    }

    /// Builtin: command - run command bypassing aliases/builtins
    fn builtinCommand(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinCommand(self, cmd);
    }

    /// Builtin: eval - execute arguments as shell command
    fn builtinEval(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinEval(self, cmd);
    }

    /// Builtin: shift - shift positional parameters
    fn builtinShift(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinShift(self, cmd);
    }

    /// Builtin: time - time command execution
    fn builtinTime(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinTime(self, cmd);
    }

    /// Builtin: umask - set file creation mask
    fn builtinUmask(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinUmask(self, cmd);
    }

    /// Builtin: clear - clear the terminal screen
    fn builtinClear(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinClear(self, cmd);
    }

    /// Builtin: uname - print system information
    fn builtinUname(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinUname(self, cmd);
    }

    /// Builtin: whoami - print current username
    fn builtinWhoami(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinWhoami(self, cmd);
    }

    /// Builtin: hash - remember/display command paths (simplified)
    fn builtinHash(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinHash(self, cmd);
    }

    /// Builtin: return - return from function or script
    fn builtinReturn(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinReturn(self, cmd);
    }

    /// Builtin: break - exit from loop
    /// Supports `break N` to break out of N nested loops
    fn builtinBreak(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinBreak(self, cmd);
    }

    /// Builtin: continue - skip to next loop iteration
    /// Supports `continue N` to continue the Nth enclosing loop
    fn builtinContinue(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinContinue(self, cmd);
    }

    /// Builtin: local - declare local variables (function scope)
    fn builtinLocal(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinLocal(self, cmd);
    }

    /// Builtin: declare/typeset - declare variables with attributes
    fn builtinDeclare(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinDeclare(self, cmd);
    }

    /// Helper to set variable attributes
    fn setVarAttributes(self: *Shell, name: []const u8, attrs: types.VarAttributes, remove: bool) !void {
        try shell_mod.setVarAttributes(self, name, attrs, remove);
    }

    /// Builtin: readonly - declare readonly variables
    fn builtinReadonly(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinReadonly(self, cmd);
    }

    /// Builtin: typeset - alias for declare (bash compatibility)
    fn builtinTypeset(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinTypeset(self, cmd);
    }

    /// Builtin: let - evaluate arithmetic expressions
    fn builtinLet(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinLet(self, cmd);
    }

    /// Builtin: shopt - shell options
    fn builtinShopt(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinShopt(self, cmd);
    }

    /// Builtin: mapfile/readarray - read lines into array
    fn builtinMapfile(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinMapfile(self, cmd);
    }

    /// Builtin: caller - display call stack
    fn builtinCaller(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinCaller(self, cmd);
    }

    /// Builtin: compgen - generate completions
    fn builtinCompgen(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinCompgen(self, cmd);
    }

    /// enable builtin - load/unload loadable builtins from shared libraries
    /// Usage:
    ///   enable              - list all loadable builtins
    ///   enable -a           - list all builtins (built-in and loadable)
    ///   enable -f file name - load a builtin from shared library
    ///   enable -d name      - delete (unload) a loadable builtin
    ///   enable -n name      - disable a loadable builtin
    ///   enable name         - enable a loadable builtin
    fn builtinEnable(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinEnable(self, cmd);
    }

    /// Execute a one-line C-style for loop: for ((init; cond; update)); do cmd1; cmd2; done
    fn executeCStyleForLoopOneline(self: *Shell, input: []const u8) !void {
        try shell_mod.executeCStyleForLoopOneline(self, input);
    }

    /// Execute a command in the body of a C-style for loop
    fn executeCStyleLoopBodyCommand(self: *Shell, cmd: []const u8) void {
        shell_mod.executeCStyleLoopBodyCommand(self, cmd);
    }

    /// Execute input that contains a C-style for loop with commands before and/or after
    fn executeWithCStyleForLoop(self: *Shell, input: []const u8) !void {
        try shell_mod.executeWithCStyleForLoop(self, input);
    }

    /// Execute a select loop: select VAR in ITEM1 ITEM2 ...; do BODY; done
    fn executeSelectLoop(self: *Shell, input: []const u8) !void {
        try shell_mod.executeSelectLoop(self, input);
    }

    /// Execute select loop body command (non-recursive helper)
    fn executeSelectBody(self: *Shell, body: []const u8) void {
        shell_mod.executeSelectBody(self, body);
    }

    /// Execute arithmetic statement (like i=0 or i++)
    fn executeArithmeticStatement(self: *Shell, stmt: []const u8) void {
        shell_mod.executeArithmeticStatement(self, stmt);
    }

    /// Set a variable for arithmetic operations
    fn setArithVariable(self: *Shell, name: []const u8, value: []const u8) void {
        shell_mod.setArithVariable(self, name, value);
    }

    /// Evaluate arithmetic condition (returns true if non-zero)
    fn evaluateArithmeticCondition(self: *Shell, cond: []const u8) bool {
        return shell_mod.evaluateArithmeticCondition(self, cond);
    }

    /// Evaluate arithmetic expression
    fn evaluateArithmeticExpr(self: *Shell, expr: []const u8) i64 {
        return shell_mod.evaluateArithmeticExpr(self, expr);
    }

    /// Get variable value (helper for arithmetic)
    fn getVariableValueForArith(self: *Shell, name: []const u8) []const u8 {
        return shell_mod.getVariableValueForArith(self, name);
    }

    /// Resolve nameref: follow nameref chain to get the actual variable name
    /// Returns the final variable name after following any nameref references
    /// Max depth of 10 to prevent infinite loops
    pub fn resolveNameref(self: *Shell, name: []const u8) []const u8 {
        var current_name = name;
        var depth: u32 = 0;
        const max_depth = 10;

        while (depth < max_depth) : (depth += 1) {
            if (self.var_attributes.get(current_name)) |attrs| {
                if (attrs.nameref) {
                    // This is a nameref, its value is the name of the referenced variable
                    if (self.environment.get(current_name)) |ref_name| {
                        current_name = ref_name;
                        continue;
                    }
                }
            }
            // Not a nameref or no more references to follow
            break;
        }
        return current_name;
    }

    /// Get variable value following namerefs
    pub fn getVariableValue(self: *Shell, name: []const u8) ?[]const u8 {
        const resolved_name = self.resolveNameref(name);
        return self.environment.get(resolved_name);
    }

    /// Set variable value following namerefs
    pub fn setVariableValue(self: *Shell, name: []const u8, value: []const u8) !void {
        const resolved_name = self.resolveNameref(name);

        // Check if readonly
        if (self.var_attributes.get(resolved_name)) |attrs| {
            if (attrs.readonly) {
                try IO.eprint("den: {s}: readonly variable\n", .{resolved_name});
                return error.ReadonlyVariable;
            }
        }

        // Set the value
        const gop = try self.environment.getOrPut(resolved_name);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, resolved_name);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, value);
    }

    /// Check if input is an array assignment: name=(value1 value2 ...)
    fn isArrayAssignment(input: []const u8) bool {
        // Look for pattern: name=(...)
        const eq_pos = std.mem.indexOfScalar(u8, input, '=') orelse return false;
        if (eq_pos >= input.len - 1) return false;
        if (input[eq_pos + 1] != '(') return false;

        // Check for closing paren
        return std.mem.indexOfScalar(u8, input[eq_pos + 2 ..], ')') != null;
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
        const content = std.mem.trim(u8, input[start_paren + 1 .. end_paren], &std.ascii.whitespace);

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
        try shell_mod.builtinExec(self, cmd);
    }

    /// Builtin: wait - wait for job completion
    fn builtinWait(self: *Shell, cmd: *types.ParsedCommand) !void {
        self.last_exit_code = try self.job_manager.builtinWait(cmd.args);
    }

    /// Builtin: kill - send signal to job or process
    fn builtinKill(self: *Shell, cmd: *types.ParsedCommand) !void {
        try shell_mod.builtinKill(self, cmd);
    }

    /// Builtin: disown - remove jobs from job table
    fn builtinDisown(self: *Shell, cmd: *types.ParsedCommand) !void {
        self.last_exit_code = try self.job_manager.builtinDisown(cmd.args);
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
        try shell_mod.builtinBuiltin(self, cmd);
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

    // Version detection methods - delegate to shell/version.zig module
    fn detectPackageVersion(self: *Shell, cwd: []const u8) ![]const u8 {
        return shell_mod.detectPackageVersion(self.allocator, cwd);
    }

    fn detectBunVersion(self: *Shell) ![]const u8 {
        return shell_mod.detectBunVersion(self.allocator);
    }

    fn detectNodeVersion(self: *Shell) ![]const u8 {
        return shell_mod.detectNodeVersion(self.allocator);
    }

    fn detectPythonVersion(self: *Shell) ![]const u8 {
        return shell_mod.detectPythonVersion(self.allocator);
    }

    fn detectRubyVersion(self: *Shell) ![]const u8 {
        return shell_mod.detectRubyVersion(self.allocator);
    }

    fn detectGoVersion(self: *Shell) ![]const u8 {
        return shell_mod.detectGoVersion(self.allocator);
    }

    fn detectRustVersion(self: *Shell) ![]const u8 {
        return shell_mod.detectRustVersion(self.allocator);
    }

    fn detectZigVersion(self: *Shell) ![]const u8 {
        return shell_mod.detectZigVersion(self.allocator);
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
        "add",  "bisect", "branch", "checkout", "cherry-pick", "clone",  "commit",
        "diff", "fetch",  "grep",   "init",     "log",         "merge",  "mv",
        "pull", "push",   "rebase", "reset",    "restore",     "revert", "rm",
        "show", "stash",  "status", "switch",   "tag",
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
        "add",     "bun", "create", "dev", "help",
        "install", "pm",  "remove", "run", "upgrade",
        "x",
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
        "install",  "i",      "add",       "run",    "test",  "start",   "build",
        "init",     "update", "uninstall", "remove", "rm",    "publish", "version",
        "outdated", "ls",     "link",      "unlink", "cache", "audit",   "fund",
        "doctor",   "exec",   "ci",        "prune",
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
        "add",       "audit",        "autoclean", "bin",                 "cache",   "config",
        "create",    "dedupe",       "dlx",       "exec",                "explain", "info",
        "init",      "install",      "link",      "node",                "npm",     "pack",
        "patch",     "patch-commit", "plugin",    "rebuild",             "remove",  "run",
        "search",    "set",          "stage",     "start",               "test",    "unlink",
        "unplug",    "up",           "upgrade",   "upgrade-interactive", "version", "why",
        "workspace", "workspaces",
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
        "add",     "audit",        "bin",    "config",  "create",   "dedupe",
        "dlx",     "env",          "exec",   "fetch",   "import",   "init",
        "install", "install-test", "link",   "list",    "outdated", "pack",
        "patch",   "patch-commit", "prune",  "publish", "rebuild",  "recursive",
        "remove",  "root",         "run",    "server",  "setup",    "start",
        "store",   "test",         "unlink", "update",  "why",
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
        "attach", "build",   "commit", "compose", "container", "cp",
        "create", "diff",    "events", "exec",    "export",    "history",
        "image",  "images",  "import", "info",    "inspect",   "kill",
        "load",   "login",   "logout", "logs",    "network",   "node",
        "pause",  "plugin",  "port",   "ps",      "pull",      "push",
        "rename", "restart", "rm",     "rmi",     "run",       "save",
        "search", "service", "stack",  "start",   "stats",     "stop",
        "swarm",  "system",  "tag",    "top",     "trust",     "unpause",
        "update", "version", "volume", "wait",
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
