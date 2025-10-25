import type { ModuleContext, ModuleResult } from '../types'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import process from 'node:process'
import { BaseModule } from './index'

// AWS module
export class AwsModule extends BaseModule {
  name = 'aws'
  enabled = true

  detect(context: ModuleContext): boolean {
    return !!(
      context.environment.AWS_REGION
      || context.environment.AWS_DEFAULT_REGION
      || context.environment.AWS_PROFILE
      || context.environment.AWS_ACCESS_KEY_ID
      || this.getAwsConfig()
    )
  }

  async render(_context: ModuleContext): Promise<ModuleResult | null> {
    const profile = _context.environment.AWS_PROFILE || 'default'
    const region = _context.environment.AWS_REGION
      || _context.environment.AWS_DEFAULT_REGION
      || this.getRegionFromConfig(profile)

    const symbol = '☁️'
    let content = symbol

    if (profile && profile !== 'default') {
      content += ` ${profile}`
    }

    if (region) {
      content += ` (${region})`
    }

    return this.formatResult(content, { color: '#ff9900' })
  }

  private getAwsConfig(): any {
    try {
      const configPath = join(homedir(), '.aws', 'config')
      if (existsSync(configPath)) {
        return readFileSync(configPath, 'utf-8')
      }
    }
    catch {
      // Ignore errors
    }
    return null
  }

  private getRegionFromConfig(profile: string): string | null {
    try {
      const config = this.getAwsConfig()
      if (config) {
        const sectionName = profile === 'default' ? '[default]' : `[profile ${profile}]`
        const lines = config.split('\n')
        let inSection = false

        for (const line of lines) {
          if (line.trim() === sectionName) {
            inSection = true
            continue
          }
          if (line.startsWith('[') && inSection) {
            break
          }
          if (inSection && line.includes('region')) {
            const match = line.match(/region\s*=\s*(.+)/)
            if (match) {
              return match[1].trim()
            }
          }
        }
      }
    }
    catch {
      // Ignore errors
    }
    return null
  }
}

// Azure module
export class AzureModule extends BaseModule {
  name = 'azure'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return !!(
      _context.environment.AZURE_CONFIG_DIR
      || this.getAzureProfile()
    )
  }

  async render(_context: ModuleContext): Promise<ModuleResult | null> {
    const profile = this.getAzureProfile()
    if (!profile)
      return null

    const symbol = '󰠅'
    const content = `${symbol} ${profile.name}`

    return this.formatResult(content, { color: '#0078d4' })
  }

  private getAzureProfile(): any {
    try {
      const configDir = process.env.AZURE_CONFIG_DIR || join(homedir(), '.azure')
      const profilePath = join(configDir, 'azureProfile.json')

      if (existsSync(profilePath)) {
        const profileData = JSON.parse(readFileSync(profilePath, 'utf-8'))
        const defaultSubscription = profileData.subscriptions?.find((sub: any) => sub.isDefault)
        return defaultSubscription
      }
    }
    catch {
      // Ignore errors
    }
    return null
  }
}

// Google Cloud module
export class GcloudModule extends BaseModule {
  name = 'gcloud'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return !!(
      _context.environment.CLOUDSDK_CONFIG
      || _context.environment.CLOUDSDK_CORE_PROJECT
      || _context.environment.CLOUDSDK_ACTIVE_CONFIG_NAME
      || this.getGcloudConfig()
    )
  }

  async render(_context: ModuleContext): Promise<ModuleResult | null> {
    const project = _context.environment.CLOUDSDK_CORE_PROJECT || this.getActiveProject()
    const config = _context.environment.CLOUDSDK_ACTIVE_CONFIG_NAME || this.getActiveConfig()

    if (!project && !config)
      return null

    const symbol = '☁️'
    let content = symbol

    if (project) {
      content += ` ${project}`
    }

    if (config && config !== 'default') {
      content += ` (${config})`
    }

    return this.formatResult(content, { color: '#4285f4' })
  }

  private getGcloudConfig(): any {
    try {
      const configDir = process.env.CLOUDSDK_CONFIG || join(homedir(), '.config', 'gcloud')
      const activeConfigPath = join(configDir, 'active_config')

      if (existsSync(activeConfigPath)) {
        return readFileSync(activeConfigPath, 'utf-8').trim()
      }
    }
    catch {
      // Ignore errors
    }
    return null
  }

  private getActiveConfig(): string | null {
    return this.getGcloudConfig()
  }

  private getActiveProject(): string | null {
    try {
      const configDir = process.env.CLOUDSDK_CONFIG || join(homedir(), '.config', 'gcloud')
      const activeConfig = this.getActiveConfig() || 'default'
      const configPath = join(configDir, 'configurations', `config_${activeConfig}`)

      if (existsSync(configPath)) {
        const config = readFileSync(configPath, 'utf-8')
        const match = config.match(/project\s*=\s*(.+)/)
        if (match) {
          return match[1].trim()
        }
      }
    }
    catch {
      // Ignore errors
    }
    return null
  }
}
