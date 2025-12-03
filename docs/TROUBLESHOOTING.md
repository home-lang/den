# Troubleshooting Guide

This guide helps you diagnose and fix common issues with Den Shell.

## Table of Contents

- [Installation Issues](#installation-issues)
- [Startup Problems](#startup-problems)
- [Performance Issues](#performance-issues)
- [Command Execution](#command-execution)
- [Completion Problems](#completion-problems)
- [Configuration Issues](#configuration-issues)
- [Theme Problems](#theme-problems)
- [Git Integration](#git-integration)
- [Plugin Issues](#plugin-issues)
- [Memory Issues](#memory-issues)
- [Getting Help](#getting-help)

---

## Installation Issues

### Build Fails with Zig Errors

**Symptoms:** Build fails with compilation errors.

**Solutions:**

1. **Check Zig version:**
   ```bash
   zig version
   ```
   Den requires Zig 0.16-dev.

2. **Clean build cache:**
   ```bash
   rm -rf .zig-cache zig-out
   zig build
   ```

3. **Update Zig:**
   Download the latest version from [ziglang.org](https://ziglang.org/download/).

### Permission Denied

**Symptoms:** Cannot execute `den` after build.

**Solution:**
```bash
chmod +x ./zig-out/bin/den
```

### Missing Dependencies on Linux

**Symptoms:** Build fails with missing library errors.

**Solution:**
```bash
# Debian/Ubuntu
sudo apt install build-essential

# Fedora
sudo dnf install gcc glibc-devel

# Arch
sudo pacman -S base-devel
```

---

## Startup Problems

### Shell Doesn't Start

**Symptoms:** Running `den` shows nothing or exits immediately.

**Solutions:**

1. **Check for errors:**
   ```bash
   ./zig-out/bin/den 2>&1
   ```

2. **Run with minimal config:**
   ```bash
   ./zig-out/bin/den --no-config
   ```

3. **Check config file syntax:**
   ```bash
   cat ~/.config/den/den.jsonc
   # Look for JSON syntax errors
   ```

### Slow Startup

**Symptoms:** Shell takes several seconds to start.

**Solutions:**

1. **Check config file size:**
   Large alias lists or history can slow startup.

2. **Disable plugins temporarily:**
   ```jsonc
   {
     "plugins": {
       "enabled": false
     }
   }
   ```

3. **Profile startup:**
   ```bash
   time ./zig-out/bin/den -c "exit"
   ```

### "Config file not found" Warning

**Symptoms:** Warning about missing configuration.

**Solution:** Create a config file:
```bash
mkdir -p ~/.config/den
echo '{}' > ~/.config/den/den.jsonc
```

---

## Performance Issues

### Commands Run Slowly

**Symptoms:** Simple commands take too long.

**Solutions:**

1. **Check PATH length:**
   ```bash
   echo $PATH | tr ':' '\n' | wc -l
   ```
   Very long PATH can slow command lookup.

2. **Check for recursive aliases:**
   ```bash
   alias
   # Look for aliases that reference themselves
   ```

3. **Disable unused features:**
   ```jsonc
   {
     "features": {
       "syntax_highlighting": false,
       "git_integration": false
     }
   }
   ```

### High CPU Usage

**Symptoms:** Den uses excessive CPU.

**Solutions:**

1. **Check for infinite loops in config:**
   Review any custom scripts or functions.

2. **Disable completion temporarily:**
   ```jsonc
   {
     "completion": {
       "enabled": false
     }
   }
   ```

3. **Check background jobs:**
   ```bash
   jobs
   ```

### Lag When Typing

**Symptoms:** Noticeable delay between keystrokes and display.

**Solutions:**

1. **Disable syntax highlighting:**
   ```jsonc
   {
     "syntax_highlighting": false
   }
   ```

2. **Reduce completion candidates:**
   ```jsonc
   {
     "completion": {
       "max_candidates": 50
     }
   }
   ```

3. **Check terminal emulator:** Some terminals are slower than others.

---

## Command Execution

### "Command not found"

**Symptoms:** Commands that should work aren't found.

**Solutions:**

1. **Check PATH:**
   ```bash
   echo $PATH
   which <command>
   ```

2. **Rehash command cache:**
   ```bash
   hash -r
   ```

3. **Check command exists:**
   ```bash
   ls -la $(which <command>)
   ```

### Commands Behave Differently

**Symptoms:** Commands work differently than in bash/zsh.

**Explanation:** Den has built-in versions of some commands that may differ:

| Command | Den Version | System Version |
|---------|-------------|----------------|
| `echo` | Built-in | `/bin/echo` |
| `test` | Built-in | `/bin/test` |
| `[` | Built-in | `/bin/[` |

**Solution:** Use full path for system version:
```bash
/bin/echo "Using system echo"
```

### Exit Codes Wrong

**Symptoms:** `$?` doesn't reflect expected exit code.

**Solutions:**

1. **Check immediately after command:**
   ```bash
   false; echo $?  # Should be 1
   ```

2. **Don't use in pipeline:**
   ```bash
   # Wrong - gets exit of last command
   command | grep pattern; echo $?

   # Right - use PIPESTATUS or check separately
   command
   echo $?
   ```

### Pipes Not Working

**Symptoms:** Piped commands don't work correctly.

**Solutions:**

1. **Check syntax:**
   ```bash
   # Correct
   cat file | grep pattern

   # Wrong (no space)
   cat file|grep pattern
   ```

2. **Check for buffering issues:**
   ```bash
   # Force line buffering
   command | stdbuf -oL grep pattern
   ```

---

## Completion Problems

### Tab Completion Not Working

**Symptoms:** Pressing Tab does nothing.

**Solutions:**

1. **Check completion is enabled:**
   ```jsonc
   {
     "completion": {
       "enabled": true
     }
   }
   ```

2. **Check terminal settings:**
   ```bash
   stty -a | grep -i tab
   ```

3. **Test basic completion:**
   ```bash
   # Type partial command and press Tab
   ec<TAB>  # Should complete to "echo"
   ```

### Wrong Completions

**Symptoms:** Completions are incorrect or outdated.

**Solutions:**

1. **Clear completion cache:**
   ```bash
   hash -r
   ```

2. **Check for conflicting aliases:**
   ```bash
   alias | grep <command>
   ```

### Git Completion Not Working

**Symptoms:** Git branch/command completion doesn't work.

**Solutions:**

1. **Verify in git repository:**
   ```bash
   git rev-parse --git-dir
   ```

2. **Check git is installed:**
   ```bash
   which git
   git --version
   ```

3. **Enable git completion:**
   ```jsonc
   {
     "completion": {
       "git": true
     }
   }
   ```

---

## Configuration Issues

### Config Not Loading

**Symptoms:** Settings don't take effect.

**Solutions:**

1. **Check config location:**
   ```bash
   ls -la ~/.config/den/den.jsonc
   ls -la ~/.denrc
   ```

2. **Validate JSON syntax:**
   ```bash
   # Use jq to validate (strips comments first)
   grep -v '//' ~/.config/den/den.jsonc | jq .
   ```

3. **Check for typos:**
   Common mistakes:
   - Missing commas
   - Trailing commas (not allowed in strict JSON)
   - Unquoted keys

### Hot Reload Not Working

**Symptoms:** Config changes don't apply automatically.

**Solutions:**

1. **Enable hot reload:**
   ```jsonc
   {
     "hot_reload": true
   }
   ```

2. **Manual reload:**
   ```bash
   reload
   ```

3. **Check file permissions:**
   ```bash
   ls -la ~/.config/den/den.jsonc
   ```

### Aliases Not Working

**Symptoms:** Defined aliases don't work.

**Solutions:**

1. **Check alias definition:**
   ```bash
   alias
   alias <name>
   ```

2. **Verify syntax in config:**
   ```jsonc
   {
     "aliases": {
       "ll": "ls -la",
       "gs": "git status"
     }
   }
   ```

3. **Check for conflicts:**
   ```bash
   which <alias_name>
   type <alias_name>
   ```

---

## Theme Problems

### Colors Not Displaying

**Symptoms:** No colors or wrong colors.

**Solutions:**

1. **Check terminal color support:**
   ```bash
   echo $TERM
   echo $COLORTERM
   ```

2. **Test true color:**
   ```bash
   printf '\033[38;2;255;0;0mRed\033[0m\n'
   ```

3. **Enable colors in config:**
   ```jsonc
   {
     "colors": true
   }
   ```

### Theme Not Loading

**Symptoms:** Custom theme doesn't apply.

**Solutions:**

1. **Check theme path:**
   ```jsonc
   {
     "theme": "~/.config/den/themes/mytheme.jsonc"
   }
   ```

2. **Verify theme file exists:**
   ```bash
   ls -la ~/.config/den/themes/
   ```

3. **Check theme syntax:**
   ```bash
   cat ~/.config/den/themes/mytheme.jsonc
   ```

### Prompt Not Displaying Correctly

**Symptoms:** Prompt shows wrong information or garbled characters.

**Solutions:**

1. **Check prompt format:**
   ```jsonc
   {
     "prompt": {
       "format": "{user}@{host}:{cwd}$ "
     }
   }
   ```

2. **Check for special characters:**
   Some terminals don't support Unicode.

3. **Use simple prompt:**
   ```jsonc
   {
     "prompt": {
       "format": "$ "
     }
   }
   ```

---

## Git Integration

### Git Status Not Showing

**Symptoms:** Git branch/status not in prompt.

**Solutions:**

1. **Verify in git repo:**
   ```bash
   git status
   ```

2. **Enable git integration:**
   ```jsonc
   {
     "git": {
       "enabled": true,
       "show_branch": true,
       "show_status": true
     }
   }
   ```

3. **Check git is accessible:**
   ```bash
   which git
   ```

### Slow Git Status

**Symptoms:** Prompt is slow in git repositories.

**Solutions:**

1. **Disable status checks:**
   ```jsonc
   {
     "git": {
       "show_status": false
     }
   }
   ```

2. **For large repos, disable in repo:**
   ```bash
   git config --local den.enabled false
   ```

---

## Plugin Issues

### Plugin Not Loading

**Symptoms:** Plugin features not available.

**Solutions:**

1. **Check plugin is enabled:**
   ```jsonc
   {
     "plugins": {
       "enabled": true,
       "list": ["myplugin"]
     }
   }
   ```

2. **Check plugin path:**
   ```bash
   ls -la ~/.config/den/plugins/
   ```

3. **Check for errors:**
   Plugin errors are logged to stderr.

### Plugin Crashes Shell

**Symptoms:** Shell exits when plugin runs.

**Solutions:**

1. **Disable plugin:**
   ```jsonc
   {
     "plugins": {
       "list": []
     }
   }
   ```

2. **Run with verbose errors:**
   ```bash
   DEN_DEBUG=1 den
   ```

---

## Memory Issues

### Memory Leak Warnings

**Symptoms:** Messages about leaked memory on exit.

**Explanation:** Debug builds show memory leak warnings. These are being tracked and fixed.

**Solutions:**

1. **Use release build:**
   ```bash
   zig build -Doptimize=ReleaseFast
   ```

2. **Report persistent leaks:**
   File an issue with reproduction steps.

### High Memory Usage

**Symptoms:** Den uses excessive memory.

**Solutions:**

1. **Check history size:**
   ```jsonc
   {
     "history": {
       "max_size": 1000
     }
   }
   ```

2. **Clear history:**
   ```bash
   history -c
   ```

3. **Restart shell periodically** for long-running sessions.

---

## Getting Help

### Collect Debug Information

When reporting issues, include:

```bash
# Version info
zig version
./zig-out/bin/den --version

# System info
uname -a
echo $TERM
echo $SHELL

# Config
cat ~/.config/den/den.jsonc

# Error output
./zig-out/bin/den 2>&1 | head -50
```

### Where to Get Help

1. **Documentation:** Check [docs/](./README.md)
2. **GitHub Issues:** [Report bugs](https://github.com/anthropics/den/issues)
3. **Discussions:** Ask questions in GitHub Discussions

### Reporting Bugs

Include:
- Den version and Zig version
- Operating system and version
- Steps to reproduce
- Expected vs actual behavior
- Relevant config snippets
- Error messages

---

## See Also

- [Configuration Guide](./config.md)
- [Builtin Commands](./BUILTINS.md)
- [Architecture Overview](./ARCHITECTURE.md)
