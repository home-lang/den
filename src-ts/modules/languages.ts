import type { ModuleContext, ModuleResult } from '../types'
import { BaseModule, ModuleUtils } from './index'

// Bun module
export class BunModule extends BaseModule {
  name = 'bun'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.bun || {}
    const files = cfg.detect_files ?? ['bun.lockb', 'bun.lock', 'bunfig.toml']
    return ModuleUtils.hasFiles(context, files)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('bun --version')
    const cfg = (context.config as any)?.bun || {}
    const symbol = cfg.symbol ?? '🐰'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = version
      ? format.replace('{symbol}', symbol).replace('{version}', `v${version}`)
      : symbol

    return this.formatResult(content)
  }
}

// Deno module
export class DenoModule extends BaseModule {
  name = 'deno'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.deno || {}
    const files = cfg.detect_files ?? ['deno.json', 'deno.jsonc', 'deno.lock', 'mod.ts', 'mod.js', 'deps.ts', 'deps.js']
    const exts = cfg.detect_extensions ?? ['.ts', '.js']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const output = await ModuleUtils.getCommandOutput('deno -V')
    const parsed = output ? ModuleUtils.parseVersion(output) : null
    const cfg = (context.config as any)?.deno || {}
    const symbol = cfg.symbol ?? '🦕'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsed
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsed}`)
      : symbol

    return this.formatResult(content)
  }
}

// Node.js/JavaScript module
export class NodeModule extends BaseModule {
  name = 'nodejs'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.nodejs || {}
    const files = cfg.detect_files ?? ['package.json', 'package-lock.json', 'yarn.lock', '.nvmrc', '.node-version']
    const exts = cfg.detect_extensions ?? ['.js', '.mjs', '.cjs', '.ts']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('node --version')
    const cfg = (context.config as any)?.nodejs || {}
    const symbol = cfg.symbol ?? '⬢'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = version
      ? format.replace('{symbol}', symbol).replace('{version}', version)
      : symbol

    return this.formatResult(content)
  }
}

// Python module
export class PythonModule extends BaseModule {
  name = 'python'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.python || {}
    const files = cfg.detect_files ?? ['requirements.txt', 'pyproject.toml', 'Pipfile', 'tox.ini', 'setup.py', '__init__.py']
    const exts = cfg.detect_extensions ?? ['.py', '.ipynb']
    const dirs = cfg.detect_directories ?? ['.venv', 'venv']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts) || ModuleUtils.hasDirectories(context, dirs)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('python --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.python || {}
    const symbol = cfg.symbol ?? '🐍'
    const format = cfg.format ?? 'via {symbol} {version}'
    const base = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    // Check for virtual environment
    const venv = context.environment.VIRTUAL_ENV || context.environment.CONDA_DEFAULT_ENV
    const venvName = venv ? ` (${venv.split('/').pop()})` : ''

    return this.formatResult(base + venvName)
  }
}

// Go module
export class GoModule extends BaseModule {
  name = 'golang'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.golang || {}
    const files = cfg.detect_files ?? ['go.mod', 'go.sum', 'glide.yaml', 'Gopkg.yml', 'Gopkg.lock', '.go-version']
    const exts = cfg.detect_extensions ?? ['.go']
    const dirs = cfg.detect_directories ?? ['Godeps']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts) || ModuleUtils.hasDirectories(context, dirs)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('go version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.golang || {}
    const symbol = cfg.symbol ?? '🐹'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// Java module
export class JavaModule extends BaseModule {
  name = 'java'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.java || {}
    const files = cfg.detect_files ?? ['pom.xml', 'build.gradle', 'build.gradle.kts', 'build.sbt', '.java-version']
    const exts = cfg.detect_extensions ?? ['.java', '.class', '.jar']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('java -version 2>&1')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.java || {}
    const symbol = cfg.symbol ?? '☕'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// Kotlin module
export class KotlinModule extends BaseModule {
  name = 'kotlin'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.kotlin || {}
    const exts = cfg.detect_extensions ?? ['.kt', '.kts']
    return ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('kotlin -version 2>&1')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.kotlin || {}
    const symbol = cfg.symbol ?? '🅺'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// PHP module
export class PhpModule extends BaseModule {
  name = 'php'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.php || {}
    const files = cfg.detect_files ?? ['composer.json', 'composer.lock', '.php-version']
    const exts = cfg.detect_extensions ?? ['.php']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('php --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.php || {}
    const symbol = cfg.symbol ?? '🐘'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// Ruby module
export class RubyModule extends BaseModule {
  name = 'ruby'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.ruby || {}
    const files = cfg.detect_files ?? ['Gemfile', 'Gemfile.lock', '.ruby-version', '.rvmrc']
    const exts = cfg.detect_extensions ?? ['.rb']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('ruby --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.ruby || {}
    const symbol = cfg.symbol ?? '💎'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// Swift module
export class SwiftModule extends BaseModule {
  name = 'swift'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.swift || {}
    const files = cfg.detect_files ?? ['Package.swift']
    const exts = cfg.detect_extensions ?? ['.swift']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('swift --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.swift || {}
    const symbol = cfg.symbol ?? '🐦'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// Zig module
export class ZigModule extends BaseModule {
  name = 'zig'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.zig || {}
    const files = cfg.detect_files ?? ['build.zig']
    const exts = cfg.detect_extensions ?? ['.zig']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('zig version')
    const cfg = (context.config as any)?.zig || {}
    const symbol = cfg.symbol ?? '⚡'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = version
      ? format.replace('{symbol}', symbol).replace('{version}', `v${version}`)
      : symbol

    return this.formatResult(content)
  }
}

// Lua module
export class LuaModule extends BaseModule {
  name = 'lua'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.lua || {}
    const files = cfg.detect_files ?? ['.lua-version']
    const exts = cfg.detect_extensions ?? ['.lua']
    const dirs = cfg.detect_directories ?? ['lua']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts) || ModuleUtils.hasDirectories(context, dirs)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('lua -v')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.lua || {}
    const symbol = cfg.symbol ?? '🌙'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// Perl module
export class PerlModule extends BaseModule {
  name = 'perl'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.perl || {}
    const files = cfg.detect_files ?? ['Makefile.PL', 'Build.PL', 'cpanfile', 'cpanfile.snapshot', 'META.json', 'META.yml']
    const exts = cfg.detect_extensions ?? ['.pl', '.pm', '.pod']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('perl --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.perl || {}
    const symbol = cfg.symbol ?? '🐪'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// R module
export class RModule extends BaseModule {
  name = 'rlang'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.rlang || {}
    const files = cfg.detect_files ?? ['DESCRIPTION', '.Rprofile']
    const exts = cfg.detect_extensions ?? ['.R', '.Rd', '.Rmd', '.Rsx']
    const dirs = cfg.detect_directories ?? ['.Rproj.user']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts) || ModuleUtils.hasDirectories(context, dirs)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('R --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.rlang || {}
    const symbol = cfg.symbol ?? '📊'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// .NET module
export class DotNetModule extends BaseModule {
  name = 'dotnet'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.dotnet || {}
    const files = cfg.detect_files ?? ['global.json', 'project.json', 'Directory.Build.props', 'Directory.Build.targets', 'Packages.props']
    const exts = cfg.detect_extensions ?? ['.csproj', '.fsproj', '.xproj', '.sln']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('dotnet --version')
    const cfg = (context.config as any)?.dotnet || {}
    const symbol = cfg.symbol ?? '.NET'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = version
      ? format.replace('{symbol}', symbol).replace('{version}', `v${version}`)
      : symbol

    return this.formatResult(content)
  }
}

// Erlang module
export class ErlangModule extends BaseModule {
  name = 'erlang'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.erlang || {}
    const files = cfg.detect_files ?? ['rebar.config', 'erlang.mk']
    const exts = cfg.detect_extensions ?? ['.erl', '.hrl']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('erl -noshell -eval "io:format(\"~s\", [erlang:system_info(otp_release)]), halt()."')
    const cfg = (context.config as any)?.erlang || {}
    const symbol = cfg.symbol ?? 'E'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = version
      ? format.replace('{symbol}', symbol).replace('{version}', `v${version}`)
      : symbol

    return this.formatResult(content)
  }
}

// C module
export class CModule extends BaseModule {
  name = 'c'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.c || {}
    const exts = cfg.detect_extensions ?? ['.c', '.h']
    return ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('gcc --version')
      || await ModuleUtils.getCommandOutput('clang --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.c || {}
    const symbol = cfg.symbol ?? 'C'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// C++ module
export class CppModule extends BaseModule {
  name = 'cpp'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.cpp || {}
    const exts = cfg.detect_extensions ?? ['.cpp', '.cxx', '.cc', '.hpp', '.hxx', '.hh']
    return ModuleUtils.hasExtensions(context, exts)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('g++ --version')
      || await ModuleUtils.getCommandOutput('clang++ --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.cpp || {}
    const symbol = cfg.symbol ?? 'C++'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// CMake module
export class CMakeModule extends BaseModule {
  name = 'cmake'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.cmake || {}
    const files = cfg.detect_files ?? ['CMakeLists.txt', 'CMakeCache.txt']
    return ModuleUtils.hasFiles(context, files)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('cmake --version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.cmake || {}
    const symbol = cfg.symbol ?? '△'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// Terraform module
export class TerraformModule extends BaseModule {
  name = 'terraform'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.terraform || {}
    const files = cfg.detect_files ?? ['.terraform-version']
    const exts = cfg.detect_extensions ?? ['.tf', '.hcl']
    const dirs = cfg.detect_directories ?? ['.terraform']
    return ModuleUtils.hasFiles(context, files) || ModuleUtils.hasExtensions(context, exts) || ModuleUtils.hasDirectories(context, dirs)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('terraform version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.terraform || {}
    const symbol = cfg.symbol ?? '💠'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}

// Pulumi module
export class PulumiModule extends BaseModule {
  name = 'pulumi'
  enabled = true

  detect(context: ModuleContext): boolean {
    const cfg = (context.config as any)?.pulumi || {}
    const files = cfg.detect_files ?? ['Pulumi.yaml', 'Pulumi.yml']
    return ModuleUtils.hasFiles(context, files)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const version = await ModuleUtils.getCommandOutput('pulumi version')
    const parsedVersion = version ? ModuleUtils.parseVersion(version) : null
    const cfg = (context.config as any)?.pulumi || {}
    const symbol = cfg.symbol ?? '🧊'
    const format = cfg.format ?? 'via {symbol} {version}'
    const content = parsedVersion
      ? format.replace('{symbol}', symbol).replace('{version}', `v${parsedVersion}`)
      : symbol

    return this.formatResult(content)
  }
}
