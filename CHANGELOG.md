
## ...main

### 🚀 Features

- **Extended Glob Patterns** - Advanced file matching patterns (zsh-style) ([src/utils/glob.zig:78-179](src/utils/glob.zig))
  - `*.txt~*.log` - Exclusion patterns (match *.txt but exclude *.log files)
  - `*.(sh|zsh)` - Alternation (match multiple extensions in one pattern)
  - `*.(.)` - File type qualifiers (match only regular files)
  - `*(/)` - Directory qualifier (match only directories)
  - `*(*)` - Executable qualifier (match only executable files)
  - `*(@)` - Symlink qualifier (match only symbolic links)
  - Powerful file filtering for scripts and command line!

- **Arrays** - Full array support for shell scripting (zsh/bash-style) ([src/shell.zig:102, 2743-2837](src/shell.zig), [src/utils/expansion.zig:303-362](src/utils/expansion.zig), [src/types/variable.zig](src/types/variable.zig))
  - `arr=(one two three)` - Array creation and assignment
  - `${arr[@]}` or `${arr[*]}` - Expand all array elements
  - `${arr[0]}`, `${arr[1]}` - Access elements by index (0-based)
  - `${#arr}` - Get array length
  - `arr=()` - Create empty arrays
  - Arrays properly cleaned up on shell exit
  - Essential for advanced shell scripting!

- **Incremental History Append** - History saves after each command (zsh-style) ([src/shell.zig:1289-1292, 1342-1353](src/shell.zig))
  - Commands are immediately appended to history file after execution
  - Multiple shell sessions can now share history in real-time
  - No data loss if shell crashes or is force-killed
  - More reliable history across sessions

- **Fuzzy/Approximate Completion** - Smart completion matching (zsh-style) ([src/utils/terminal.zig:1232-1324](src/utils/terminal.zig))
  - Completions sorted by relevance using fuzzy matching scores
  - Better matches appear first in completion menu
  - Bonus points for: consecutive matches, start-of-string matches, matches after separators
  - Makes finding the right completion faster and more intuitive

- **Named Directories** - Quick navigation with directory aliases (zsh-style) ([src/shell.zig:99, 2517-2610](src/shell.zig), [src/executor/mod.zig:704-727](src/executor/mod.zig))
  - `hash -d proj=~/Documents/Projects` - Create directory alias
  - `cd ~proj` - Navigate to aliased directory
  - `cd ~proj/subfolder` - Works with subdirectories too
  - `hash -d` - List all named directories
  - Expands `~` in paths automatically

- **History Deduplication** - Intelligent command history management (zsh-style) ([src/shell.zig:1243-1264](src/shell.zig))
  - Automatically removes duplicate commands from history
  - Checks last 50 commands and removes old duplicates when new ones are added
  - Deduplicates when loading history from file
  - Keeps history clean and more useful for searching
  - More efficient history navigation

- **Auto CD** - Navigate to directories without typing `cd` (zsh-style) ([src/executor/mod.zig:495-507](src/executor/mod.zig))
  - Type directory paths directly: `Documents/Projects`, `../`, `~`, etc.
  - Works with relative paths, absolute paths, parent directories (..), and home (~)
  - Signature zsh feature now available in Den!

- **Menu Completion** - Interactive completion with arrow key navigation (already implemented) ([src/utils/terminal.zig:1034-1062](src/utils/terminal.zig))
  - Visual menu for selecting completions with arrow keys
  - Highlighted selection (black text on gray background)
  - Navigate with Up/Down or Left/Right arrow keys
  - Tab cycles through completions
  - Enter accepts selection
  - Directories shown in cyan color

### 🩹 Fixes

- **Fix history not being saved on exit** - History now saves before exit command terminates ([src/shell.zig:462](src/shell.zig))
  - Previously `std.process.exit(0)` bypassed the `deinit()` method where history was saved
  - Now explicitly calls `saveHistory()` before exiting
  - Ensures all commands are properly persisted to `~/.den_history`

- Fix ls -l command to display proper Unix file permissions, extended attributes, and hard link counts ([src/executor/mod.zig:2957-3095](src/executor/mod.zig))
  - Now reads actual file permissions from stat() instead of hardcoded "rw-r--r--"
  - Added @ indicator for files with extended attributes (macOS)
  - Displays actual hard link count from stat() instead of hardcoded "1"
  - Updated output format to match standard Unix ls -l format

