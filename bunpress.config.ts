import type { BunPressConfig } from 'bunpress'

const config: BunPressConfig = {
  name: 'Den Shell',
  description: 'A modern, high-performance shell written in Zig with native speed and memory safety',
  url: 'https://den.sh',

  nav: [
    { text: 'Guide', link: '/guide/introduction' },
    { text: 'Features', link: '/features/overview' },
    { text: 'Builtins', link: '/builtins/reference' },
    { text: 'GitHub', link: 'https://github.com/stacksjs/den' },
  ],

  sidebar: {
    '/guide/': [
      {
        text: 'Getting Started',
        items: [
          { text: 'Introduction', link: '/guide/introduction' },
          { text: 'Installation', link: '/guide/installation' },
          { text: 'Quick Start', link: '/guide/quick-start' },
          { text: 'Configuration', link: '/guide/configuration' },
        ],
      },
      {
        text: 'Usage',
        items: [
          { text: 'Custom Commands', link: '/guide/custom-commands' },
          { text: 'Scripting', link: '/guide/scripting' },
          { text: 'Migration from Bash', link: '/guide/bash-migration' },
        ],
      },
    ],
    '/features/': [
      {
        text: 'Core Features',
        items: [
          { text: 'Overview', link: '/features/overview' },
          { text: 'Pipelines', link: '/features/pipelines' },
          { text: 'Redirections', link: '/features/redirections' },
          { text: 'Job Control', link: '/features/job-control' },
          { text: 'Expansions', link: '/features/expansions' },
        ],
      },
    ],
    '/advanced/': [
      {
        text: 'Advanced',
        items: [
          { text: 'Configuration', link: '/advanced/configuration' },
          { text: 'Custom Builtins', link: '/advanced/custom-builtins' },
          { text: 'Performance', link: '/advanced/performance' },
          { text: 'Shell Integration', link: '/advanced/shell-integration' },
        ],
      },
    ],
    '/builtins/': [
      {
        text: 'Reference',
        items: [
          { text: 'All Builtins', link: '/builtins/reference' },
        ],
      },
    ],
  },

  themeConfig: {
    colors: {
      primary: '#10b981',
    },
  },
}

export default config
