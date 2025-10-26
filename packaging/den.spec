Name:           den
Version:        0.1.0
Release:        1%{?dist}
Summary:        Modern, fast, and feature-rich POSIX shell written in Zig

License:        MIT
URL:            https://github.com/stacksjs/den
Source0:        https://github.com/stacksjs/den/releases/download/v%{version}/den-%{version}-linux-x64.tar.gz

BuildArch:      x86_64
Requires:       glibc

%description
Den Shell is a modern shell designed for speed and usability.
It features advanced command completion, syntax highlighting,
plugin support, and comprehensive scripting capabilities.

Key features:
- Fast startup and execution
- Advanced tab completion
- Plugin system with hook support
- Theming and prompt customization
- Built-in scripting engine
- Job control and process management

%prep
%setup -q -n den

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}%{_bindir}
install -m 0755 den %{buildroot}%{_bindir}/den

%post
# Add den to /etc/shells
if [ -f /etc/shells ]; then
    if ! grep -q "^%{_bindir}/den$" /etc/shells; then
        echo "%{_bindir}/den" >> /etc/shells
    fi
fi

echo ""
echo "Den Shell has been installed!"
echo ""
echo "To use Den as your default shell:"
echo "  chsh -s %{_bindir}/den"
echo ""
echo "To start using Den:"
echo "  den"
echo ""

%postun
# Remove den from /etc/shells on uninstall
if [ $1 -eq 0 ]; then
    if [ -f /etc/shells ]; then
        sed -i.bak '\|^%{_bindir}/den$|d' /etc/shells
        rm -f /etc/shells.bak
    fi
fi

%files
%{_bindir}/den

%changelog
* $(date "+%a %b %d %Y") Stacks.js <support@stacksjs.org> - 0.1.0-1
- Initial RPM release
