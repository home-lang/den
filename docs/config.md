# Configuration

Krusty is configured via a `krusty.config.ts` (or `.js`) file. This page highlights key options, with emphasis on system modules now driven by centralized configuration.

## Quick start

```ts
import type { KrustyConfig } from 'krusty/src/types'

const config: KrustyConfig = {
  prompt: { format: '{user}@{host} {path}{git} {modules} {symbol} ' },
  modules: {
    os: {
      enabled: false,
      format: 'on {symbol} {name}',
      symbol: '💻',
      symbols: { darwin: '', linux: '🐧', win32: '🪟' },
    },
    hostname: { enabled: true, format: '@{hostname}', ssh_only: true, showOnLocal: false },
    username: { enabled: true, format: '{username}', show_always: false, showOnLocal: false, root_format: '{username}' },
    directory: { enabled: true, format: '{path}', truncation_length: 3, truncate_to_repo: true, home_symbol: '~', readonly_symbol: '🔒' },
    battery: {
      enabled: true,
      format: '{symbol} {percentage}%',
      // Legacy keys still supported
      full_symbol: '🔋',
      charging_symbol: '🔌',
      discharging_symbol: '🔋',
      unknown_symbol: '🔋',
      empty_symbol: '🪫',
      // New unified keys
      symbol: '🔋',
      symbol_charging: '🔌',
      symbol_low: '🪫',
    },
    cmd_duration: { enabled: true, format: 'took {duration}', min_time: 2000, min_ms: 2000, show_milliseconds: false },
    time: { enabled: false, format: '{symbol} {time}', symbol: '🕐', locale: undefined, options: { hour: '2-digit', minute: '2-digit' } },
    memory_usage: { enabled: false, format: '🐏 {ram}', threshold: 75, symbol: '🐏' },
    nix_shell: { enabled: true, format: 'via {symbol} {state}', symbol: '❄️' },
  },
}

export default config
```

## Placeholders

Most module `format` strings accept placeholders. Common ones:

- `os`: {symbol}, {name}
- `hostname`: {hostname}
- `username`: {username}
- `directory`: {path}
- `battery`: {symbol}, {percentage}
- `cmd_duration`: {duration}
- `time`: {symbol}, {time}
- `nix_shell`: {symbol}, {state}

## Backward compatibility

Legacy keys like `battery.full_symbol`, `cmd_duration.min_time`, and `time: '🕐 {time}'` remain supported. The new unified keys and formats provide a single source of truth while preserving existing configs.

## Tips

- Symbols and colors are theme-driven; modules avoid hardcoded colors.
- You can override per-platform OS symbols via `os.symbols`.
- Set `hostname.showOnLocal`/`username.showOnLocal` to show/hide on local sessions.
