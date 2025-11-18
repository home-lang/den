---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Den Shell"
  text: "A blazing-fast POSIX shell written in Zig"
  tagline: "Native performance meets modern safety"
  image: /images/logo-white.png
  actions:
    - theme: brand
      text: Get Started
      link: /intro
    - theme: alt
      text: View on GitHub
      link: https://github.com/stacksjs/den

features:
  - title: "⚡ Lightning Fast"
    icon: "⚡"
    details: "5ms startup, 5-9x faster than bash/zsh/fish. Zero runtime overhead."
  - title: "🛡️ Memory Safe"
    icon: "🛡️"
    details: "Written in Zig. Compile-time safety prevents memory leaks and crashes."
  - title: "📦 Zero Dependencies"
    icon: "📦"
    details: "1.8MB binary with no external dependencies. Deploy anywhere."
  - title: "🎯 Feature Rich"
    icon: "🎯"
    details: "54 builtins, job control, history, completion, and full POSIX support."
  - title: "🔧 Extensible"
    icon: "🔧"
    details: "Plugin system, custom themes, and comprehensive configuration."
  - title: "📊 Benchmarked"
    icon: "📊"
    details: "Continuous performance monitoring. 2-4x less memory than alternatives."
---

<Home />
