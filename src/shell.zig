const std = @import("std");
const types = @import("types/mod.zig");
const parser_mod = @import("parser/mod.zig");
const executor_mod = @import("executor/mod.zig");
const IO = @import("utils/io.zig").IO;

fn getEnvOwned(allocator: std.mem.Allocator, key: [*:0]const u8) ?[]u8 {
    const raw = std.c.getenv(key) orelse return null;
    const value = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    return allocator.dupe(u8, value) catch null;
}

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

        // Initialize environment from system - inherit all parent environment variables
        var env = std.StringHashMap([]const u8).init(allocator);

        // Inherit all environment variables from parent process
        {
            const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
            var i: usize = 0;
            while (c_environ.*[i]) |entry| : (i += 1) {
                const entry_str = std.mem.span(@as([*:0]const u8, @ptrCast(entry)));
                if (std.mem.indexOfScalar(u8, entry_str, '=')) |eq_pos| {
                    const key = try allocator.dupe(u8, entry_str[0..eq_pos]);
                    const val = try allocator.dupe(u8, entry_str[eq_pos + 1 ..]);
                    try env.put(key, val);
                }
            }
        }

        // Ensure critical variables have fallback values
        const home = if (env.get("HOME")) |h|
            try allocator.dupe(u8, h)
        else blk: {
            const fallback = getEnvOwned(allocator, "USERPROFILE") orelse
                try allocator.dupe(u8, "/");
            const home_key = try allocator.dupe(u8, "HOME");
            try env.put(home_key, try allocator.dupe(u8, fallback));
            break :blk fallback;
        };
        defer allocator.free(home);

        if (!env.contains("PATH")) {
            const path_key = try allocator.dupe(u8, "PATH");
            const path_val = try allocator.dupe(u8, "/usr/bin:/bin");
            try env.put(path_key, path_val);
        }

        // Load default environment variables from config
        if (config.environment.enabled) {
            // First, set defaults (only if not already in environment)
            for (types.EnvironmentConfig.defaults) |default_var| {
                if (!env.contains(default_var.name)) {
                    const key_copy = try allocator.dupe(u8, default_var.name);
                    const value_copy = try allocator.dupe(u8, default_var.value);
                    try env.put(key_copy, value_copy);
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
        var history_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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
            shell.is_interactive = (std.Io.File{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } }).isTty(std.Options.debug_io) catch false;
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

        // Fire EXIT trap before leaving
        self.executeExitTrap();
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
        // Preprocess heredocs: convert <<DELIM\ncontent\nDELIM to herestring
        if (std.mem.indexOf(u8, input, "<<") != null and std.mem.indexOfScalar(u8, input, '\n') != null) {
            if (self.preprocessHeredoc(input)) |rewritten| {
                defer self.allocator.free(rewritten);
                return self.executeCommand(rewritten);
            }
        }

        // Split on unquoted semicolons and execute each part separately.
        // This ensures variables set by earlier parts are visible to later parts.
        if (self.splitAndExecuteSemicolons(input)) return;

        // Handle ! negation prefix (negate exit code)
        const neg_trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, neg_trimmed, "! ")) {
            const inner = std.mem.trim(u8, neg_trimmed[2..], &std.ascii.whitespace);
            if (inner.len > 0) {
                self.executeCommand(inner) catch {};
                self.last_exit_code = if (self.last_exit_code == 0) @as(i32, 1) else @as(i32, 0);
                return;
            }
        }

        // Check for function definition (name() { ... } or function name { ... })
        const fn_trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (try self.checkFunctionDefinitionStart(fn_trimmed)) {
            self.last_exit_code = 0;
            return;
        }

        // Check for arithmetic command: (( expression ))
        if (fn_trimmed.len > 4 and std.mem.startsWith(u8, fn_trimmed, "((") and std.mem.endsWith(u8, fn_trimmed, "))")) {
            const expr = std.mem.trim(u8, fn_trimmed[2 .. fn_trimmed.len - 2], &std.ascii.whitespace);
            if (expr.len > 0) {
                // Handle post-increment: (( x++ ))
                if (std.mem.endsWith(u8, expr, "++")) {
                    const var_name = std.mem.trim(u8, expr[0 .. expr.len - 2], &std.ascii.whitespace);
                    if (var_name.len > 0) {
                        const current = shell_mod.getVariableValue(self, var_name) orelse "0";
                        const num = std.fmt.parseInt(i64, current, 10) catch 0;
                        var buf: [32]u8 = undefined;
                        const new_val = std.fmt.bufPrint(&buf, "{d}", .{num + 1}) catch "0";
                        shell_mod.setArithVariable(self, var_name, new_val);
                        self.last_exit_code = if (num != 0) @as(i32, 0) else @as(i32, 1);
                        return;
                    }
                }
                // Handle post-decrement: (( x-- ))
                if (std.mem.endsWith(u8, expr, "--")) {
                    const var_name = std.mem.trim(u8, expr[0 .. expr.len - 2], &std.ascii.whitespace);
                    if (var_name.len > 0) {
                        const current = shell_mod.getVariableValue(self, var_name) orelse "0";
                        const num = std.fmt.parseInt(i64, current, 10) catch 0;
                        var buf: [32]u8 = undefined;
                        const new_val = std.fmt.bufPrint(&buf, "{d}", .{num - 1}) catch "0";
                        shell_mod.setArithVariable(self, var_name, new_val);
                        self.last_exit_code = if (num != 0) @as(i32, 0) else @as(i32, 1);
                        return;
                    }
                }
                // Handle pre-increment: (( ++x ))
                if (std.mem.startsWith(u8, expr, "++")) {
                    const var_name = std.mem.trim(u8, expr[2..], &std.ascii.whitespace);
                    if (var_name.len > 0) {
                        const current = shell_mod.getVariableValue(self, var_name) orelse "0";
                        const num = std.fmt.parseInt(i64, current, 10) catch 0;
                        const new_num = num + 1;
                        var buf: [32]u8 = undefined;
                        const new_val = std.fmt.bufPrint(&buf, "{d}", .{new_num}) catch "0";
                        shell_mod.setArithVariable(self, var_name, new_val);
                        self.last_exit_code = if (new_num != 0) @as(i32, 0) else @as(i32, 1);
                        return;
                    }
                }
                // Handle pre-decrement: (( --x ))
                if (std.mem.startsWith(u8, expr, "--")) {
                    const var_name = std.mem.trim(u8, expr[2..], &std.ascii.whitespace);
                    if (var_name.len > 0) {
                        const current = shell_mod.getVariableValue(self, var_name) orelse "0";
                        const num = std.fmt.parseInt(i64, current, 10) catch 0;
                        const new_num = num - 1;
                        var buf: [32]u8 = undefined;
                        const new_val = std.fmt.bufPrint(&buf, "{d}", .{new_num}) catch "0";
                        shell_mod.setArithVariable(self, var_name, new_val);
                        self.last_exit_code = if (new_num != 0) @as(i32, 0) else @as(i32, 1);
                        return;
                    }
                }
                // Handle assignment: (( x = expr ))
                if (std.mem.indexOf(u8, expr, "=")) |eq_idx| {
                    // Make sure it's not == or != or <= or >=
                    const is_comparison = (eq_idx > 0 and (expr[eq_idx - 1] == '!' or expr[eq_idx - 1] == '<' or expr[eq_idx - 1] == '>')) or
                        (eq_idx + 1 < expr.len and expr[eq_idx + 1] == '=');
                    if (!is_comparison) {
                        const var_name = std.mem.trim(u8, expr[0..eq_idx], &std.ascii.whitespace);
                        const value_expr = std.mem.trim(u8, expr[eq_idx + 1 ..], &std.ascii.whitespace);
                        // Evaluate the right side
                        var arith = @import("utils/arithmetic.zig").Arithmetic.initWithVariables(self.allocator, &self.environment);
                        const result = arith.eval(value_expr) catch 0;
                        var buf: [32]u8 = undefined;
                        const val_str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch "0";
                        shell_mod.setArithVariable(self, var_name, val_str);
                        self.last_exit_code = 0;
                        return;
                    }
                }
                // Non-assignment: evaluate and set exit code based on result
                var arith = @import("utils/arithmetic.zig").Arithmetic.initWithVariables(self.allocator, &self.environment);
                const result = arith.eval(expr) catch 0;
                self.last_exit_code = if (result != 0) @as(i32, 0) else @as(i32, 1);
                return;
            }
        }

        // Check for compound command group: { command; }
        if (fn_trimmed.len > 2 and fn_trimmed[0] == '{' and fn_trimmed[fn_trimmed.len - 1] == '}') {
            // Must have space after { (bash requirement)
            if (fn_trimmed.len > 1 and (fn_trimmed[1] == ' ' or fn_trimmed[1] == '\t' or fn_trimmed[1] == '\n')) {
                const inner = std.mem.trim(u8, fn_trimmed[1 .. fn_trimmed.len - 1], &std.ascii.whitespace);
                if (inner.len > 0) {
                    // Execute in current shell context (no fork)
                    self.executeCommand(inner) catch |err| {
                        if (err == error.Exit) return err;
                    };
                    return;
                }
            }
        }

        // Check for subshell: (command)
        if (fn_trimmed.len > 2 and fn_trimmed[0] == '(' and fn_trimmed[fn_trimmed.len - 1] == ')') {
            // Execute the inner command in a subshell (fork to isolate env changes)
            const inner = std.mem.trim(u8, fn_trimmed[1 .. fn_trimmed.len - 1], &std.ascii.whitespace);
            if (inner.len > 0) {
                const fork_ret = std.c.fork();
                if (fork_ret < 0) {
                    try IO.eprint("den: fork failed\n", .{});
                    self.last_exit_code = 1;
                    return;
                }
                if (fork_ret == 0) {
                    // Child: execute command and exit
                    self.executeCommand(inner) catch {
                        std.c._exit(1);
                    };
                    std.c._exit(@as(u8, @intCast(@as(u32, @bitCast(self.last_exit_code)) & 0xff)));
                }
                // Parent: wait for child
                var wait_status: c_int = 0;
                _ = std.c.waitpid(@intCast(fork_ret), &wait_status, 0);
                if (wait_status & 0x7f == 0) {
                    // Exited normally
                    self.last_exit_code = @as(i32, @intCast((wait_status >> 8) & 0xff));
                } else {
                    self.last_exit_code = 128 + @as(i32, @intCast(wait_status & 0x7f));
                }
                return;
            }
        }

        // Check for array assignment first
        if (shell_mod.isArrayAssignment(input)) {
            try shell_mod.executeArrayAssignment(self, input);
            return;
        }

        // Check for simple variable assignment: VAR=value or VAR+=value (no spaces before =)
        // This handles both regular assignments and nameref assignments
        const trimmed_input = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (std.mem.indexOf(u8, trimmed_input, "=")) |eq_pos| {
            // Check for += append operator
            const is_append = eq_pos > 0 and trimmed_input[eq_pos - 1] == '+';
            const var_end = if (is_append) eq_pos - 1 else eq_pos;
            // Check if this is a simple assignment (no spaces before =, valid var name)
            const potential_var = trimmed_input[0..var_end];
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
                        const raw_value = trimmed_input[eq_pos + 1 ..];
                        // If value contains expansion characters ($, `), let the full
                        // pipeline handle it so command substitution works correctly.
                        var needs_full_pipeline = false;
                        for (raw_value) |ch| {
                            if (ch == '$' or ch == '`') {
                                needs_full_pipeline = true;
                                break;
                            }
                        }
                        if (!needs_full_pipeline) {
                            // Check if readonly before assignment
                            if (self.var_attributes.get(potential_var)) |attrs| {
                                if (attrs.readonly) {
                                    try IO.eprint("den: {s}: readonly variable\n", .{potential_var});
                                    self.last_exit_code = 1;
                                    return;
                                }
                            }
                            // Simple literal assignment - strip surrounding quotes
                            const stripped = if (raw_value.len >= 2 and
                                ((raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') or
                                (raw_value[0] == '\'' and raw_value[raw_value.len - 1] == '\'')))
                                raw_value[1 .. raw_value.len - 1]
                            else
                                raw_value;
                            if (is_append) {
                                // += append: get existing value and concatenate
                                const existing = shell_mod.getVariableValue(self, potential_var) orelse "";
                                const combined = self.allocator.alloc(u8, existing.len + stripped.len) catch {
                                    shell_mod.setArithVariable(self, potential_var, stripped);
                                    self.last_exit_code = 0;
                                    return;
                                };
                                @memcpy(combined[0..existing.len], existing);
                                @memcpy(combined[existing.len..], stripped);
                                shell_mod.setArithVariable(self, potential_var, combined);
                            } else {
                                shell_mod.setArithVariable(self, potential_var, stripped);
                            }
                            self.last_exit_code = 0;
                            return;
                        }
                        // Fall through to full pipeline for expansion
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

        // Check for one-liner control flow: for/while/until/if/case
        if (std.mem.startsWith(u8, trimmed_input, "for ") or
            std.mem.startsWith(u8, trimmed_input, "while ") or
            std.mem.startsWith(u8, trimmed_input, "until ") or
            std.mem.startsWith(u8, trimmed_input, "if ") or
            std.mem.startsWith(u8, trimmed_input, "case "))
        {
            self.executeControlFlowOneliner(trimmed_input) catch |err| {
                try IO.eprint("den: control flow error: {}\n", .{err});
                self.last_exit_code = 1;
            };
            return;
        }

        // Check for pipeline into control flow: cmd | while/for/if/until/case ...
        // The parser can't handle this because it splits on semicolons inside while/for/etc.
        // We handle it here by manually setting up the pipe and executing both sides.
        if (std.mem.indexOf(u8, trimmed_input, "|") != null) {
            if (self.handlePipeToControlFlow(trimmed_input)) return;
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
        // Skip direct dispatch if there are redirections - let the executor handle them
        if (chain.commands.len == 1 and chain.operators.len == 0) {
            const cmd = &chain.commands[0];
            if (cmd.redirections.len == 0) {
                if (try shell_mod.dispatchBuiltin(self, cmd) == .handled) {
                    return;
                }
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

    pub fn executeExitTrap(self: *Shell) void {
        shell_mod.executeExitTrap(self);
    }

    /// Preprocess heredoc: convert multi-line heredoc to herestring.
    /// Input like "cat <<EOF\nhello\nworld\nEOF" becomes "cat <<< 'hello\nworld'"
    /// Returns null if no heredoc found or processing fails.
    fn preprocessHeredoc(self: *Shell, input: []const u8) ?[]const u8 {
        // Find << that's not <<< (herestring)
        var search_pos: usize = 0;
        const heredoc_pos = while (search_pos < input.len) {
            const pos = std.mem.indexOf(u8, input[search_pos..], "<<") orelse break null;
            const abs_pos = search_pos + pos;
            // Skip <<< (herestring)
            if (abs_pos + 2 < input.len and input[abs_pos + 2] == '<') {
                search_pos = abs_pos + 3;
                continue;
            }
            break abs_pos;
        } else null;

        const hd_pos = heredoc_pos orelse return null;

        // Check for <<- (strip tabs variant)
        var after_op = hd_pos + 2;
        var strip_tabs = false;
        if (after_op < input.len and input[after_op] == '-') {
            strip_tabs = true;
            after_op += 1;
        }

        // Skip whitespace after <<
        while (after_op < input.len and (input[after_op] == ' ' or input[after_op] == '\t')) {
            after_op += 1;
        }

        if (after_op >= input.len) return null;

        // Extract delimiter (handle quoted: 'EOF', "EOF", \EOF, or plain EOF)
        var delim_start = after_op;
        var delim_end = after_op;
        var quoted = false;

        if (input[delim_start] == '\'' or input[delim_start] == '"') {
            const quote_char = input[delim_start];
            delim_start += 1;
            delim_end = delim_start;
            while (delim_end < input.len and input[delim_end] != quote_char) {
                delim_end += 1;
            }
            quoted = true;
            after_op = if (delim_end < input.len) delim_end + 1 else delim_end;
        } else {
            while (delim_end < input.len and input[delim_end] != '\n' and
                input[delim_end] != ' ' and input[delim_end] != '\t')
            {
                delim_end += 1;
            }
            after_op = delim_end;
        }

        const delimiter = input[delim_start..delim_end];
        if (delimiter.len == 0) return null;

        // Find the first newline after the heredoc operator (start of content)
        const first_nl = std.mem.indexOfScalarPos(u8, input, after_op, '\n') orelse return null;
        const content_start = first_nl + 1;

        // Find the delimiter line in the remaining content
        var line_start = content_start;
        var content_end = content_start;
        var found_delim = false;

        while (line_start < input.len) {
            const line_end = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse input.len;
            var line = input[line_start..line_end];

            // Strip leading tabs if <<-
            if (strip_tabs) {
                while (line.len > 0 and line[0] == '\t') {
                    line = line[1..];
                }
            }

            if (std.mem.eql(u8, std.mem.trim(u8, line, &std.ascii.whitespace), delimiter)) {
                content_end = line_start;
                found_delim = true;
                break;
            }
            line_start = if (line_end < input.len) line_end + 1 else input.len;
        }

        if (!found_delim) return null;

        // Build the heredoc content (everything between command and delimiter)
        var heredoc_content = input[content_start..content_end];
        // Remove trailing newline if present
        if (heredoc_content.len > 0 and heredoc_content[heredoc_content.len - 1] == '\n') {
            heredoc_content = heredoc_content[0 .. heredoc_content.len - 1];
        }

        // Build the command part (everything before <<)
        const cmd_part = std.mem.trim(u8, input[0..hd_pos], &std.ascii.whitespace);

        if (quoted) {
            // Quoted heredoc: no expansion. Directly pipe the content.
            // Create pipe, fork writer, redirect stdin, then execute command.
            var pipe_fds: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&pipe_fds) != 0) return null;
            const read_fd = pipe_fds[0];
            const write_fd = pipe_fds[1];

            const fork_ret = std.c.fork();
            if (fork_ret < 0) {
                std.posix.close(read_fd);
                std.posix.close(write_fd);
                return null;
            }
            if (fork_ret == 0) {
                // Child: write content and exit
                std.posix.close(read_fd);
                const content_with_nl = std.fmt.allocPrint(self.allocator, "{s}\n", .{heredoc_content}) catch {
                    std.c._exit(1);
                    unreachable;
                };
                (std.Io.File{ .handle = write_fd, .flags = .{ .nonblocking = false } }).writeStreamingAll(std.Options.debug_io, content_with_nl) catch {};
                std.posix.close(write_fd);
                std.c._exit(0);
                unreachable;
            }

            // Parent: redirect stdin to read end of pipe
            std.posix.close(write_fd);
            const saved_stdin = std.c.dup(std.posix.STDIN_FILENO);
            if (std.c.dup2(read_fd, std.posix.STDIN_FILENO) < 0) {
                std.posix.close(read_fd);
                if (saved_stdin >= 0) std.posix.close(@intCast(saved_stdin));
                return null;
            }
            std.posix.close(read_fd);

            // Wait for writer to finish
            var wait_status: c_int = 0;
            _ = std.c.waitpid(@intCast(fork_ret), &wait_status, 0);

            // Execute the command with stdin redirected
            self.executeCommand(cmd_part) catch {};

            // Restore stdin
            if (saved_stdin >= 0) {
                _ = std.c.dup2(saved_stdin, std.posix.STDIN_FILENO);
                std.posix.close(@intCast(saved_stdin));
            }

            // Return empty string to signal we handled it (caller will free and return)
            return self.allocator.dupe(u8, "") catch null;
        } else {
            // Unquoted heredoc: allow expansion via herestring with double quotes
            const result = std.fmt.allocPrint(self.allocator, "{s} <<< \"{s}\"", .{
                cmd_part, heredoc_content,
            }) catch return null;
            return result;
        }
    }

    /// Execute a one-liner control flow statement (for/while/until/if/case).
    /// Converts semicolons to line breaks and feeds to the ControlFlowParser/Executor.
    fn executeControlFlowOneliner(self: *Shell, input: []const u8) !void {
        // Convert one-liner to multi-line by splitting on semicolons,
        // but respecting quotes, $() substitutions, and nested constructs.
        var lines_buf: [256][]const u8 = undefined;
        var line_count: usize = 0;
        var start: usize = 0;
        var in_single_quote = false;
        var in_double_quote = false;
        var paren_depth: u32 = 0;
        var i: usize = 0;

        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (c == '\\' and !in_single_quote and i + 1 < input.len) {
                i += 1;
                continue;
            }
            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
            } else if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
            } else if (!in_single_quote and !in_double_quote) {
                if (c == '(' and (paren_depth > 0 or (i > 0 and input[i - 1] == '$'))) {
                    paren_depth += 1;
                } else if (c == ')' and paren_depth > 0) {
                    paren_depth -= 1;
                } else if (c == ';' and paren_depth == 0) {
                    // Check for ;; (case terminator) - keep it with the preceding part
                    if (i + 1 < input.len and input[i + 1] == ';') {
                        // Include the ;; in the current part, split after it
                        const part = std.mem.trim(u8, input[start .. i + 2], &std.ascii.whitespace);
                        if (part.len > 0 and line_count < lines_buf.len) {
                            lines_buf[line_count] = part;
                            line_count += 1;
                        }
                        i += 1; // skip second ;
                        start = i + 1;
                    } else {
                        const part = std.mem.trim(u8, input[start..i], &std.ascii.whitespace);
                        if (part.len > 0 and line_count < lines_buf.len) {
                            lines_buf[line_count] = part;
                            line_count += 1;
                        }
                        start = i + 1;
                    }
                }
            }
        }
        // Last part
        const last_part = std.mem.trim(u8, input[start..], &std.ascii.whitespace);
        if (last_part.len > 0 and line_count < lines_buf.len) {
            lines_buf[line_count] = last_part;
            line_count += 1;
        }

        if (line_count == 0) return;

        // Post-process: split lines that start with "do ", "then ", "else "
        // into separate lines, since the parser expects these as standalone keywords.
        // Also handle "case ... in PATTERN)" by splitting after " in ".
        var expanded_buf: [512][]const u8 = undefined;
        var expanded_count: usize = 0;
        for (lines_buf[0..line_count]) |line| {
            if (expanded_count >= expanded_buf.len) break;
            // Handle "case VALUE in PATTERN)" - split after " in "
            if (std.mem.startsWith(u8, line, "case ")) {
                if (std.mem.indexOf(u8, line[5..], " in ")) |in_off| {
                    const in_pos = 5 + in_off;
                    // "case VALUE in" part
                    expanded_buf[expanded_count] = line[0 .. in_pos + 3]; // up to and including " in"
                    expanded_count += 1;
                    if (expanded_count < expanded_buf.len) {
                        const rest = std.mem.trim(u8, line[in_pos + 4 ..], &std.ascii.whitespace);
                        if (rest.len > 0) {
                            expanded_buf[expanded_count] = rest;
                            expanded_count += 1;
                        }
                    }
                    continue;
                }
            }
            const keywords = [_][]const u8{ "do ", "then ", "else " };
            var found_keyword = false;
            for (keywords) |kw| {
                if (std.mem.startsWith(u8, line, kw)) {
                    expanded_buf[expanded_count] = line[0 .. kw.len - 1]; // "do" or "then" or "else"
                    expanded_count += 1;
                    if (expanded_count < expanded_buf.len) {
                        const rest = std.mem.trim(u8, line[kw.len..], &std.ascii.whitespace);
                        if (rest.len > 0) {
                            expanded_buf[expanded_count] = rest;
                            expanded_count += 1;
                        }
                    }
                    found_keyword = true;
                    break;
                }
            }
            if (!found_keyword) {
                expanded_buf[expanded_count] = line;
                expanded_count += 1;
            }
        }

        const lines = expanded_buf[0..expanded_count];

        var cf_parser = ControlFlowParser.init(self.allocator);
        var cf_executor = ControlFlowExecutor.init(self);

        if (std.mem.startsWith(u8, input, "for ")) {
            const result = try cf_parser.parseFor(lines, 0);
            var loop = result.loop;
            defer loop.deinit();
            self.last_exit_code = try cf_executor.executeFor(&loop);
        } else if (std.mem.startsWith(u8, input, "while ")) {
            const result = try cf_parser.parseWhile(lines, 0, false);
            var loop = result.loop;
            defer loop.deinit();
            self.last_exit_code = try cf_executor.executeWhile(&loop);
        } else if (std.mem.startsWith(u8, input, "until ")) {
            const result = try cf_parser.parseWhile(lines, 0, true);
            var loop = result.loop;
            defer loop.deinit();
            self.last_exit_code = try cf_executor.executeWhile(&loop);
        } else if (std.mem.startsWith(u8, input, "if ")) {
            const result = try cf_parser.parseIf(lines, 0);
            var stmt = result.stmt;
            defer stmt.deinit();
            self.last_exit_code = try cf_executor.executeIf(&stmt);
        } else if (std.mem.startsWith(u8, input, "case ")) {
            const result = try cf_parser.parseCase(lines, 0);
            var stmt = result.stmt;
            defer stmt.deinit();
            self.last_exit_code = try cf_executor.executeCase(&stmt);
        }

        // Propagate break/continue from executor to shell so outer loops can see them
        if (cf_executor.break_levels > 0) {
            self.break_levels = cf_executor.break_levels;
        }
        if (cf_executor.continue_levels > 0) {
            self.continue_levels = cf_executor.continue_levels;
        }
    }

    /// Handle pipeline into control flow: cmd | while/for/if/until/case ...
    /// Returns true if the pattern was detected and handled, false otherwise.
    fn handlePipeToControlFlow(self: *Shell, input: []const u8) bool {
        // Find the last top-level pipe that leads into a control flow keyword
        var pipe_pos: ?usize = null;
        var in_sq = false;
        var in_dq = false;
        var paren_d: u32 = 0;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (c == '\\' and !in_sq and i + 1 < input.len) {
                i += 1;
                continue;
            }
            if (c == '\'' and !in_dq) {
                in_sq = !in_sq;
            } else if (c == '"' and !in_sq) {
                in_dq = !in_dq;
            } else if (!in_sq and !in_dq) {
                if (c == '(') paren_d += 1;
                if (c == ')' and paren_d > 0) paren_d -= 1;
                if (c == '|' and paren_d == 0 and (i + 1 >= input.len or input[i + 1] != '|')) {
                    // Single | (not ||)
                    pipe_pos = i;
                }
            }
        }

        const pp = pipe_pos orelse return false;
        if (pp + 1 >= input.len) return false;

        // Check if the part after the last pipe starts with a control flow keyword
        const right = std.mem.trim(u8, input[pp + 1 ..], &std.ascii.whitespace);
        const cf_keywords = [_][]const u8{ "while ", "for ", "until ", "if ", "case " };
        var is_cf = false;
        for (cf_keywords) |kw| {
            if (std.mem.startsWith(u8, right, kw)) {
                is_cf = true;
                break;
            }
        }
        if (!is_cf) return false;

        // Split: left side is everything before the last pipe, right side is control flow
        const left = std.mem.trim(u8, input[0..pp], &std.ascii.whitespace);
        if (left.len == 0) return false;

        // Set up a pipe, fork for the left side, execute right side with piped stdin
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return false;

        const fork_ret = std.c.fork();
        if (fork_ret < 0) {
            std.posix.close(fds[0]);
            std.posix.close(fds[1]);
            return false;
        }
        const pid: std.posix.pid_t = @intCast(fork_ret);

        if (pid == 0) {
            // Child: execute left side, stdout -> pipe write end
            std.posix.close(fds[0]);
            _ = std.c.dup2(fds[1], std.posix.STDOUT_FILENO);
            std.posix.close(fds[1]);
            self.executeCommand(left) catch {};
            std.c._exit(@intCast(if (self.last_exit_code >= 0) @as(u32, @intCast(self.last_exit_code)) else 1));
        }

        // Parent: execute right side (control flow) with stdin <- pipe read end
        std.posix.close(fds[1]);
        const saved_stdin = std.c.dup(std.posix.STDIN_FILENO);
        _ = std.c.dup2(fds[0], std.posix.STDIN_FILENO);
        std.posix.close(fds[0]);

        // Execute the control flow command
        self.executeCommand(right) catch {};

        // Restore stdin
        if (saved_stdin >= 0) {
            _ = std.c.dup2(saved_stdin, std.posix.STDIN_FILENO);
            std.posix.close(saved_stdin);
        }

        // Wait for child
        var wait_status: c_int = 0;
        _ = std.c.waitpid(pid, &wait_status, 0);

        return true;
    }

    /// Check if a word at position is a control flow opener keyword.
    /// The word must be at a word boundary (start of string or after whitespace/semicolon).
    fn isControlFlowOpener(input: []const u8, pos: usize) bool {
        const openers = [_][]const u8{ "for ", "while ", "until ", "if ", "case ", "select " };
        for (openers) |kw| {
            if (pos + kw.len <= input.len and std.mem.eql(u8, input[pos..][0..kw.len], kw)) {
                return true;
            }
        }
        return false;
    }

    /// Check if a word at position is a control flow closer keyword.
    fn isControlFlowCloser(input: []const u8, pos: usize) bool {
        const closers = [_]struct { word: []const u8, for_kw: []const u8 }{
            .{ .word = "done", .for_kw = "done" },
            .{ .word = "fi", .for_kw = "fi" },
            .{ .word = "esac", .for_kw = "esac" },
        };
        for (closers) |c| {
            const wlen = c.word.len;
            if (pos + wlen <= input.len and std.mem.eql(u8, input[pos..][0..wlen], c.word)) {
                // Must be at end of string or followed by whitespace/semicolon
                if (pos + wlen == input.len or
                    input[pos + wlen] == ' ' or input[pos + wlen] == ';' or
                    input[pos + wlen] == '\t' or input[pos + wlen] == '\n')
                {
                    return true;
                }
            }
        }
        return false;
    }

    /// Split input on unquoted semicolons and execute each part separately.
    /// Returns true if input was split and executed, false if no splitting needed.
    /// Tracks control flow depth so semicolons inside for/while/if/case constructs
    /// are NOT treated as split points.
    fn splitAndExecuteSemicolons(self: *Shell, input: []const u8) bool {
        // Quick check: if no semicolons, skip
        if (std.mem.indexOfScalar(u8, input, ';') == null) return false;

        // Find semicolons that are not inside quotes, $(), or control flow constructs
        var parts_buf: [64][]const u8 = undefined;
        var part_count: usize = 0;
        var start: usize = 0;
        var in_single_quote = false;
        var in_double_quote = false;
        var paren_depth: u32 = 0;
        var brace_depth: u32 = 0; // { } nesting depth (function bodies)
        var cf_depth: u32 = 0; // control flow nesting depth
        var i: usize = 0;
        var at_word_start = true; // track word boundaries for keyword detection

        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (c == '\\' and !in_single_quote and i + 1 < input.len) {
                i += 1; // skip escaped char
                at_word_start = false;
                continue;
            }
            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
                at_word_start = false;
            } else if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
                at_word_start = false;
            } else if (!in_single_quote and !in_double_quote) {
                if (c == '(') {
                    paren_depth += 1;
                    at_word_start = false;
                } else if (c == ')' and paren_depth > 0) {
                    paren_depth -= 1;
                    at_word_start = false;
                } else if (c == '{' and at_word_start) {
                    brace_depth += 1;
                    at_word_start = false;
                } else if (c == '}' and brace_depth > 0) {
                    brace_depth -= 1;
                    at_word_start = false;
                } else if (paren_depth == 0) {
                    // Track control flow nesting at word boundaries
                    if (at_word_start and isControlFlowOpener(input, i)) {
                        cf_depth += 1;
                        at_word_start = false;
                    } else if (at_word_start and cf_depth > 0 and isControlFlowCloser(input, i)) {
                        cf_depth -= 1;
                        at_word_start = false;
                    } else if (c == ';') {
                        // Skip double semicolons (;;) used in case statements
                        if (i + 1 < input.len and input[i + 1] == ';') {
                            i += 1;
                            at_word_start = true;
                            continue;
                        }
                        if (cf_depth == 0 and brace_depth == 0) {
                            const part = std.mem.trim(u8, input[start..i], &std.ascii.whitespace);
                            if (part.len > 0 and part_count < parts_buf.len) {
                                parts_buf[part_count] = part;
                                part_count += 1;
                            }
                            start = i + 1;
                        }
                        at_word_start = true;
                        continue;
                    } else if (c == ' ' or c == '\t' or c == '\n') {
                        at_word_start = true;
                        continue;
                    } else {
                        at_word_start = false;
                    }
                } else {
                    at_word_start = false;
                }
            } else {
                at_word_start = false;
            }
        }
        // Last part
        const last_part = std.mem.trim(u8, input[start..], &std.ascii.whitespace);
        if (last_part.len > 0 and part_count < parts_buf.len) {
            parts_buf[part_count] = last_part;
            part_count += 1;
        }

        // If we only have 1 part but the input had semicolons (trailing semicolons),
        // still handle it so it doesn't fall through to the parser with a dangling ';'
        if (part_count == 0) return false;
        if (part_count == 1) {
            // Only handle if the part is different from the original input
            // (i.e., we actually stripped a trailing semicolon).
            // If the part IS the full input, semicolons were inside control flow/quotes
            // and we must return false to avoid infinite recursion.
            const trimmed_orig = std.mem.trim(u8, input, &std.ascii.whitespace);
            if (std.mem.eql(u8, parts_buf[0], trimmed_orig)) return false;
            self.executeCommand(parts_buf[0]) catch {};
            return true;
        }

        // Execute each part separately
        for (parts_buf[0..part_count]) |part| {
            self.executeCommand(part) catch {};
            // Honor set -e (errexit): stop if a command fails
            if (self.option_errexit and self.last_exit_code != 0) break;
        }
        return true;
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
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Options.debug_io, &cwd_buf) catch 0;
    const cwd = if (cwd_len > 0) cwd_buf[0..cwd_len] else "/";

    // Get home directory to abbreviate with ~
    const home = getenv("HOME");

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
