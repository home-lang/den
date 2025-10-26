# Den Shell Algorithms

This document describes the key algorithms implemented in Den Shell, including parsing, expansion, glob matching, and execution strategies.

## Table of Contents

1. [Parsing Algorithms](#parsing-algorithms)
2. [Expansion Algorithms](#expansion-algorithms)
3. [Glob Matching](#glob-matching)
4. [Execution Algorithms](#execution-algorithms)
5. [Completion Algorithms](#completion-algorithms)
6. [Performance Optimizations](#performance-optimizations)

## Parsing Algorithms

### Tokenization (src/parser/tokenizer.zig)

**Algorithm**: Single-pass lexical analysis with lookahead

**Time Complexity**: O(n) where n is input length

**Process**:
```
Input: "echo 'hello world' | grep pattern"

1. Start at position 0
2. Skip whitespace
3. Read character:
   - Letter/digit → Read word until delimiter
   - Quote → Read quoted string
   - Operator char → Check for multi-char operators
   - Special → Single character token
4. Create token with type and position
5. Advance position
6. Repeat until EOF
```

**Output**: Token stream
```zig
[
    Token{ .type = .word, .value = "echo" },
    Token{ .type = .string, .value = "hello world" },
    Token{ .type = .pipe, .value = "|" },
    Token{ .type = .word, .value = "grep" },
    Token{ .type = .word, .value = "pattern" },
    Token{ .type = .eof, .value = "" },
]
```

**Key Features**:
- Handles escaping: `\$`, `\"`, `\\`
- Quote types: single (`'`), double (`"`), backticks (`` ` ``)
- Operator recognition: `|`, `||`, `&&`, `;`, `&`, `<`, `>`, `>>`
- Position tracking for error messages

**Pseudocode**:
```
function tokenize(input: string) -> []Token:
    tokens = []
    pos = 0
    line = 1
    col = 1

    while pos < input.length:
        // Skip whitespace
        while input[pos] == ' ' or input[pos] == '\t':
            pos++
            col++

        if pos >= input.length:
            break

        // Read next token
        token = null
        ch = input[pos]

        if ch == '\n':
            token = Token(newline, "\n", line, col)
            line++
            col = 1
            pos++
        else if ch == '|':
            if input[pos+1] == '|':
                token = Token(pipe_pipe, "||", line, col)
                pos += 2
            else:
                token = Token(pipe, "|", line, col)
                pos++
        else if ch == '&':
            if input[pos+1] == '&':
                token = Token(ampersand_ampersand, "&&", line, col)
                pos += 2
            else:
                token = Token(ampersand, "&", line, col)
                pos++
        else if ch == '"' or ch == '\'':
            token = read_quoted_string(input, pos, line, col)
        else if is_word_char(ch):
            token = read_word(input, pos, line, col)
        else:
            error("Unexpected character")

        tokens.append(token)
        col += token.value.length

    tokens.append(Token(eof, "", line, col))
    return tokens
```

### Recursive Descent Parser (src/parser/parser.zig)

**Algorithm**: Top-down recursive descent with operator precedence

**Time Complexity**: O(n) where n is number of tokens

**Grammar** (simplified):
```
program        → statement_list
statement_list → statement (';' | '\n' | '&') statement_list | statement
statement      → pipeline | conditional | loop | function_def
pipeline       → command ('|' command)*
command        → word word* redirect*
conditional    → 'if' pipeline 'then' statement_list ('else' statement_list)? 'fi'
loop           → 'while' pipeline 'do' statement_list 'done'
               | 'for' word 'in' word* 'do' statement_list 'done'
```

**Operator Precedence** (highest to lowest):
1. Redirections (`<`, `>`, `>>`)
2. Pipes (`|`)
3. Logical AND (`&&`)
4. Logical OR (`||`)
5. Sequential (`;`)
6. Background (`&`)

**Parsing Strategy**:
```
function parse_program() -> AST:
    statements = []
    while not at_eof():
        stmt = parse_statement()
        statements.append(stmt)
        if current_token() in [';', '\n']:
            consume()
    return AST(statements)

function parse_statement() -> ASTNode:
    if current_token() == 'if':
        return parse_conditional()
    else if current_token() == 'while':
        return parse_loop()
    else if current_token() == 'for':
        return parse_for_loop()
    else if current_token() == 'function':
        return parse_function()
    else:
        return parse_pipeline()

function parse_pipeline() -> ASTNode:
    commands = []
    commands.append(parse_command())

    while current_token() == '|':
        consume('|')
        commands.append(parse_command())

    if commands.length == 1:
        return commands[0]
    else:
        return Pipeline(commands)

function parse_command() -> Command:
    name = expect(word)
    args = []
    redirects = []

    while current_token() == word:
        args.append(consume())

    while current_token() in ['<', '>', '>>']:
        redirects.append(parse_redirect())

    return Command(name, args, redirects)
```

**Error Recovery**:
- Panic mode: Skip to next statement boundary
- Position tracking: Report line and column
- Context-aware messages: "Expected 'then' after 'if' condition"

### AST Construction

**Example**: `if [ -f file ]; then cat file | grep pattern; fi`

**Token Stream**:
```
[if] [[] [-f] [file] []] [;] [then] [cat] [file] [|] [grep] [pattern] [;] [fi]
```

**AST**:
```
Conditional {
    condition: Command {
        name: "[",
        args: ["-f", "file", "]"],
        redirects: []
    },
    then_branch: CompoundStatement {
        statements: [
            Pipeline {
                commands: [
                    Command { name: "cat", args: ["file"] },
                    Command { name: "grep", args: ["pattern"] }
                ]
            }
        ]
    },
    else_branch: null
}
```

## Expansion Algorithms

### Variable Expansion (src/utils/expansion.zig)

**Algorithm**: Pattern matching with lookahead

**Time Complexity**: O(n*m) where n is input length, m is average variable name length

**Process**:
```
Input: "Hello $USER, your home is $HOME"

1. Scan for '$'
2. Determine expansion type:
   - $VAR → Simple variable
   - ${VAR} → Braced variable
   - ${VAR:-default} → With default
   - ${VAR:=assign} → With assignment
3. Look up variable in environment
4. Replace with value
5. Continue scanning
```

**Pseudocode**:
```
function expand_variables(input: string, env: Environment) -> string:
    result = ""
    pos = 0

    while pos < input.length:
        if input[pos] == '$':
            if input[pos+1] == '{':
                // Braced expansion: ${VAR}
                end = find_matching_brace(input, pos+2)
                var_expr = input[pos+2..end]
                value = expand_variable_expression(var_expr, env)
                result += value
                pos = end + 1
            else:
                // Simple expansion: $VAR
                end = pos + 1
                while is_var_char(input[end]):
                    end++
                var_name = input[pos+1..end]
                value = env.get(var_name) or ""
                result += value
                pos = end
        else if input[pos] == '\\' and input[pos+1] == '$':
            // Escaped dollar sign
            result += '$'
            pos += 2
        else:
            result += input[pos]
            pos++

    return result
```

**Special Variables**:
- `$?`: Last exit code
- `$#`: Argument count
- `$@`: All arguments
- `$$`: Process ID
- `$!`: Last background PID
- `$0`: Shell name
- `$1-$9`: Positional parameters

### Command Substitution (src/utils/expansion.zig)

**Algorithm**: Recursive execution with output capture

**Time Complexity**: O(n + T) where n is input length, T is command execution time

**Process**:
```
Input: "Files: $(ls *.txt)"

1. Find $( or backtick
2. Extract command
3. Execute command, capture stdout
4. Replace with output
5. Strip trailing newlines
```

**Pseudocode**:
```
function expand_command_substitution(input: string) -> string:
    result = ""
    pos = 0

    while pos < input.length:
        if input[pos..pos+2] == "$(":
            // Find matching )
            depth = 1
            end = pos + 2
            while depth > 0:
                if input[end] == '(':
                    depth++
                else if input[end] == ')':
                    depth--
                end++

            command = input[pos+2..end-1]
            output = execute_and_capture(command)
            result += trim_trailing_newlines(output)
            pos = end

        else if input[pos] == '`':
            // Backtick substitution
            end = pos + 1
            while input[end] != '`':
                end++
            command = input[pos+1..end]
            output = execute_and_capture(command)
            result += trim_trailing_newlines(output)
            pos = end + 1

        else:
            result += input[pos]
            pos++

    return result
```

### Brace Expansion (src/utils/brace.zig)

**Algorithm**: Recursive combinatorial expansion

**Time Complexity**: O(n * m) where n is input length, m is number of expansions

**Examples**:
- `{a,b,c}` → `a b c`
- `file{1,2,3}.txt` → `file1.txt file2.txt file3.txt`
- `{a,b}{1,2}` → `a1 a2 b1 b2`
- `{1..5}` → `1 2 3 4 5`

**Pseudocode**:
```
function expand_braces(input: string) -> []string:
    // Find first brace expression
    start = find(input, '{')
    if start == -1:
        return [input]

    end = find_matching_brace(input, start)
    prefix = input[0..start]
    suffix = input[end+1..]
    content = input[start+1..end]

    // Check for sequence: {1..10}
    if is_sequence(content):
        values = expand_sequence(content)
    else:
        // Split by comma
        values = split(content, ',')

    // Combine with prefix and suffix
    results = []
    for value in values:
        expanded = prefix + value + suffix
        // Recursively expand suffix
        for result in expand_braces(expanded):
            results.append(result)

    return results

function is_sequence(content: string) -> bool:
    return contains(content, "..")

function expand_sequence(content: string) -> []string:
    parts = split(content, "..")
    start = parse_int(parts[0])
    end = parse_int(parts[1])

    results = []
    if start <= end:
        for i in start..=end:
            results.append(to_string(i))
    else:
        for i in start..=end step -1:
            results.append(to_string(i))

    return results
```

**Example Execution**:
```
Input: "file{1..3}.{txt,log}"

Step 1: Expand {1..3}
  → "file1.{txt,log}" "file2.{txt,log}" "file3.{txt,log}"

Step 2: Expand {txt,log} in each
  → "file1.txt" "file1.log" "file2.txt" "file2.log" "file3.txt" "file3.log"

Output: ["file1.txt", "file1.log", "file2.txt", "file2.log", "file3.txt", "file3.log"]
```

## Glob Matching

### Pattern Matching (src/utils/glob.zig)

**Algorithm**: Recursive backtracking with optimization

**Time Complexity**: O(n * m) worst case, O(n + m) average case
- n = pattern length
- m = string length

**Wildcard Support**:
- `*`: Matches any number of characters (including zero)
- `?`: Matches exactly one character
- `[abc]`: Matches one of a, b, or c
- `[a-z]`: Matches any character in range
- `[!abc]`: Matches any character except a, b, or c

**Pseudocode**:
```
function glob_match(pattern: string, text: string) -> bool:
    return match_recursive(pattern, 0, text, 0)

function match_recursive(pattern, p_pos, text, t_pos) -> bool:
    // Base cases
    if p_pos >= pattern.length and t_pos >= text.length:
        return true
    if p_pos >= pattern.length:
        return false

    ch = pattern[p_pos]

    if ch == '*':
        // Try matching zero characters
        if match_recursive(pattern, p_pos + 1, text, t_pos):
            return true

        // Try matching one or more characters
        while t_pos < text.length:
            t_pos++
            if match_recursive(pattern, p_pos + 1, text, t_pos):
                return true

        return false

    else if ch == '?':
        if t_pos >= text.length:
            return false
        return match_recursive(pattern, p_pos + 1, text, t_pos + 1)

    else if ch == '[':
        // Character class
        end = find_matching_bracket(pattern, p_pos)
        char_class = pattern[p_pos+1..end]

        if t_pos >= text.length:
            return false

        if match_char_class(char_class, text[t_pos]):
            return match_recursive(pattern, end + 1, text, t_pos + 1)
        else:
            return false

    else:
        // Literal character
        if t_pos >= text.length or text[t_pos] != ch:
            return false
        return match_recursive(pattern, p_pos + 1, text, t_pos + 1)

function match_char_class(char_class: string, ch: char) -> bool:
    negate = (char_class[0] == '!')
    if negate:
        char_class = char_class[1..]

    matched = false

    i = 0
    while i < char_class.length:
        if i + 2 < char_class.length and char_class[i+1] == '-':
            // Range: a-z
            if ch >= char_class[i] and ch <= char_class[i+2]:
                matched = true
                break
            i += 3
        else:
            // Single character
            if ch == char_class[i]:
                matched = true
                break
            i++

    return negate ? !matched : matched
```

### File Globbing (src/utils/glob.zig)

**Algorithm**: Directory traversal with pattern matching

**Time Complexity**: O(N * M) where N is number of files, M is pattern complexity

**Process**:
```
Input: "src/**/*.zig"

1. Split pattern by directory separators
2. For each segment:
   - If contains wildcard → List directory, filter by pattern
   - If literal → Validate path exists
3. Recurse into subdirectories for **
4. Combine results
```

**Pseudocode**:
```
function glob_files(pattern: string) -> []string:
    segments = split(pattern, '/')
    return glob_recursive(segments, 0, ".")

function glob_recursive(segments, index, base_path) -> []string:
    if index >= segments.length:
        return [base_path]

    segment = segments[index]
    results = []

    if segment == "**":
        // Recursive wildcard
        for entry in list_dir_recursive(base_path):
            if match_remaining_pattern(entry, segments, index+1):
                results.append(entry)

    else if contains_wildcard(segment):
        // Wildcard in segment
        for entry in list_dir(base_path):
            if glob_match(segment, entry.name):
                new_path = join(base_path, entry.name)
                for result in glob_recursive(segments, index+1, new_path):
                    results.append(result)

    else:
        // Literal segment
        new_path = join(base_path, segment)
        if path_exists(new_path):
            for result in glob_recursive(segments, index+1, new_path):
                results.append(result)

    return results
```

## Execution Algorithms

### Pipeline Execution (src/executor/executor.zig)

**Algorithm**: Fork-exec with pipe chaining

**Process**:
```
Command: cat file | grep pattern | wc -l

1. Create N-1 pipes for N commands
   pipe1: [read_fd1, write_fd1]
   pipe2: [read_fd2, write_fd2]

2. Fork first command (cat):
   - Close pipe read ends
   - Dup write_fd1 to stdout (fd 1)
   - Exec cat

3. Fork second command (grep):
   - Dup read_fd1 to stdin (fd 0)
   - Dup write_fd2 to stdout (fd 1)
   - Exec grep

4. Fork third command (wc):
   - Dup read_fd2 to stdin (fd 0)
   - Close pipe ends
   - Exec wc

5. Parent closes all pipe ends
6. Wait for all children
```

**Pseudocode**:
```
function execute_pipeline(commands: []Command) -> ExitCode:
    // Create pipes
    pipes = []
    for i in 0..(commands.length - 1):
        pipes.append(create_pipe())

    // Fork processes
    pids = []
    for i, command in enumerate(commands):
        pid = fork()

        if pid == 0:  // Child process
            // Set up stdin
            if i > 0:
                dup2(pipes[i-1].read_fd, STDIN)

            // Set up stdout
            if i < commands.length - 1:
                dup2(pipes[i].write_fd, STDOUT)

            // Close all pipe fds
            for pipe in pipes:
                close(pipe.read_fd)
                close(pipe.write_fd)

            // Execute command
            exec(command.name, command.args)
            exit(127)  // If exec fails

        else:  // Parent process
            pids.append(pid)

    // Close all pipe fds in parent
    for pipe in pipes:
        close(pipe.read_fd)
        close(pipe.write_fd)

    // Wait for all children
    last_status = 0
    for pid in pids:
        status = waitpid(pid)
        last_status = status

    return last_status
```

### Background Job Management (src/jobs/)

**Algorithm**: Process group tracking with signal handling

**Process**:
```
Command: sleep 100 &

1. Fork process
2. Create new process group (setpgid)
3. Store job info in background_jobs array
4. Don't wait (return immediately)
5. Install SIGCHLD handler
6. On SIGCHLD:
   - Check all background jobs
   - Update status of completed jobs
```

**Pseudocode**:
```
function execute_background(command: Command) -> JobID:
    pid = fork()

    if pid == 0:  // Child
        setpgid(0, 0)  // New process group
        exec(command)

    else:  // Parent
        job_id = next_job_id++
        background_jobs[job_id] = BackgroundJob{
            pid: pid,
            job_id: job_id,
            command: command.to_string(),
            status: .running
        }
        print("[{}] {}", job_id, pid)
        return job_id

function signal_handler_SIGCHLD():
    // Check all background jobs
    for job in background_jobs:
        if job.status == .running:
            status = waitpid(job.pid, WNOHANG)
            if status != 0:
                job.status = if WIFEXITED(status): .exited else: .signaled
                print("[{}] Done: {}", job.job_id, job.command)
```

## Completion Algorithms

### Command Completion (src/completion/)

**Algorithm**: Multi-source prefix matching with ranking

**Sources**:
1. Builtins
2. Commands in PATH
3. Aliases
4. Functions
5. Files in current directory

**Pseudocode**:
```
function complete_command(prefix: string) -> []Completion:
    completions = []

    // 1. Builtins
    for builtin in BUILTINS:
        if starts_with(builtin, prefix):
            completions.append(Completion{
                value: builtin,
                type: .builtin,
                description: BUILTIN_DESCRIPTIONS[builtin]
            })

    // 2. Commands in PATH
    for dir in PATH:
        for file in list_dir(dir):
            if starts_with(file, prefix) and is_executable(file):
                completions.append(Completion{
                    value: file,
                    type: .command
                })

    // 3. Aliases
    for alias in aliases:
        if starts_with(alias, prefix):
            completions.append(Completion{
                value: alias,
                type: .alias
            })

    // 4. Functions
    for function in functions:
        if starts_with(function, prefix):
            completions.append(Completion{
                value: function,
                type: .function
            })

    // Sort by relevance
    sort(completions, by: rank)

    return completions

function rank(completion: Completion) -> int:
    score = 0

    // Exact match bonus
    if completion.value == prefix:
        score += 100

    // Type priorities
    if completion.type == .builtin:
        score += 10
    else if completion.type == .alias:
        score += 8
    else if completion.type == .function:
        score += 6

    // Frequency bonus (from history)
    score += usage_count(completion.value)

    return score
```

### File Completion (src/completion/)

**Algorithm**: Directory traversal with fuzzy matching

**Process**:
```
Input: "src/par"

1. Split into directory and prefix
   dir = "src/"
   prefix = "par"

2. List directory entries
3. Filter by prefix
4. Add directory indicator for dirs
5. Sort (dirs first, then files)
```

**Pseudocode**:
```
function complete_file(input: string) -> []Completion:
    // Split into directory and filename
    last_slash = rfind(input, '/')
    if last_slash != -1:
        dir = input[0..last_slash+1]
        prefix = input[last_slash+1..]
    else:
        dir = "."
        prefix = input

    completions = []

    for entry in list_dir(dir):
        if starts_with(entry.name, prefix):
            completion = Completion{
                value: dir + entry.name,
                type: if entry.is_dir: .directory else: .file
            }

            // Add trailing slash for directories
            if entry.is_dir:
                completion.value += "/"

            completions.append(completion)

    // Sort: directories first, then alphabetically
    sort(completions, by: |a, b| {
        if a.type == .directory and b.type != .directory:
            return -1
        if a.type != .directory and b.type == .directory:
            return 1
        return compare(a.value, b.value)
    })

    return completions
```

## Performance Optimizations

### 1. String Interning

**Problem**: Many repeated strings (commands, paths)

**Solution**: Intern common strings
```zig
const INTERNED_STRINGS = std.StringHashMap([]const u8).init();

function intern(str: []const u8) -> []const u8:
    if INTERNED_STRINGS.get(str):
        return INTERNED_STRINGS.get(str)
    else:
        copy = allocate(str)
        INTERNED_STRINGS.put(str, copy)
        return copy
```

**Benefit**: Reduces memory, enables pointer comparison

### 2. Arena Allocator for Parser

**Problem**: Many small allocations during parsing

**Solution**: Use arena allocator
```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

var parser = Parser.init(arena.allocator());
ast = try parser.parse();
// All allocations freed at once
```

**Benefit**: Faster allocation, bulk deallocation

### 3. Completion Caching

**Problem**: Expensive directory traversal for completions

**Solution**: Cache results with invalidation
```zig
const CompletionCache = struct {
    entries: std.StringHashMap([]Completion),
    timestamps: std.StringHashMap(i64),

    function get(prefix: string) -> ?[]Completion:
        if entries.get(prefix):
            timestamp = timestamps.get(prefix)
            if time.now() - timestamp < 60:  // 1 minute cache
                return entries.get(prefix)
        return null
};
```

**Benefit**: Instant completions for repeated queries

### 4. Parallel Directory Traversal

**Problem**: Slow directory traversal for large directories

**Solution**: Use thread pool
```zig
function glob_parallel(pattern: string) -> []string:
    var pool = ThreadPool.init(allocator, 0)
    defer pool.deinit()

    segments = split(pattern, '/')
    if segments.length > 1:
        // Process each top-level dir in parallel
        for segment in segments[0]:
            try pool.submit(glob_segment, .{segment, segments[1..]})
        pool.waitIdle()
```

**Benefit**: 2-4x faster on multi-directory globs

## Algorithm Complexity Summary

| Algorithm | Time | Space | Notes |
|-----------|------|-------|-------|
| Tokenization | O(n) | O(n) | Linear scan |
| Parsing | O(n) | O(n) | Recursive descent |
| Variable expansion | O(n*m) | O(n) | n=input, m=avg var len |
| Brace expansion | O(n*m) | O(n*m) | Combinatorial |
| Glob matching | O(n*m) | O(1) | n=pattern, m=string |
| File globbing | O(N*M) | O(N) | N=files, M=pattern |
| Pipeline execution | O(n) | O(n) | n=commands |
| Completion | O(N*log N) | O(N) | With sorting |

## Related Documentation

- [Architecture](ARCHITECTURE.md) - System architecture
- [Data Structures](DATA_STRUCTURES.md) - Data structure details
- [API Reference](API.md) - Public APIs
- [Performance](CPU_OPTIMIZATION.md) - CPU optimization techniques
