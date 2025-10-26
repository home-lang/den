{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

stdenv.mkDerivation rec {
  pname = "den";
  version = "0.1.0";

  src = fetchurl {
    url = if stdenv.isDarwin then
      if stdenv.isAarch64 then
        "https://github.com/stacksjs/den/releases/download/v${version}/den-${version}-darwin-arm64.tar.gz"
      else
        "https://github.com/stacksjs/den/releases/download/v${version}/den-${version}-darwin-x64.tar.gz"
    else
      if stdenv.isAarch64 then
        "https://github.com/stacksjs/den/releases/download/v${version}/den-${version}-linux-arm64.tar.gz"
      else
        "https://github.com/stacksjs/den/releases/download/v${version}/den-${version}-linux-x64.tar.gz";

    sha256 = "0000000000000000000000000000000000000000000000000000";  # Update with actual hash
  };

  nativeBuildInputs = lib.optionals stdenv.isLinux [ autoPatchelfHook ];

  sourceRoot = "den";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp den $out/bin/den
    chmod +x $out/bin/den

    # Create wrapper script
    cat > $out/bin/den-wrapper <<'EOF'
    #!${stdenv.shell}
    export DEN_NONINTERACTIVE=1
    exec $out/bin/den "$@"
    EOF
    chmod +x $out/bin/den-wrapper

    runHook postInstall
  '';

  meta = with lib; {
    description = "Modern, fast, and feature-rich POSIX shell written in Zig";
    homepage = "https://github.com/stacksjs/den";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "den";
  };
}
