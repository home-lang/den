# Den Shell Quick Reference

A quick reference guide for Den's interactive features and keyboard shortcuts.

## Tab Completion

### Basic Completion
```bash
# Complete commands
git st<TAB>      → git status

# Complete files
cat READ<TAB>    → cat README.md

# Complete directories (adds /)
cd Doc<TAB>      → cd Documents/
```

### Multiple Suggestions
```bash
cd /usr/l<TAB>
# Shows:  lib/  libexec/  local/

# Press TAB again to cycle through options
# Currently selected option is highlighted
```

### Mid-Word Path Expansion (zsh-style)
```bash
# Type abbreviations, get full paths
/u/l/b<TAB>           → /usr/local/bin/
~/D/P/d<TAB>          → ~/Documents/Projects/den/
./s/u/c<TAB>          → ./src/utils/completion.zig

# Works even with ambiguous segments!
/u/l/s<TAB>           → /usr/local/share/
# (even though /usr/l matches lib, libexec, local)
```

## History Navigation

### Basic History
```bash
Up Arrow     # Previous command
Down Arrow   # Next command
```

### History Substring Search
```bash
# Type part of a command, then press Up/Down
# to filter history by substring

den> git<Up>
# Shows only commands containing "git"
den> git commit -m "fix bug"

den> docker<Up>
# Shows only commands containing "docker"
den> docker ps -a
```

**Features:**
- Matches substring anywhere in command (not just at start)
- Press Up/Down to navigate through matches
- Press Down past last match to return to search query
- Type any character to exit search mode

## Keyboard Shortcuts

### Line Editing
| Key | Action |
|-----|--------|
| `Ctrl+A` | Move to beginning of line |
| `Ctrl+E` | Move to end of line |
| `Ctrl+U` | Clear line before cursor |
| `Ctrl+K` | Clear line after cursor |
| `Ctrl+W` | Delete word before cursor |
| `Ctrl+L` | Clear screen |
| `Ctrl+C` | Cancel current line |
| `Ctrl+D` | Exit shell (if line is empty) |

### Cursor Movement
| Key | Action |
|-----|--------|
| `Left Arrow` | Move cursor left |
| `Right Arrow` | Move cursor right |
| `Home` | Move to beginning of line |
| `End` | Move to end of line |

### History
| Key | Action |
|-----|--------|
| `Up Arrow` | Previous history / Previous match (if searching) |
| `Down Arrow` | Next history / Next match (if searching) |
| `Ctrl+R` | Reverse search (coming soon) |

### Completion
| Key | Action |
|-----|--------|
| `TAB` | Complete / Cycle through suggestions |
| `Esc` | Cancel completion |

## Quick Tips

### Tip 1: Fast Directory Navigation
```bash
# Instead of:
cd /usr/local/share/
# Type:
cd /u/l/s<TAB>
```

### Tip 2: Find Commands in History
```bash
# Instead of pressing Up repeatedly, type part of the command:
den> docker<Up>
# Instantly shows matching docker commands
```

### Tip 3: Cycle Through Suggestions
```bash
# Don't memorize paths - cycle through options:
cd Documents/<TAB><TAB><TAB>
# Cycles: Projects/ → Work/ → Personal/ → ...
```

### Tip 4: Complete Hidden Files
```bash
# Start with dot to show hidden files:
ls .<TAB>
# Shows: .bashrc  .gitignore  .config/
```

### Tip 5: Search by Arguments
```bash
# Find commands by their flags:
den> --verbose<Up>
# Shows all commands you ran with --verbose
```

## Feature Comparison with Other Shells

### vs Bash
| Feature | Bash | Den |
|---------|------|-----|
| Tab completion | ✓ | ✓ |
| Multiple suggestions | ✓ | ✓ with cycling |
| Mid-word expansion | ✗ | ✓ |
| History substring search | ✗ | ✓ |
| Lookahead path resolution | ✗ | ✓ |

### vs Zsh
| Feature | Zsh | Den |
|---------|-----|-----|
| Tab completion | ✓ | ✓ |
| Mid-word expansion | ✓ | ✓ |
| History substring search | ✓ (plugin) | ✓ (built-in) |
| Lookahead path resolution | ✓ | ✓ |
| Fuzzy matching | ✓ | Coming soon |
| Menu selection | ✓ | Coming soon |

