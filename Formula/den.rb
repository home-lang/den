# Homebrew Formula for Den Shell
# Usage:
#   brew install stacksjs/tap/den
#   brew install den.rb  (from local file)

class Den < Formula
  desc "Modern, fast, and feature-rich POSIX shell written in Zig"
  homepage "https://github.com/stacksjs/den"
  version "0.1.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/stacksjs/den/releases/download/v0.1.0/den-0.1.0-darwin-arm64.tar.gz"
      sha256 "PLACEHOLDER_SHA256_DARWIN_ARM64"
    else
      url "https://github.com/stacksjs/den/releases/download/v0.1.0/den-0.1.0-darwin-x64.tar.gz"
      sha256 "PLACEHOLDER_SHA256_DARWIN_X64"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/stacksjs/den/releases/download/v0.1.0/den-0.1.0-linux-arm64.tar.gz"
      sha256 "PLACEHOLDER_SHA256_LINUX_ARM64"
    else
      url "https://github.com/stacksjs/den/releases/download/v0.1.0/den-0.1.0-linux-x64.tar.gz"
      sha256 "PLACEHOLDER_SHA256_LINUX_X64"
    end
  end

  def install
    bin.install "den/den"

    # Install shell wrapper
    (bin/"den-wrapper").write <<~EOS
      #!/bin/sh
      export DEN_NONINTERACTIVE=1
      exec "#{bin}/den" "$@"
    EOS
    chmod 0755, bin/"den-wrapper"
  end

  def caveats
    <<~EOS
      Den Shell has been installed!

      To use Den as your default shell:
        1. Add to /etc/shells:
           echo "#{bin}/den" | sudo tee -a /etc/shells

        2. Change your default shell:
           chsh -s #{bin}/den

      To start using Den interactively:
        den

      For more information:
        den --help
    EOS
  end

  test do
    assert_match "Den Shell v#{version}", shell_output("#{bin}/den version")
    assert_match "Den Shell", shell_output("#{bin}/den --help")

    # Test basic command execution
    assert_equal "hello\n", shell_output("#{bin}/den exec 'echo hello'")
  end
end