- Fix prompt not displaying after Ctrl+L clear screen ([src/utils/terminal.zig:965-988](src/utils/terminal.zig), [src/shell.zig:3144-3177](src/shell.zig))
  - Added prompt refresh callback to LineEditor
  - Prompt now updates with current directory when screen is cleared with Ctrl+L
  - Current directory displays immediately after clear without needing to press Enter
  - Note: Cmd+K (macOS Terminal) is handled by Terminal.app, use Ctrl+L for shell-managed clear

### 🏡 Chore

- Initial commit ([e3c724b](https://github.com/stacksjs/krusty/commit/e3c724b))
- Wip ([880e8d7](https://github.com/stacksjs/krusty/commit/880e8d7))
- Wip ([6519940](https://github.com/stacksjs/krusty/commit/6519940))
- Wip ([fec2d46](https://github.com/stacksjs/krusty/commit/fec2d46))
- Wip ([9d8fb7b](https://github.com/stacksjs/krusty/commit/9d8fb7b))
- Wip ([2e83562](https://github.com/stacksjs/krusty/commit/2e83562))
- Wip ([3ed09b4](https://github.com/stacksjs/krusty/commit/3ed09b4))
- Wip ([12bc791](https://github.com/stacksjs/krusty/commit/12bc791))
- Wip ([6405c46](https://github.com/stacksjs/krusty/commit/6405c46))
- Wip ([ee6e8f8](https://github.com/stacksjs/krusty/commit/ee6e8f8))
- Wip ([893cc2b](https://github.com/stacksjs/krusty/commit/893cc2b))
- Wip ([313ab0b](https://github.com/stacksjs/krusty/commit/313ab0b))
- Wip ([56617ca](https://github.com/stacksjs/krusty/commit/56617ca))
- Wip ([83e778b](https://github.com/stacksjs/krusty/commit/83e778b))
- Wip ([fc03dd7](https://github.com/stacksjs/krusty/commit/fc03dd7))
- Wip ([bb75517](https://github.com/stacksjs/krusty/commit/bb75517))
- Wip ([dcc3422](https://github.com/stacksjs/krusty/commit/dcc3422))
- Wip ([a5a928e](https://github.com/stacksjs/krusty/commit/a5a928e))
- Wip ([239945f](https://github.com/stacksjs/krusty/commit/239945f))
- Wip ([5aa19fc](https://github.com/stacksjs/krusty/commit/5aa19fc))
- Wip ([2b1629a](https://github.com/stacksjs/krusty/commit/2b1629a))
- Wip ([38e704c](https://github.com/stacksjs/krusty/commit/38e704c))
- Wip ([626c9d7](https://github.com/stacksjs/krusty/commit/626c9d7))
- Wip ([0f94a76](https://github.com/stacksjs/krusty/commit/0f94a76))
- Wip ([be70173](https://github.com/stacksjs/krusty/commit/be70173))
- Wip ([c266ae8](https://github.com/stacksjs/krusty/commit/c266ae8))
- Wip ([22cc5dd](https://github.com/stacksjs/krusty/commit/22cc5dd))
- Wip ([1d08305](https://github.com/stacksjs/krusty/commit/1d08305))
- Wip ([d1204f7](https://github.com/stacksjs/krusty/commit/d1204f7))
- Wip ([c1bc1dc](https://github.com/stacksjs/krusty/commit/c1bc1dc))
- Wip ([a55e1f9](https://github.com/stacksjs/krusty/commit/a55e1f9))
- Wip ([20cebfd](https://github.com/stacksjs/krusty/commit/20cebfd))
- Wip ([271f4e2](https://github.com/stacksjs/krusty/commit/271f4e2))
- Wip ([ec7775c](https://github.com/stacksjs/krusty/commit/ec7775c))
- Wip ([b1f9d08](https://github.com/stacksjs/krusty/commit/b1f9d08))
- Wip ([4a74010](https://github.com/stacksjs/krusty/commit/4a74010))
- Wip ([44ac44a](https://github.com/stacksjs/krusty/commit/44ac44a))
- Wip ([936f6b5](https://github.com/stacksjs/krusty/commit/936f6b5))
- Wip ([312b53a](https://github.com/stacksjs/krusty/commit/312b53a))
- Wip ([2858a70](https://github.com/stacksjs/krusty/commit/2858a70))
- Wip ([d30dca7](https://github.com/stacksjs/krusty/commit/d30dca7))
- Wip ([23681cd](https://github.com/stacksjs/krusty/commit/23681cd))
- Wip ([4028b79](https://github.com/stacksjs/krusty/commit/4028b79))
- Wip ([49ccfd4](https://github.com/stacksjs/krusty/commit/49ccfd4))
- Wip ([a04f25e](https://github.com/stacksjs/krusty/commit/a04f25e))
- Wip ([ec094a2](https://github.com/stacksjs/krusty/commit/ec094a2))
- Wip ([4525a3b](https://github.com/stacksjs/krusty/commit/4525a3b))
- Wip ([9865ee4](https://github.com/stacksjs/krusty/commit/9865ee4))
- Wip ([0442194](https://github.com/stacksjs/krusty/commit/0442194))
- Wip ([d738345](https://github.com/stacksjs/krusty/commit/d738345))
- Wip ([ea2461d](https://github.com/stacksjs/krusty/commit/ea2461d))
- Wip ([8255bf2](https://github.com/stacksjs/krusty/commit/8255bf2))
- Wip ([8647377](https://github.com/stacksjs/krusty/commit/8647377))
- Wip ([717e192](https://github.com/stacksjs/krusty/commit/717e192))
- Wip ([88859bb](https://github.com/stacksjs/krusty/commit/88859bb))
- Wip ([088dfe6](https://github.com/stacksjs/krusty/commit/088dfe6))
- Wip ([86ddb87](https://github.com/stacksjs/krusty/commit/86ddb87))
- Wip ([f9861de](https://github.com/stacksjs/krusty/commit/f9861de))
- Wip ([eeb3bf7](https://github.com/stacksjs/krusty/commit/eeb3bf7))
- Wip ([0a57690](https://github.com/stacksjs/krusty/commit/0a57690))
- Wip ([cccb58b](https://github.com/stacksjs/krusty/commit/cccb58b))
- Wip ([16fbd55](https://github.com/stacksjs/krusty/commit/16fbd55))
- Wip ([52bf19d](https://github.com/stacksjs/krusty/commit/52bf19d))
- Wip ([7e3f660](https://github.com/stacksjs/krusty/commit/7e3f660))
- Wip ([960076d](https://github.com/stacksjs/krusty/commit/960076d))
- Wip ([4c82948](https://github.com/stacksjs/krusty/commit/4c82948))
- Wip ([6b6f232](https://github.com/stacksjs/krusty/commit/6b6f232))
- Wip ([bf0fcc1](https://github.com/stacksjs/krusty/commit/bf0fcc1))
- Wip ([1995e88](https://github.com/stacksjs/krusty/commit/1995e88))
- Wip ([3bb3a0e](https://github.com/stacksjs/krusty/commit/3bb3a0e))
- Wip ([4859024](https://github.com/stacksjs/krusty/commit/4859024))
- Wip ([cde91e2](https://github.com/stacksjs/krusty/commit/cde91e2))
- Wip ([a18cba0](https://github.com/stacksjs/krusty/commit/a18cba0))
- Wip ([dd9bed5](https://github.com/stacksjs/krusty/commit/dd9bed5))
- Wip ([5e36ab1](https://github.com/stacksjs/krusty/commit/5e36ab1))
- Wip ([36d371d](https://github.com/stacksjs/krusty/commit/36d371d))
- Wip ([eca9b04](https://github.com/stacksjs/krusty/commit/eca9b04))
- Wip ([99a95e8](https://github.com/stacksjs/krusty/commit/99a95e8))
- Wip ([7359ee5](https://github.com/stacksjs/krusty/commit/7359ee5))
- Wip ([a6af446](https://github.com/stacksjs/krusty/commit/a6af446))
- Wip ([a4097f4](https://github.com/stacksjs/krusty/commit/a4097f4))
- Wip ([87d0d8b](https://github.com/stacksjs/krusty/commit/87d0d8b))
- Wip ([6db848d](https://github.com/stacksjs/krusty/commit/6db848d))
- Wip ([3b58b46](https://github.com/stacksjs/krusty/commit/3b58b46))
- Wip ([7f66e59](https://github.com/stacksjs/krusty/commit/7f66e59))
- Wip ([31fe091](https://github.com/stacksjs/krusty/commit/31fe091))
- Wip ([5c583b9](https://github.com/stacksjs/krusty/commit/5c583b9))
- Wip ([ff5468d](https://github.com/stacksjs/krusty/commit/ff5468d))
- Wip ([ec3e57e](https://github.com/stacksjs/krusty/commit/ec3e57e))
- Wip ([4fac024](https://github.com/stacksjs/krusty/commit/4fac024))
- Wip ([bfb94e5](https://github.com/stacksjs/krusty/commit/bfb94e5))
- Wip ([6d174ab](https://github.com/stacksjs/krusty/commit/6d174ab))
- Wip ([867a524](https://github.com/stacksjs/krusty/commit/867a524))
- Wip ([62e66fd](https://github.com/stacksjs/krusty/commit/62e66fd))
- Wip ([dcbf687](https://github.com/stacksjs/krusty/commit/dcbf687))
- Wip ([0099a87](https://github.com/stacksjs/krusty/commit/0099a87))
- Wip ([3fb3ccb](https://github.com/stacksjs/krusty/commit/3fb3ccb))
- Wip ([bcedd90](https://github.com/stacksjs/krusty/commit/bcedd90))
- Wip ([70c79f4](https://github.com/stacksjs/krusty/commit/70c79f4))

### ❤️ Contributors

- Chris ([@chrisbbreuer](https://github.com/chrisbbreuer))

## v0.3.1...main

[compare changes](https://github.com/stacksjs/ts-starter/compare/v0.3.1...main)

### 🚀 Enhancements

- Add `bun-plugin-dts-auto` ([c0c487b](https://github.com/stacksjs/ts-starter/commit/c0c487b))

### ❤️ Contributors

- Chris <chrisbreuer93@gmail.com>

## v0.3.0...main

[compare changes](https://github.com/stacksjs/ts-starter/compare/v0.3.0...main)

### 🏡 Chore

- Fix isolatedDeclarations setting ([b87b6b1](https://github.com/stacksjs/ts-starter/commit/b87b6b1))
- Adjust urls ([0a40b72](https://github.com/stacksjs/ts-starter/commit/0a40b72))

### ❤️ Contributors

- Chris <chrisbreuer93@gmail.com>

## v0.2.1...main

[compare changes](https://github.com/stacksjs/ts-starter/compare/v0.2.1...main)

### 🚀 Enhancements

- Add `noFallthroughCasesInSwitch` ([b9cfa30](https://github.com/stacksjs/ts-starter/commit/b9cfa30))
- Add `verbatimModuleSyntax` ([c495d17](https://github.com/stacksjs/ts-starter/commit/c495d17))
- Several updates ([f703179](https://github.com/stacksjs/ts-starter/commit/f703179))

### 🩹 Fixes

- Properly use bun types ([7144221](https://github.com/stacksjs/ts-starter/commit/7144221))

### 🏡 Chore

- Adjust badge links ([432aff7](https://github.com/stacksjs/ts-starter/commit/432aff7))
- Add `runs-on` options ([9a5b97f](https://github.com/stacksjs/ts-starter/commit/9a5b97f))
- Cache node_modules ([ba2f6ce](https://github.com/stacksjs/ts-starter/commit/ba2f6ce))
- Use `ubuntu-latest` for now ([1add684](https://github.com/stacksjs/ts-starter/commit/1add684))
- Minor updates ([1007cff](https://github.com/stacksjs/ts-starter/commit/1007cff))
- Lint ([d531bdc](https://github.com/stacksjs/ts-starter/commit/d531bdc))
- Remove bunx usage ([e1a5575](https://github.com/stacksjs/ts-starter/commit/e1a5575))
- Pass bun flag ([960976f](https://github.com/stacksjs/ts-starter/commit/960976f))
- Use defaults ([157455b](https://github.com/stacksjs/ts-starter/commit/157455b))
- Run typecheck using bun flag ([f22f3b1](https://github.com/stacksjs/ts-starter/commit/f22f3b1))
- Test ([0b3c3a1](https://github.com/stacksjs/ts-starter/commit/0b3c3a1))
- Use modern js for commitlint ([4bd6978](https://github.com/stacksjs/ts-starter/commit/4bd6978))
- Update worklows readme ([f54aae9](https://github.com/stacksjs/ts-starter/commit/f54aae9))
- Adjust readme ([92d7ff1](https://github.com/stacksjs/ts-starter/commit/92d7ff1))
- More updates ([0225587](https://github.com/stacksjs/ts-starter/commit/0225587))
- Add .zed settings for biome ([1688024](https://github.com/stacksjs/ts-starter/commit/1688024))
- Extend via alias ([b108d30](https://github.com/stacksjs/ts-starter/commit/b108d30))
- Lint ([d961b2a](https://github.com/stacksjs/ts-starter/commit/d961b2a))
- Minor updates ([e66d44a](https://github.com/stacksjs/ts-starter/commit/e66d44a))

### ❤️ Contributors

- Chris <chrisbreuer93@gmail.com>

## v0.2.0...main

[compare changes](https://github.com/stacksjs/ts-starter/compare/v0.2.0...main)

### 🏡 Chore

- Remove unused action ([066f85a](https://github.com/stacksjs/ts-starter/commit/066f85a))
- Housekeeping ([fc4e24d](https://github.com/stacksjs/ts-starter/commit/fc4e24d))

### ❤️ Contributors

- Chris <chrisbreuer93@gmail.com>

## v0.1.1...main

[compare changes](https://github.com/stacksjs/ts-starter/compare/v0.1.1...main)

### 🏡 Chore

- Adjust eslint config name ([53c2aa6](https://github.com/stacksjs/ts-starter/commit/53c2aa6))
- Set type module ([22dde14](https://github.com/stacksjs/ts-starter/commit/22dde14))

### ❤️ Contributors

- Chris <chrisbreuer93@gmail.com>

## v0.1.0...main

[compare changes](https://github.com/stacksjs/ts-starter/compare/v0.1.0...main)

### 🏡 Chore

- Use correct cover image ([75bd3ae](https://github.com/stacksjs/ts-starter/commit/75bd3ae))

### ❤️ Contributors

- Chris <chrisbreuer93@gmail.com>

## v0.0.5...main

[compare changes](https://github.com/stacksjs/ts-starter/compare/v0.0.5...main)

### 🚀 Enhancements

- Add pkgx deps ([319c066](https://github.com/stacksjs/ts-starter/commit/319c066))
- Use flat eslint config ([cdb0093](https://github.com/stacksjs/ts-starter/commit/cdb0093))

### 🏡 Chore

- Fix badge ([bc3b000](https://github.com/stacksjs/ts-starter/commit/bc3b000))
- Minor updates ([78dc522](https://github.com/stacksjs/ts-starter/commit/78dc522))
- Housekeeping ([e1cba3b](https://github.com/stacksjs/ts-starter/commit/e1cba3b))
- Additional housekeeping ([f5dc625](https://github.com/stacksjs/ts-starter/commit/f5dc625))
- Add `.gitattributes` ([7080f8c](https://github.com/stacksjs/ts-starter/commit/7080f8c))
- Adjust deps ([cc71b42](https://github.com/stacksjs/ts-starter/commit/cc71b42))
- Adjust wording ([3bc54b3](https://github.com/stacksjs/ts-starter/commit/3bc54b3))
- Adjust readme cover ([e6acbb2](https://github.com/stacksjs/ts-starter/commit/e6acbb2))

### ❤️ Contributors

- Chris <chrisbreuer93@gmail.com>

## v0.0.5...main

[compare changes](https://github.com/stacksjs/ts-starter/compare/v0.0.5...main)

### 🚀 Enhancements

- Add pkgx deps ([319c066](https://github.com/stacksjs/ts-starter/commit/319c066))
- Use flat eslint config ([cdb0093](https://github.com/stacksjs/ts-starter/commit/cdb0093))

### 🏡 Chore

- Fix badge ([bc3b000](https://github.com/stacksjs/ts-starter/commit/bc3b000))
- Minor updates ([78dc522](https://github.com/stacksjs/ts-starter/commit/78dc522))
- Housekeeping ([e1cba3b](https://github.com/stacksjs/ts-starter/commit/e1cba3b))
- Additional housekeeping ([f5dc625](https://github.com/stacksjs/ts-starter/commit/f5dc625))
- Add `.gitattributes` ([7080f8c](https://github.com/stacksjs/ts-starter/commit/7080f8c))
- Adjust deps ([cc71b42](https://github.com/stacksjs/ts-starter/commit/cc71b42))
- Adjust wording ([3bc54b3](https://github.com/stacksjs/ts-starter/commit/3bc54b3))
- Adjust readme cover ([e6acbb2](https://github.com/stacksjs/ts-starter/commit/e6acbb2))

### ❤️ Contributors

- Chris <chrisbreuer93@gmail.com>
