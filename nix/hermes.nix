{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  python3,
  icu,
}:

stdenv.mkDerivation {
  pname = "hermesc";
  # Match bun.lock's hermes-compiler source and bytecode format.
  version = "260318099.0.4";
  src = fetchFromGitHub {
    owner = "facebook";
    repo = "hermes";
    rev = "d412d3bd851278712c20cca25d094e32641a0465";
    hash = "sha256-ZH1BraxaRsEs/uGlJ8oXrUg/pl2kj8jkdavJ7Ly5JNg=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    python3
  ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ icu ];
  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DHERMES_RELEASE_VERSION=260318099.0.4"
    "-DHERMES_ENABLE_TEST_SUITE=OFF"
  ];
  # Only the host compiler; skip VM, other tools, tests, and release LTO.
  ninjaFlags = [ "hermesc" ];
  installPhase = ''
    runHook preInstall
    install -Dm755 bin/hermesc $out/bin/hermesc
    mkdir -p $out/build/bin
    ln -s ../../bin/hermesc $out/build/bin/hermesc
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/hermesc --version
    echo 'print(1 + 2)' > smoke.js
    $out/bin/hermesc -O -emit-binary -out smoke.hbc smoke.js
    test -s smoke.hbc
    runHook postInstallCheck
  '';
  meta = {
    description = "React Native's pinned Hermes host bytecode compiler";
    homepage = "https://github.com/facebook/hermes";
    license = lib.licenses.mit;
    mainProgram = "hermesc";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
