import type { Module, ModuleConfig, ModuleContext, ModuleResult } from '../types'
import { exec } from 'node:child_process'
import { existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { promisify } from 'node:util'

const execAsync = promisify(exec)

// Utility functions for modules
export class ModuleUtils {
  static hasFiles(context: ModuleContext, files: string[]): boolean {
    return files.some(file => existsSync(join(context.cwd, file)))
  }

  static hasExtensions(context: ModuleContext, extensions: string[]): boolean {
    try {
      // eslint-disable-next-line ts/no-require-imports
      const entries = require('node:fs').readdirSync(context.cwd)
      return entries.some((entry: string) =>
        extensions.some(ext => entry.endsWith(ext)),
      )
    }
    catch {
      return false
    }
  }

  static hasDirectories(context: ModuleContext, directories: string[]): boolean {
    return directories.some((dir) => {
      try {
        const path = join(context.cwd, dir)
        return existsSync(path) && statSync(path).isDirectory()
      }
      catch {
        return false
      }
    })
  }

  static async getCommandOutput(command: string): Promise<string | null> {
    try {
      const { stdout } = await execAsync(command)
      return stdout.trim()
    }
    catch {
      return null
    }
  }

  static formatTemplate(template: string, variables: Record<string, string>): string {
    return template.replace(/\{(\w+)\}/g, (match, key) => variables[key] || match)
  }

  static parseVersion(versionString: string): string | null {
    const match = versionString.match(/(\d+\.\d+(?:\.\d+)?(?:-[\w.]+)?)/)
    return match ? match[1] : null
  }
}

// Base module class
export abstract class BaseModule implements Module {
  abstract name: string
  abstract enabled: boolean
  // Optional config that modules may use; not abstract to avoid forcing implementation in subclasses
  config?: Record<string, any>

  abstract detect(context: ModuleContext): boolean
  abstract render(context: ModuleContext): Promise<ModuleResult | null>

  protected formatResult(content: string, style?: ModuleResult['style']): ModuleResult {
    return { content, style }
  }

  protected isEnabled(moduleConfig?: any): boolean {
    return moduleConfig?.enabled !== false
  }
}

// Module registry
export class ModuleRegistry {
  private modules = new Map<string, Module>()

  register(module: Module): void {
    this.modules.set(module.name, module)
  }

  get(name: string): Module | undefined {
    return this.modules.get(name)
  }

  getAll(): Module[] {
    return Array.from(this.modules.values())
  }

  getEnabled(): Module[] {
    return this.getAll().filter(module => module.enabled)
  }

  async renderModules(context: ModuleContext, config?: ModuleConfig): Promise<ModuleResult[]> {
    const results: ModuleResult[] = []

    for (const module of this.getEnabled()) {
      if (module.detect(context)) {
        const moduleConfig = config?.[module.name as keyof ModuleConfig]
        if (moduleConfig?.enabled !== false) {
          const result = await module.render(context)
          if (result) {
            results.push(result)
          }
        }
      }
    }

    return results
  }
}

// Create default module registry
export const moduleRegistry: ModuleRegistry = new ModuleRegistry()
