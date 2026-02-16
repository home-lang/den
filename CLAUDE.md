# Claude Code Guidelines

## About

A modern POSIX-compliant shell written in Zig, delivering native performance with a ~1.8MB binary and ~5ms startup time (5-9x faster than bash/zsh/fish). It includes 54 built-in commands, pipelines, I/O redirection, job control, variable/command/arithmetic/brace/tilde/glob expansion, persistent history, tab completion, and aliases. Originally built with TypeScript/Bun, it was rewritten in Zig for zero runtime dependencies and minimal memory usage (~2MB idle).

## Linting

- Use **pickier** for linting — never use eslint directly
- Run `bunx --bun pickier .` to lint, `bunx --bun pickier . --fix` to auto-fix
- When fixing unused variable warnings, prefer `// eslint-disable-next-line` comments over prefixing with `_`

## Frontend

- Use **stx** for templating — never write vanilla JS (`var`, `document.*`, `window.*`) in stx templates
- Use **crosswind** as the default CSS framework which enables standard Tailwind-like utility classes
- stx `<script>` tags should only contain stx-compatible code (signals, composables, directives)

## Dependencies

- **buddy-bot** handles dependency updates — not renovatebot
- **better-dx** provides shared dev tooling as peer dependencies — do not install its peers (e.g., `typescript`, `pickier`, `bun-plugin-dtsx`) separately if `better-dx` is already in `package.json`
- If `better-dx` is in `package.json`, ensure `bunfig.toml` includes `linker = "hoisted"`

## Commits

- Use conventional commit messages (e.g., `fix:`, `feat:`, `chore:`)