### vs Fish
| Feature | Fish | Den |
|---------|------|-----|
| Tab completion | ✓ | ✓ |
| Auto-suggestions | ✓ | Coming soon |
| Syntax highlighting | ✓ | Coming soon |
| History search | ✓ | ✓ |

## Common Workflows

### Workflow 1: Exploring a New Project
```bash
# Navigate quickly
cd /u/l/s/app/j<TAB>  → cd /usr/local/share/applications/java/

# List what's there
ls <TAB>
# Cycle through suggestions to explore

# Open files
vim sr<TAB>  → vim src/
```

### Workflow 2: Repeating Commands
```bash
# Find that complex docker command
den> docker run<Up>
# Cycle through previous docker run commands

# Find by specific flag
den> --name myapp<Up>
# Shows commands with --name myapp
```

### Workflow 3: File Operations
```bash
# Quick copy with completion
cp ~/D/P/d/R<TAB>  →  cp ~/Documents/Projects/den/README.md

# Move with abbreviation
mv /t/d/f<TAB> ./  →  mv /tmp/downloads/file.txt ./
```

## Environment

### Current Directory
```bash
pwd                  # Print working directory
cd -                # Go to previous directory
cd ~                # Go to home directory
cd                  # Go to home directory (same as cd ~)
```

### Path Completion Contexts

Den knows what to complete based on command:
```bash
cd <TAB>            # Only directories
ls <TAB>            # Files and directories
cat <TAB>           # Files and directories
mkdir <TAB>         # No completion (you're creating a new dir)
```

## Advanced Examples

### Example 1: Complex Path Navigation
```bash
# Navigate to deep directory in one step
cd /u/l/s/f/t/d/c<TAB>
# Expands to: /usr/local/share/fonts/truetype/dejavu/confavail/
```

### Example 2: Finding Old Commands
```bash
# You remember running a curl command with specific headers
den> Content-Type<Up>
# Shows: curl -H "Content-Type: application/json" ...
```

### Example 3: Exploring Command Options
```bash
# What git commands have I used?
git <TAB>
# Shows all git subcommands

# Cycle through to remind yourself
git <TAB><TAB><TAB>
# Cycles through: status → commit → push → pull → ...
```

## Customization (Coming Soon)

Future configuration options:
```bash
# ~/.den/config.json (planned)
{
  "completion": {
    "style": "cycle",           # or "menu"
    "columns": 4,               # columns in suggestion list
    "case_sensitive": false,    # case-insensitive completion
    "fuzzy_match": true,        # fuzzy path matching
    "show_hidden": false        # show hidden files by default
  },
  "history": {
    "substring_search": true,   # enable substring search
    "case_sensitive": false,    # case-insensitive search
    "max_entries": 10000        # history size
  }
}
```

## Troubleshooting

### Completion not working?
1. Type more characters to narrow down options
2. Check file/directory permissions
3. Verify path exists: `ls /u/l/b`

### History search not finding commands?
1. Check spelling (search is case-sensitive)
2. Make sure command is in history: `history | grep docker`
3. Verify substring exists in command

### Mid-word expansion not working?
1. Path must be unique through all segments
2. Test with: `den complete "/u/l/b"`
3. Check directory permissions

## Learn More

- **[Tab Completion](TAB_COMPLETION.md)** - Complete guide to interactive completion
- **[Mid-Word Completion](MID_WORD_COMPLETION.md)** - Path abbreviation deep dive
- **[History Substring Search](HISTORY_SUBSTRING_SEARCH.md)** - History navigation guide
- **[Usage Guide](usage.md)** - General usage documentation

## Cheat Sheet Summary

**Most Useful Commands:**
```bash
# TAB completion
<text><TAB>              Complete current word
<TAB><TAB>...            Cycle through suggestions

# Path abbreviation
/u/l/b<TAB>              Expand to /usr/local/bin/

# History search
<text><Up>               Search history for text
<Down>                   Next match / Return to query

# Line editing
Ctrl+A / Ctrl+E          Start / End of line
Ctrl+U / Ctrl+K          Clear before / after cursor
Ctrl+W                   Delete previous word
Ctrl+L                   Clear screen
Ctrl+C                   Cancel line

# Navigation
Up / Down                History navigation
Left / Right             Cursor movement
```

**Remember:**
- TAB is your friend - use it everywhere!
- Type less, complete more
- Search history by substring, not just prefix
- Path abbreviations save keystrokes

---

**Pro Tip:** The fastest way to learn is to use Tab and Up Arrow constantly. You'll discover features naturally!
