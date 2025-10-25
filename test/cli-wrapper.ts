#!/usr/bin/env -S bun run
// Test wrapper that bypasses test environment checks
import process from 'node:process'
import { CAC } from 'cac'
import { version } from '../package.json'
import { config as defaultConfig, loadKrustyConfig } from '../src/config'
import { KrustyShell } from '../src/shell/index'

// Note: Removed test environment check for e2e testing

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
      await shell.start()
    }
  })

// Execute a single command
cli
  .command('exec <command>', 'Execute a single command')
  .option('--verbose', 'Enable verbose logging')
  .option('--config <config>', 'Path to config file')
  .action(async (command: string, options: CliOptions) => {
    const cfg = await loadKrustyConfig({ path: options.config })
    const base = { ...defaultConfig, ...cfg }
    const shell = new KrustyShell({ ...base, verbose: options.verbose ?? base.verbose })
    const result = await shell.execute(command)

    if (!result.streamed) {
      if (result.stdout)
        process.stdout.write(result.stdout)
      if (result.stderr)
        process.stderr.write(result.stderr)
    }

    process.exit(result.exitCode)
  })

cli.help()
cli.version(version)
cli.parse()