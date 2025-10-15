import type { KrustyConfig, Plugin } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { KrustyShell } from '../src'
import { PluginManager } from '../src/plugins/plugin-manager'

describe('Plugin System', () => {
  let shell: KrustyShell
  let pluginManager: PluginManager
  let tempDir: string
  let pluginPath: string

  beforeEach(() => {
    const config: KrustyConfig = {
      verbose: false,
      plugins: [],
      hooks: {},
    }

    shell = new KrustyShell(config)
    // Re-instantiate PluginManager before each test to ensure isolation
    pluginManager = new PluginManager(shell, config)

    // Create temporary directory for test plugin
    tempDir = mkdtempSync(join(tmpdir(), 'krusty-plugin-test-'))
    pluginPath = join(tempDir, 'test-plugin.js')

    // Write test plugin to file
    const pluginCode = `
      class TestPlugin {
        name = 'test-plugin'
        version = '1.0.0'
        description = 'A test plugin'

        commands = {
          hello: {
            description: 'Say hello',
            execute: async (args, context) => {
              const name = args[0] || 'World'
              return {
                exitCode: 0,
                stdout: \`Hello, \${name}!\\n\`,
                stderr: '',
                duration: 0
              }
            }
          }
        }

        async initialize(context) {
          context.logger.info('Test plugin initialized')
        }

        async activate(context) {
          context.logger.info('Test plugin activated')
        }

        async deactivate(context) {
          context.logger.info('Test plugin deactivated')
        }
      }

      module.exports = new TestPlugin()
    `

    writeFileSync(pluginPath, pluginCode)
  })

  afterEach(() => {
    if (tempDir) {
      rmSync(tempDir, { recursive: true, force: true })
    }
  })

  it('should load plugin from path', async () => {
    const pluginToLoad: Plugin = {
      name: 'test-plugin',
      path: pluginPath,
      enabled: true,
    }

    await pluginManager.loadPlugin(pluginToLoad)

    const plugin = pluginManager.getPlugin('test-plugin')
    expect(plugin).toBeDefined()
    expect(plugin?.name).toBe('test-plugin')
    expect(plugin?.version).toBe('1.0.0')
  })

  it('should register plugin commands', async () => {
    const pluginToLoad: Plugin = {
      name: 'test-plugin',
      path: pluginPath,
      enabled: true,
    }

    await pluginManager.loadPlugin(pluginToLoad)

    const plugin = pluginManager.getPlugin('test-plugin')
    expect(plugin).toBeDefined()
    expect(plugin?.commands?.hello).toBeDefined()
    expect(plugin?.commands?.hello.description).toBe('Say hello')
  })

  it('should execute plugin commands', async () => {
    const pluginToLoad: Plugin = {
      name: 'test-plugin',
      path: pluginPath,
      enabled: true,
    }

    await pluginManager.loadPlugin(pluginToLoad)

    const plugin = pluginManager.getPlugin('test-plugin')
    const context = pluginManager.getPluginContext('test-plugin')
    expect(plugin?.commands?.hello).toBeDefined()
    expect(context).toBeDefined()

    if (plugin?.commands?.hello && context) {
      const result = await plugin.commands.hello.execute(['krusty'], context)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('Hello, krusty!\n')
    }
  })

  it('should unload plugins', async () => {
    const pluginToLoad: Plugin = {
      name: 'test-plugin',
      path: pluginPath,
      enabled: true,
    }

    await pluginManager.loadPlugin(pluginToLoad)
    expect(pluginManager.getPlugin('test-plugin')).toBeDefined()

    await pluginManager.unloadPlugin('test-plugin')
    expect(pluginManager.getPlugin('test-plugin')).toBeUndefined()
  })

  it('should handle plugin loading errors', async () => {
    const pluginToLoad: Plugin = {
      name: 'invalid-plugin',
      path: '/nonexistent/path/plugin.js',
      enabled: true,
    }

    // Should not throw, but should log error and continue
    await pluginManager.loadPlugin(pluginToLoad)
    expect(pluginManager.getPlugin('invalid-plugin')).toBeUndefined()
  })

  it('should skip disabled plugins', async () => {
    const pluginToLoad: Plugin = {
      name: 'test-plugin',
      path: pluginPath,
      enabled: false,
    }

    const shellConfig: KrustyConfig = {
      verbose: false,
      plugins: [pluginToLoad],
      hooks: {},
    }

    // Use a new PluginManager instance for this specific test case
    const localPluginManager = new PluginManager(shell, shellConfig)
    await localPluginManager.loadPlugins()

    expect(localPluginManager.getPlugin('test-plugin')).toBeUndefined()
  })

  it('should provide plugin utilities', async () => {
    const pluginToLoad: Plugin = {
      name: 'test-plugin',
      path: pluginPath,
      enabled: true,
    }

    await pluginManager.loadPlugin(pluginToLoad)

    const context = pluginManager.getPluginContext('test-plugin')
    expect(context).toBeDefined()
    expect(context?.utils).toBeDefined()
    expect(typeof context?.utils.exec).toBe('function')
    expect(typeof context?.utils.readFile).toBe('function')
    expect(typeof context?.utils.writeFile).toBe('function')
    expect(typeof context?.utils.exists).toBe('function')
    expect(typeof context?.utils.expandPath).toBe('function')
    expect(typeof context?.utils.formatTemplate).toBe('function')
  })

  it('should provide plugin logger', async () => {
    const pluginToLoad: Plugin = {
      name: 'test-plugin',
      path: pluginPath,
      enabled: true,
    }

    await pluginManager.loadPlugin(pluginToLoad)

    const context = pluginManager.getPluginContext('test-plugin')
    expect(context).toBeDefined()
    expect(context?.logger).toBeDefined()
    expect(typeof context?.logger.debug).toBe('function')
    expect(typeof context?.logger.info).toBe('function')
    expect(typeof context?.logger.warn).toBe('function')
    expect(typeof context?.logger.error).toBe('function')
  })
})
