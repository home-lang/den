#!/usr/bin/env -S bun run
import process from 'node:process'
import { CAC } from 'cac'
import { version } from '../package.json'
import { config as defaultConfig, loadKrustyConfig } from '../src/config'
import { KrustyShell } from '../src/shell/index'

// Skip CLI execution during tests to prevent hanging
if (process.env.NODE_ENV === 'test' || process.env.BUN_ENV === 'test') {
  process.exit(0)
}

const cli = new CAC('krusty')

interface CliOptions {
  verbose?: boolean
  config?: string
}

// Default command - start the shell
cli
  .command('[...args]', 'Start the krusty shell', {
    allowUnknownOptions: true,
    ignoreOptionDefaultValue: true,
  })
  .option('--verbose', 'Enable verbose logging')
  .option('--config <config>', 'Path to config file')
  .action(async (args: string[], options: CliOptions) => {
    const cfg = await loadKrustyConfig({ path: options.config })
    const base = { ...defaultConfig, ...cfg }
    // Terminals may pass shell-style flags (e.g., -l). Ignore leading dash args for command execution
    const nonFlagArgs = args.filter(a => !(a?.startsWith?.('-')))
    // If non-flag arguments are provided, execute them as a command
    if (nonFlagArgs.length > 0) {
      const shell = new KrustyShell({ ...base, verbose: options.verbose ?? base.verbose })
      const command = nonFlagArgs.join(' ')
      const result = await shell.execute(command)

      if (!result.streamed) {
        if (result.stdout)
          process.stdout.write(result.stdout)
        if (result.stderr)
          process.stderr.write(result.stderr)
      }

      process.exit(result.exitCode)
    }
    else {
      // Start interactive shell
      const shell = new KrustyShell({ ...base, verbose: options.verbose ?? base.verbose })

      // Startup timestamp (configurable)
      const tsCfg = base.prompt?.startupTimestamp
      if (tsCfg?.enabled !== false) {
        const now = new Date()
        const locale = tsCfg?.locale
        const options: any = tsCfg?.options || { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
        const stamp = locale ? now.toLocaleString(locale, options) : now.toLocaleString(undefined, options)
        const label = tsCfg?.label ? `${tsCfg.label} ` : ''
        process.stdout.write(`${label}${stamp}\n`)
      }

      // Graceful shutdown handlers
      const onSigint = async () => {
        try {
          shell.stop()
        }
        finally {
          process.stdout.write('\n')
          process.exit(130) // 128 + SIGINT
        }
      }
      const onSigterm = async () => {
        try {
          shell.stop()
        }
        finally {
          process.exit(143) // 128 + SIGTERM
        }
      }
      process.on('SIGINT', onSigint)
      process.on('SIGTERM', onSigterm)

      try {
        await shell.start()
      }
      catch (err: any) {
        process.stderr.write(`Shell error: ${err?.message ?? String(err)}\n`)
        process.exitCode = 1
      }
      finally {
        process.off('SIGINT', onSigint)
        process.off('SIGTERM', onSigterm)
      }
    }
  })

// Dev setup command: create a shim pointing to the local source (bin/cli.ts)
cli
  .command('dev-setup', 'Create a dev shim that executes this repo\'s source (bin/cli.ts)')
  .option('--prefix <path>', 'Install prefix for the shim (defaults to ~/.local/bin on Unix)')
  .option('--name <name>', 'Shim file name', { default: 'krusty' })
  .option('--no-backup', 'Do not create a .bak backup if target exists')
  .example('krusty dev-setup')
  .example('krusty dev-setup --prefix ~/bin --name krusty')
  .action(async (options: { prefix?: string, name?: string, noBackup?: boolean }) => {
    try {
      const isWindows = process.platform === 'win32'
      const { homedir } = await import('node:os')
      const { join } = await import('node:path')
      const { writeFileSync, chmodSync, mkdirSync, renameSync, existsSync } = await import('node:fs')
      const { fileURLToPath } = await import('node:url')

      // Resolve source path to this file (bin/cli.ts)
      const thisFile = fileURLToPath(import.meta.url)
      const srcCli = thisFile // absolute path to bin/cli.ts when run via `bun run`

      // Determine install prefix
      let prefix = options.prefix
      if (!prefix) {
        if (isWindows) {
          prefix = join(homedir(), 'AppData', 'Local', 'krusty')
        }
        else {
          prefix = join(homedir(), '.local', 'bin')
        }
      }

      // Ensure directory exists
      try {
        mkdirSync(prefix, { recursive: true })
      }
      catch {}

      const name = options.name || 'krusty'
      const target = join(prefix, name)

      // Backup existing target unless --no-backup
      if (existsSync(target) && options.noBackup !== true) {
        const ts = new Date().toISOString().replace(/[:.]/g, '-')
        const backup = `${target}.bak-${ts}`
        try {
          renameSync(target, backup)
        }
        catch {}
        process.stdout.write(`Backed up existing ${name} to ${backup}\n`)
      }

      if (isWindows) {
        // Write a .bat shim next to target, and also write target without extension for convenience
        const batPath = `${target}.bat`
        const batScript = `@echo off\r\n`
          + `setlocal enabledelayedexpansion\r\n`
          + `"%~dp0\\..\\..\\bun\\bun.exe" run "${srcCli}" %*\r\n`
        writeFileSync(batPath, batScript)
        // Also write a PowerShell shim
        const ps1Path = `${target}.ps1`
        const ps1Script = `#!/usr/bin/env pwsh\n& bun run \"${srcCli}\" $args\n`
        writeFileSync(ps1Path, ps1Script)
        process.stdout.write(`Installed Windows dev shims: ${batPath} and ${ps1Path}\n`)
      }
      else {
        // POSIX shell shim
        const shim = `#!/bin/sh\n`
          + `# Krusty dev shim -> ${srcCli}\n`
          + `exec bun run "${srcCli}" "$@"\n`
        writeFileSync(target, shim)
        try {
          chmodSync(target, 0o755)
        }
        catch {}
        process.stdout.write(`Installed dev shim: ${target}\n`)
        process.stdout.write(`It will execute: bun run ${srcCli}\n`)
        process.stdout.write(`Ensure ${prefix} is in your PATH (e.g., export PATH=\"${prefix}:$PATH\").\n`)
      }
    }
    catch (err: any) {
      process.stderr.write(`dev-setup error: ${err?.message ?? String(err)}\n`)
      process.exit(1)
    }
  })

// Print completions (debug utility)
cli
  .command('complete <input>', 'Print JSON of completions for given input (optional [cursor])')
  .option('--cursor <n>', 'Cursor position within input (defaults to input length)')
  .option('--verbose', 'Enable verbose logging')
  .option('--config <config>', 'Path to config file')
  .action(async (inputText: string, options: CliOptions & { cursor?: string }) => {
    try {
      const cfg = await loadKrustyConfig({ path: options.config })
      const base = { ...defaultConfig, ...cfg }
      const shell = new KrustyShell({ ...base, verbose: options.verbose ?? base.verbose })
      // Ensure plugins are loaded so plugin completions are available
      await shell.loadPlugins()
      const cursor = (options.cursor != null && options.cursor !== '')
        ? Math.max(0, Math.min(inputText.length, Number.parseInt(String(options.cursor), 10) || 0))
        : inputText.length
      const completions = shell.getCompletions(inputText, cursor)
      process.stdout.write(`${JSON.stringify(completions, null, 2)}\n`)
      process.exit(0)
    }
    catch (err: any) {
      process.stderr.write(`complete error: ${err?.message ?? String(err)}\n`)
      process.exit(1)
    }
  })

// Explicit shell command
cli
  .command('shell', 'Start the interactive shell')
  .option('--verbose', 'Enable verbose logging')
  .option('--config <config>', 'Path to config file')
  .action(async (options: CliOptions) => {
    const cfg = await loadKrustyConfig({ path: options.config })
    const base = { ...defaultConfig, ...cfg }
    const shell = new KrustyShell({ ...base, verbose: options.verbose ?? base.verbose })

    // Startup timestamp (configurable)
    const tsCfg = base.prompt?.startupTimestamp
    if (tsCfg?.enabled !== false) {
      const now = new Date()
      const locale = tsCfg?.locale
      const options: any = tsCfg?.options || { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
      const stamp = locale ? now.toLocaleString(locale, options) : now.toLocaleString(undefined, options)
      const label = tsCfg?.label ? `${tsCfg.label} ` : ''
      process.stdout.write(`${label}${stamp}\n`)
    }

    const onSigint = async () => {
      try {
        shell.stop()
      }
      finally {
        process.stdout.write('\n')
        process.exit(130)
      }
    }
    const onSigterm = async () => {
      try {
        shell.stop()
      }
      finally {
        process.exit(143)
      }
    }
    process.on('SIGINT', onSigint)
    process.on('SIGTERM', onSigterm)

    try {
      await shell.start()
    }
    catch (err: any) {
      process.stderr.write(`Shell error: ${err?.message ?? String(err)}\n`)
      process.exitCode = 1
    }
    finally {
      process.off('SIGINT', onSigint)
      process.off('SIGTERM', onSigterm)
    }
  })

// Execute a single command
cli
  .command('exec <command>', 'Execute a single command')
  .option('--verbose', 'Enable verbose logging')
  .option('--config <config>', 'Path to config file')
  .action(async (command: string, options: CliOptions) => {
    if (process.env.KRUSTY_DEBUG) {
      console.error(`[DEBUG] CLI exec called with command: "${command}"`)
    }

    const cfg = await loadKrustyConfig({ path: options.config })
    const base = { ...defaultConfig, ...cfg }
    const shell = new KrustyShell({ ...base, verbose: options.verbose ?? base.verbose })

    if (process.env.KRUSTY_DEBUG) {
      console.error(`[DEBUG] Shell created, calling execute...`)
    }

    const result = await shell.execute(command)

    if (process.env.KRUSTY_DEBUG) {
      console.error(`[DEBUG] Execute result:`, result)
    }

    if (!result.streamed) {
      if (result.stdout)
        process.stdout.write(result.stdout)
      if (result.stderr)
        process.stderr.write(result.stderr)
    }

    process.exit(result.exitCode)
  })

// Set as default shell
cli
  .command('set-shell', 'Set Krusty as the default shell')
  .action(async () => {
    const shellPath = process.argv[1] // Path to current script
    const isWindows = process.platform === 'win32'

    if (isWindows) {
      // Windows implementation
      process.stdout.write('Setting Krusty as default shell on Windows...\n')
      // On Windows, we need to modify the registry
      try {
        const { execSync } = await import('node:child_process')
        const { homedir } = await import('node:os')
        const { writeFileSync } = await import('node:fs')

        // Create a .bat file to launch Krusty
        const batPath = `${homedir()}/krusty_shell.bat`
        writeFileSync(batPath, `@echo off\n"${process.execPath}" "${shellPath}" %*`)

        // Set the registry to use our .bat file
        execSync(`reg add "HKCU\\Software\\Microsoft\\Command Processor" /v "AutoRun" /d "${batPath}" /f`)
        process.stdout.write('Success! Krusty is now your default shell on Windows.\n')
        process.stdout.write('You may need to restart your terminal for changes to take effect.\n')
      }
      catch {
        process.stderr.write('Failed to set Krusty as default shell. Please run as administrator.\n')
        process.exit(1)
      }
    }
    else {
      // Unix-like systems (macOS, Linux)
      process.stdout.write('Setting Krusty as default shell...\n')
      try {
        const { writeFileSync, chmodSync } = await import('node:fs')
        const { execSync } = await import('node:child_process')

        // Create a wrapper script
        const wrapperPath = '/usr/local/bin/krusty-shell'
        const wrapperScript = `#!/bin/sh\nexec "${process.execPath}" "${shellPath}" "$@"\n`

        // Write the wrapper script
        writeFileSync(wrapperPath, wrapperScript)
        chmodSync(wrapperPath, 0o755) // Make it executable

        // Add to /etc/shells if not already present
        execSync(`grep -qF '${wrapperPath}' /etc/shells || echo '${wrapperPath}' | sudo tee -a /etc/shells`)

        // Change the shell
        execSync(`chsh -s ${wrapperPath} ${process.env.USER}`)

        process.stdout.write('Success! Krusty is now your default shell.\n')
        process.stdout.write('You may need to log out and log back in for changes to take effect.\n')
      }
      catch {
        process.stderr.write('Failed to set Krusty as default shell. You may need to run with sudo.\n')
        process.exit(1)
      }
    }
  })

// Setup command: install wrapper, optionally register and set as default shell
cli
  .command('setup', 'Setup krusty (install wrapper; optionally set as default shell)')
  .option('--prefix <path>', 'Install prefix for the wrapper (defaults to /usr/local/bin or ~/.local/bin)')
  .option('--no-chsh', 'Install wrapper only; do not change the login shell')
  .example('krusty setup --prefix /usr/local/bin --no-chsh')
  .action(async (options: { prefix?: string, noChsh?: boolean }) => {
    const isWindows = process.platform === 'win32'
    const shellPath = process.argv[1]

    if (isWindows) {
      process.stdout.write('Setup on Windows will configure a launcher; setting default shell depends on terminal.\n')
      try {
        const { writeFileSync } = await import('node:fs')
        const { homedir } = await import('node:os')
        const batPath = `${homedir()}/krusty_shell.bat`
        writeFileSync(batPath, `@echo off\n"${process.execPath}" "${shellPath}" %*`)
        process.stdout.write(`Installed Windows launcher at: ${batPath}\n`)
        process.stdout.write('Configure your terminal profile to use this launcher.\n')
      }
      catch (err: any) {
        process.stderr.write(`Failed to write launcher: ${err?.message ?? String(err)}\n`)
        process.exit(1)
      }
      return
    }

    process.stdout.write('Setting up krusty on this system...\n')
    try {
      const { writeFileSync, chmodSync, mkdirSync } = await import('node:fs')
      const { execSync } = await import('node:child_process')
      const { join } = await import('node:path')
      const { homedir } = await import('node:os')

      // Determine install prefix
      let prefix = options.prefix
      const candidates = ['/usr/local/bin', '/opt/homebrew/bin']
      if (!prefix) {
        prefix = candidates.find((p) => {
          try {
            execSync(`[ -d "${p}" ] && [ -w "${p}" ] && echo ok`)
            return true
          }
          catch {
            return false
          }
        }) || join(homedir(), '.local', 'bin')
      }

      // Ensure directory exists
      try {
        mkdirSync(prefix, { recursive: true })
      }
      catch {}

      const wrapperPath = join(prefix, 'krusty')
      const wrapperScript = `#!/bin/sh\nSHELL="${wrapperPath}"\nexport SHELL\nexec "${process.execPath}" "${shellPath}" "$@"\n`
      writeFileSync(wrapperPath, wrapperScript)
      chmodSync(wrapperPath, 0o755)
      process.stdout.write(`Installed wrapper: ${wrapperPath}\n`)

      // Register as a valid login shell
      try {
        execSync(`grep -qF '${wrapperPath}' /etc/shells || echo '${wrapperPath}' | sudo tee -a /etc/shells > /dev/null`, { stdio: 'inherit' })
      }
      catch {
        process.stdout.write('\nNote: Could not add to /etc/shells automatically. Run this manually (may require sudo):\n')
        process.stdout.write(`  echo '${wrapperPath}' | sudo tee -a /etc/shells\n`)
      }

      // Change the user's login shell unless --no-chsh was provided
      const doChsh = options.noChsh !== true
      if (doChsh) {
        try {
          execSync(`chsh -s ${wrapperPath} ${process.env.USER}`, { stdio: 'inherit' })
          process.stdout.write('\nSuccess! krusty set as your default shell. Log out and back in to take effect.\n')
        }
        catch {
          process.stdout.write('\nNote: Could not change login shell automatically. Run manually:\n')
          process.stdout.write(`  chsh -s ${wrapperPath} ${process.env.USER}\n`)
        }
      }
      else {
        process.stdout.write('Wrapper installed. Skipping login shell change due to --no-chsh.\n')
      }
    }
    catch (err: any) {
      process.stderr.write(`setup error: ${err?.message ?? String(err)}\n`)
      process.exit(1)
    }
  })

// Version command
// Uninstall command: remove wrapper and clean up
cli
  .command('uninstall', 'Uninstall krusty wrapper and clean up system configuration')
  .option('--prefix <path>', 'Prefix where krusty wrapper was installed (defaults to /usr/local/bin or ~/.local/bin)')
  .action(async (options: { prefix?: string }) => {
    const isWindows = process.platform === 'win32'

    if (isWindows) {
      process.stdout.write('Windows uninstall:\n')
      process.stdout.write('1. Delete the krusty_shell.bat file from your home directory\n')
      process.stdout.write('2. Remove any terminal profiles that reference krusty\n')
      return
    }

    process.stdout.write('Uninstalling krusty...\n')
    try {
      const { unlinkSync } = await import('node:fs')
      const { execSync } = await import('node:child_process')
      const { join } = await import('node:path')
      const { homedir } = await import('node:os')

      // Determine install prefix
      let prefix = options.prefix
      const candidates = ['/usr/local/bin', '/opt/homebrew/bin']
      if (!prefix) {
        prefix = candidates.find((p) => {
          try {
            execSync(`[ -f "${p}/krusty" ] && echo ok`)
            return true
          }
          catch {
            return false
          }
        }) || join(homedir(), '.local', 'bin')
      }

      const wrapperPath = join(prefix, 'krusty')

      // Remove wrapper script
      try {
        unlinkSync(wrapperPath)
        process.stdout.write(`Removed wrapper script: ${wrapperPath}\n`)
      }
      catch (err: any) {
        if (err.code !== 'ENOENT') {
          throw err
        }
        process.stdout.write(`No wrapper script found at ${wrapperPath}\n`)
      }

      // Remove from /etc/shells if present
      try {
        execSync(`grep -qF '${wrapperPath}' /etc/shells && sudo sed -i '' '\|${wrapperPath}|d' /etc/shells`, { stdio: 'pipe' })
        process.stdout.write('Removed from /etc/shells\n')
      }
      catch {
        // Ignore errors - might not be in /etc/shells or no permissions
      }

      // Check if current shell is krusty
      try {
        const currentShell = execSync('getent passwd $LOGNAME | cut -d: -f7').toString().trim()
        if (currentShell.includes('krusty')) {
          process.stdout.write('\nWARNING: Your current login shell is still set to krusty.\n')
          process.stdout.write('To change it back to bash, run:\n')
          process.stdout.write('  chsh -s /bin/bash\n')
          process.stdout.write('Or specify another shell like /bin/zsh or /bin/fish\n')
        }
      }
      catch {
        // Ignore errors from getent/chsh check
      }

      process.stdout.write('\nUninstall complete. You may need to log out and back in for all changes to take effect.\n')
    }
    catch (err: any) {
      process.stderr.write(`Uninstall error: ${err?.message ?? String(err)}\n`)
      process.exit(1)
    }
  })

// Version command
cli.command('version', 'Show the version').action(() => {
  process.stdout.write(`${version}\n`)
})

cli.version(version)
cli.help()
cli.parse()
