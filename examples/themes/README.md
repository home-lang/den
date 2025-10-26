# Den Shell Theme Examples

This directory contains example themes demonstrating how to customize Den Shell's appearance.

## Available Themes

### 1. default.jsonc
**Description:** Balanced theme with good readability and modern colors.

**Best for:** General use, balanced aesthetics

**Features:**
- One Dark inspired color scheme
- Clear visual hierarchy
- Git status colors
- Module indicators

**Preview:**
```
user@host ~/projects/den main ✗ ➜
```

### 2. minimal.jsonc
**Description:** Clean, distraction-free theme optimized for focus.

**Best for:** Minimal distractions, fast rendering, low-resource systems

**Features:**
- Monochrome color scheme
- Simple prompt format
- Minimal visual elements
- Fast rendering

**Preview:**
```
~/projects/den ❯
```

### 3. powerline.jsonc
**Description:** Powerline-inspired theme with segment-based design.

**Best for:** Visual information density, status monitoring

**Features:**
- Segment-based prompt
- Powerline symbols
- Background colors for segments
- Status indicators

**Preview:**
```
┌─  user  host  ~/projects/den  main ✗
└─ ➜
```

### 4. ocean.jsonc
**Description:** Cool blue ocean-inspired color palette.

**Best for:** Night coding, reduced eye strain

**Features:**
- Blue/cyan color scheme
- Calm, easy on eyes
- Subtle contrast
- Wave-inspired symbols

**Preview:**
```
╭─ user@host ~/projects/den ≋ main ✗
╰─➤
```

### 5. tokyo-night.jsonc
**Description:** Tokyo Night color scheme - popular dark theme.

**Best for:** Modern aesthetics, high contrast

**Features:**
- Tokyo Night colors
- High contrast
- Vibrant accents
- Modern symbols

**Preview:**
```
 user@host  ~/projects/den  main ✗  ➜
```

### 6. gruvbox.jsonc
**Description:** Gruvbox color scheme - warm retro groove.

**Best for:** Warm color preference, retro aesthetics

**Features:**
- Gruvbox color palette
- Warm, earthy tones
- Good contrast
- Comfortable for long sessions

**Preview:**
```
[user@host] ~/projects/den (main ✗) $
```

## Theme Structure

Themes are defined in JSONC format with the following structure:

```jsonc
{
  "theme": {
    "name": "theme-name",
    "colorScheme": "dark",  // or "light" or "auto"

    "colors": {
      // Base colors
      "primary": "#61afef",
      "secondary": "#98c379",
      "background": "#282c34",
      "foreground": "#abb2bf",

      // Semantic colors
      "success": "#98c379",
      "warning": "#e5c07b",
      "error": "#e06c75",
      "info": "#56b6c2",

      // UI elements
      "prompt": "#61afef",
      "command": "#abb2bf",
      "comment": "#5c6370",
      "selection": "#3e4451"
    },

    "prompt": {
      "template": "{user}@{host} {cwd} {git_branch} {symbol} ",
      "symbols": {
        "success": "➜",
        "error": "✗",
        "root": "#"
      }
    },

    "syntax": {
      "command": "primary",
      "argument": "foreground",
      "flag": "info",
      "string": "success",
      "number": "warning",
      "operator": "secondary",
      "comment": "comment",
      "error": "error"
    },

    "git": {
      "clean": "success",
      "dirty": "warning",
      "conflict": "error",
      "ahead": "info",
      "behind": "warning"
    }
  }
}
```

## Using Themes

### Method 1: Reference by Name
```jsonc
{
  "theme": {
    "name": "ocean"
  }
}
```

### Method 2: Inline Theme
```jsonc
{
  "theme": {
    "name": "custom",
    "colors": {
      "primary": "#your-color",
      // ... your custom colors
    }
  }
}
```

### Method 3: Extend Existing Theme
```jsonc
{
  "theme": {
    "extends": "ocean",
    "colors": {
      "primary": "#custom-color"  // Override specific colors
    }
  }
}
```

## Color Format

Colors can be specified in multiple formats:

- **Hex:** `#61afef` or `#61afef80` (with alpha)
- **RGB:** `rgb(97, 175, 239)`
- **RGBA:** `rgba(97, 175, 239, 0.5)`
- **Named:** `blue`, `red`, `green`, etc.
- **ANSI:** `ansi(34)` for ANSI color codes

## Dynamic Colors

Themes support dynamic colors based on context:

```jsonc
{
  "theme": {
    "colors": {
      "prompt": {
        "default": "#61afef",
        "error": "#e06c75",
        "root": "#e5c07b"
      }
    }
  }
}
```

## Color Scheme Auto-Detection

Set `colorScheme: "auto"` to automatically detect light/dark mode:

```jsonc
{
  "theme": {
    "colorScheme": "auto",
    "colors": {
      "light": {
        "primary": "#0184bc"
      },
      "dark": {
        "primary": "#61afef"
      }
    }
  }
}
```

## Creating Custom Themes

1. **Choose a Base Color Palette**
   - Pick 5-7 base colors
   - Ensure good contrast ratios
   - Test in different lighting conditions

2. **Define Semantic Colors**
   - success: operations that completed successfully
   - warning: cautions or non-critical issues
   - error: failures or critical issues
   - info: informational messages

3. **Configure Syntax Highlighting**
   - Map syntax elements to your colors
   - Test with various commands
   - Ensure readability

4. **Customize Prompt**
   - Choose appropriate symbols
   - Balance information density
   - Consider prompt length

5. **Test Extensively**
   - Test in different terminals
   - Check color support (16/256/truecolor)
   - Verify in light and dark environments
   - Test with colorblindness simulators

## Terminal Compatibility

### True Color (24-bit)
Most modern terminals support true color:
- iTerm2
- Alacritty
- WezTerm
- Windows Terminal
- GNOME Terminal (3.x+)
- Konsole

### 256 Colors
Den Shell automatically downgrades for 256-color terminals:
- tmux (with `set -g default-terminal "screen-256color"`)
- screen
- xterm-256color

### 16 Colors
Basic fallback for limited terminals:
- Linux console
- Basic xterm
- SSH sessions with color limitations

## Theme Best Practices

1. **Accessibility**
   - Maintain WCAG 2.1 AA contrast ratios (4.5:1 minimum)
   - Test with colorblindness simulators
   - Provide clear visual distinctions

2. **Performance**
   - Avoid excessive color changes
   - Cache color calculations
   - Use ANSI codes efficiently

3. **Consistency**
   - Use colors semantically
   - Maintain visual hierarchy
   - Keep related elements similar

4. **Context**
   - Consider terminal background
   - Test in different lighting
   - Provide light/dark variants

## Resources

- [Color Picker](https://colorpicker.me/)
- [Contrast Checker](https://webaim.org/resources/contrastchecker/)
- [Colorblind Simulator](https://www.color-blindness.com/coblis-color-blindness-simulator/)
- [Terminal Color Schemes](https://terminal.sexy/)
- [ANSI Escape Codes](https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797)

## Contributing Themes

To contribute a theme to Den Shell:

1. Create your theme file in `examples/themes/`
2. Add preview and description to this README
3. Test on multiple terminals
4. Verify accessibility standards
5. Submit a pull request

## Popular Color Schemes to Port

- Dracula
- Nord
- Solarized
- Monokai
- Material
- Atom One Dark/Light
- Ayu
- Palenight
- Horizon
