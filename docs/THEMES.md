# Themes

Den Shell includes a comprehensive theming system with pre-built theme packs inspired by popular color schemes.

## Table of Contents

- [Overview](#overview)
- [Available Themes](#available-themes)
- [Using Themes](#using-themes)
- [Theme Structure](#theme-structure)
- [Creating Custom Themes](#creating-custom-themes)

---

## Overview

The Den theming system allows you to customize the visual appearance of your shell, including:

- **Prompt colors**: User, host, current directory, Git status
- **Syntax highlighting**: Commands, keywords, strings, variables
- **File type colors**: Different colors for directories, executables, symlinks, etc.
- **UI elements**: Borders, selections, completion menus
- **Git integration**: Branch names, status indicators

All themes are defined in JSONC (JSON with Comments) format for easy customization.

---

## Available Themes

### Dracula

A dark theme with vibrant colors inspired by the official Dracula color palette.

**Preview:**
```
User: Bright Green (#b8bb26)
Host: Bright Cyan (#8be9fd)
Directory: Purple (#bd93f9)
Git Branch: Pink (#ff79c6)
```

**File location:** `examples/themes/dracula.jsonc`

**Best for:** Developers who prefer vibrant, high-contrast colors

---

### Solarized Dark

Precision colors for machines and people by Ethan Schoonover. The Solarized Dark variant provides excellent readability with carefully balanced hues.

**Preview:**
```
User: Green (#859900)
Host: Blue (#268bd2)
Directory: Cyan (#2aa198)
Git Branch: Magenta (#d33682)
```

**File location:** `examples/themes/solarized-dark.jsonc`

**Best for:** Long coding sessions, reduces eye strain

---

### Solarized Light

Light variant of the Solarized theme. Perfect for bright environments.

**Preview:**
```
Background: Light (#fdf6e3)
Foreground: Dark (#657b83)
Accent colors: Same as Solarized Dark
```

**File location:** `examples/themes/solarized-light.jsonc`

**Best for:** Daytime work, well-lit environments

---

### Nord

An arctic, north-bluish color palette that provides a clean and modern look.

**Preview:**
```
User: Green (#a3be8c)
Host: Bright Cyan (#88c0d0)
Directory: Blue (#81a1c1)
Git Branch: Purple (#b48ead)
Background: Dark Blue (#2e3440)
```

**File location:** `examples/themes/nord.jsonc`

**Best for:** Minimalist aesthetic, cool color preferences

---

### One Dark

Atom's iconic One Dark theme, bringing the popular editor theme to your shell.

**Preview:**
```
User: Green (#98c379)
Host: Blue (#61afef)
Directory: Cyan (#56b6c2)
Git Branch: Purple (#c678dd)
Background: Dark (#282c34)
```

**File location:** `examples/themes/onedark.jsonc`

**Best for:** Atom/VSCode users, consistency across tools

---

### Gruvbox

Retro groove color scheme with pastel 'retro groove' colors.

**Preview:**
```
User: Bright Green (#b8bb26)
Host: Bright Blue (#83a598)
Directory: Bright Aqua (#8ec07c)
Git Branch: Bright Purple (#d3869b)
Background: Dark (#282828)
```

**File location:** `examples/themes/gruvbox.jsonc`

**Best for:** Warm, vintage aesthetic preferences

---

### Monokai

The legendary Monokai color scheme from TextMate and Sublime Text.

**Preview:**
```
User: Green (#a6e22e)
Host: Blue (#66d9ef)
Directory: Purple (#ae81ff)
Git Branch: Red (#f92672)
Background: Dark (#272822)
```

**File location:** `examples/themes/monokai.jsonc`

**Best for:** Sublime Text users, high contrast

---

### Additional Themes

- **Default**: Den's default theme with balanced colors
- **Minimal**: Clean, minimal theme with subtle colors
- **Ocean**: Ocean-inspired blues and greens
- **Powerline**: Designed for use with powerline fonts
- **Tokyo Night**: Inspired by the Tokyo Night color scheme

---

## Using Themes

### Applying a Theme

To use a theme, copy it to your Den configuration directory and reference it in your `den.jsonc`:

```bash
# Copy theme to config directory
cp examples/themes/dracula.jsonc ~/.config/den/themes/

# Edit den.jsonc
{
  "theme": "~/.config/den/themes/dracula.jsonc"
}
```

### Quick Theme Switching

You can also reference themes directly:

```jsonc
{
  "theme": "examples/themes/nord.jsonc"
}
```

### Hot Reloading

Changes to theme files are automatically detected and applied. Simply edit your theme file and the changes will appear in new shell sessions.

---

## Theme Structure

A theme file consists of several sections:

### Basic Information

```jsonc
{
  "theme": {
    "name": "Theme Name",
    "author": "Author Name",
    "description": "Theme description",

    // ... color definitions
  }
}
```

### Color Palette

Define your base colors:

```jsonc
"colors": {
  "background": "#282c34",
  "foreground": "#abb2bf",
  "red": "#e06c75",
  "green": "#98c379",
  "blue": "#61afef",
  // ... more colors
}
```

### Prompt Configuration

Customize your shell prompt:

```jsonc
"prompt": {
  "format": "{user}@{host}:{cwd} {git}$ ",
  "user_color": "#98c379",    // green
  "host_color": "#61afef",    // blue
  "cwd_color": "#56b6c2",     // cyan
  "git_color": "#c678dd",     // purple
  "prompt_char": "#abb2bf",   // foreground
  "error_color": "#e06c75"    // red
}
```

**Available prompt variables:**
- `{user}`: Current username
- `{host}`: Hostname
- `{cwd}`: Current working directory
- `{git}`: Git branch and status

### Syntax Highlighting

Define colors for different syntax elements:

```jsonc
"syntax": {
  "command": "#98c379",       // Valid commands
  "builtin": "#61afef",       // Built-in commands
  "keyword": "#c678dd",       // Keywords (if, then, else)
  "string": "#98c379",        // Strings
  "number": "#d19a66",        // Numbers
  "variable": "#e5c07b",      // Variables
  "comment": "#5c6370",       // Comments
  "operator": "#56b6c2",      // Operators
  "flag": "#61afef",          // Command flags
  "path": "#56b6c2",          // File paths
  "error": "#e06c75"          // Errors
}
```

### File Type Colors

Customize colors for different file types (used in `ls` command):

```jsonc
"file_types": {
  "directory": "#61afef",     // Directories
  "executable": "#98c379",    // Executable files
  "symlink": "#56b6c2",       // Symbolic links
  "archive": "#e5c07b",       // Archives (.zip, .tar, etc.)
  "image": "#c678dd",         // Images
  "video": "#c678dd",         // Videos
  "audio": "#d19a66",         // Audio files
  "document": "#abb2bf",      // Documents
  "code": "#61afef",          // Source code
  "hidden": "#5c6370"         // Hidden files
}
```

### UI Elements

Customize interface elements:

```jsonc
"ui": {
  "border": "#3b4048",
  "selection": "#3e4451",
  "cursor": "#528bff",
  "line_number": "#636d83",
  "status_bar_bg": "#21252b",
  "status_bar_fg": "#abb2bf",
  "error_bg": "#e06c75",
  "error_fg": "#282c34",
  "warning_bg": "#e5c07b",
  "warning_fg": "#282c34",
  "info_bg": "#61afef",
  "info_fg": "#282c34",
  "success_bg": "#98c379",
  "success_fg": "#282c34"
}
```

### Completion Menu

Customize the autocomplete menu:

```jsonc
"completion": {
  "background": "#21252b",
  "foreground": "#abb2bf",
  "selected_bg": "#2c313a",
  "selected_fg": "#abb2bf",
  "description": "#5c6370",
  "border": "#3b4048"
}
```

### Git Integration

Customize Git status colors:

```jsonc
"git": {
  "branch": "#c678dd",        // Branch name
  "clean": "#98c379",         // Clean working directory
  "dirty": "#e5c07b",         // Modified files
  "staged": "#56b6c2",        // Staged changes
  "conflict": "#e06c75",      // Merge conflicts
  "ahead": "#61afef",         // Ahead of remote
  "behind": "#d19a66"         // Behind remote
}
```

---

## Creating Custom Themes

### Step 1: Choose a Base

Start with an existing theme that's close to what you want:

```bash
cp examples/themes/dracula.jsonc ~/.config/den/themes/my-theme.jsonc
```

### Step 2: Customize Colors

Edit your theme file and modify the colors:

```jsonc
{
  "theme": {
    "name": "My Custom Theme",
    "author": "Your Name",
    "description": "My personalized theme",

    "colors": {
      "background": "#1e1e1e",
      "foreground": "#d4d4d4",
      // ... your custom colors
    },

    // ... other sections
  }
}
```

### Step 3: Color Formats

Colors can be specified in several formats:

```jsonc
"red": "#ff0000"        // Hex RGB
"green": "#00ff00"      // Hex RGB
"blue": "rgb(0,0,255)"  // RGB function (future support)
```

### Step 4: Test Your Theme

Apply your theme in `den.jsonc`:

```jsonc
{
  "theme": "~/.config/den/themes/my-theme.jsonc"
}
```

### Step 5: Share Your Theme

Consider contributing your theme to the Den community! Submit a pull request with your theme file in the `examples/themes/` directory.

---

## Best Practices

### Accessibility

- **Contrast**: Ensure sufficient contrast between foreground and background colors (WCAG AAA standard recommends 7:1 for normal text)
- **Color blindness**: Test your theme with color blindness simulators
- **Semantic colors**: Use consistent colors for similar elements (e.g., always use green for success)

### Performance

- **ANSI colors**: Prefer standard ANSI color codes when possible for better terminal compatibility
- **Fallbacks**: Provide fallback colors for terminals that don't support true color

### Consistency

- **Related elements**: Use similar hues for related elements
- **Hierarchy**: Use saturation and brightness to indicate importance
- **Balance**: Maintain visual balance across all UI elements

---

## Troubleshooting

### Theme Not Loading

1. Check that the theme file path is correct in `den.jsonc`
2. Verify the JSONC syntax is valid (no trailing commas, proper quotes)
3. Ensure the theme file has read permissions

### Colors Not Displaying

1. Verify your terminal supports 24-bit color (true color)
2. Check `$COLORTERM` environment variable: `echo $COLORTERM` should show "truecolor" or "24bit"
3. Test with a simple command: `printf '\033[38;2;255;0;0mRed Text\033[0m\n'`

### Git Colors Not Showing

1. Ensure Git is installed and accessible
2. Verify you're in a Git repository
3. Check that Git integration is enabled in `den.jsonc`

---

## See Also

- [Shell Configuration](./config.md)
- [Built-in Commands](./BUILTINS.md)
- [Plugin Development](./PLUGIN_DEVELOPMENT.md)
