// Cloud modules
import {
  AwsModule,
  AzureModule,
  GcloudModule,
} from './cloud'

// Custom modules
import { createCustomModules } from './custom'

// Git modules
import {
  GitBranchModule,
  GitCommitModule,
  GitMetricsModule,
  GitStateModule,
  GitStatusModule,
} from './git'

import { moduleRegistry } from './index'

// Language modules
import {
  BunModule,
  CMakeModule,
  CModule,
  CppModule,
  DenoModule,
  DotNetModule,
  ErlangModule,
  GoModule,
  JavaModule,
  KotlinModule,
  LuaModule,
  NodeModule,
  PerlModule,
  PhpModule,
  PulumiModule,
  PythonModule,
  RModule,
  RubyModule,
  SwiftModule,
  TerraformModule,
  ZigModule,
} from './languages'

// System modules
import {
  BatteryModule,
  CmdDurationModule,
  DirectoryModule,
  HostnameModule,
  MemoryUsageModule,
  NixShellModule,
  OsModule,
  ShellModule,
  TimeModule,
  UsernameModule,
} from './system'

// Register all default modules
export function registerDefaultModules(): void {
  // Language modules
  moduleRegistry.register(new BunModule())
  moduleRegistry.register(new DenoModule())
  moduleRegistry.register(new NodeModule())
  moduleRegistry.register(new PythonModule())
  moduleRegistry.register(new GoModule())
  moduleRegistry.register(new JavaModule())
  moduleRegistry.register(new KotlinModule())
  moduleRegistry.register(new PhpModule())
  moduleRegistry.register(new RubyModule())
  moduleRegistry.register(new SwiftModule())
  moduleRegistry.register(new ZigModule())
  moduleRegistry.register(new LuaModule())
  moduleRegistry.register(new PerlModule())
  moduleRegistry.register(new RModule())
  moduleRegistry.register(new DotNetModule())
  moduleRegistry.register(new ErlangModule())
  moduleRegistry.register(new CModule())
  moduleRegistry.register(new CppModule())
  moduleRegistry.register(new CMakeModule())
  moduleRegistry.register(new TerraformModule())
  moduleRegistry.register(new PulumiModule())

  // Cloud modules
  moduleRegistry.register(new AwsModule())
  moduleRegistry.register(new AzureModule())
  moduleRegistry.register(new GcloudModule())

  // Git modules
  moduleRegistry.register(new GitBranchModule())
  moduleRegistry.register(new GitCommitModule())
  moduleRegistry.register(new GitStateModule())
  moduleRegistry.register(new GitStatusModule())
  moduleRegistry.register(new GitMetricsModule())

  // System modules
  moduleRegistry.register(new OsModule())
  moduleRegistry.register(new HostnameModule())
  moduleRegistry.register(new DirectoryModule())
  moduleRegistry.register(new UsernameModule())
  moduleRegistry.register(new ShellModule())
  moduleRegistry.register(new BatteryModule())
  moduleRegistry.register(new CmdDurationModule())
  moduleRegistry.register(new MemoryUsageModule())
  moduleRegistry.register(new TimeModule())
  moduleRegistry.register(new NixShellModule())
}

// Register custom modules from config
export function registerCustomModules(config: any): void {
  const customModules = createCustomModules(config)
  for (const module of customModules) {
    moduleRegistry.register(module)
  }
}

// Initialize all modules
export function initializeModules(config?: any): void {
  registerDefaultModules()

  if (config) {
    registerCustomModules(config)
  }
}

export { moduleRegistry }
