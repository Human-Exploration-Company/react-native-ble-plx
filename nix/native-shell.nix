{
  pkgs,
  system,
  defaultShell,
}:
let
  androidPackages = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "37" ];
    # AGP's library default is 36; the SDK 58 app template selects 37.
    buildToolsVersions = [ "36.0.0" "37.0.0" ];
    includeNDK = true;
    ndkVersions = [ "27.1.12297006" ];
    # Use host-native CMake/Ninja from Nix, including on ARM Linux.
    includeCmake = false;
    toolsVersion = null;
  };
  androidSdkPackage = androidPackages.androidsdk.overrideAttrs (previous: {
    postInstall =
      (previous.postInstall or "")
      + pkgs.lib.optionalString (system == "aarch64-linux") ''
        # Google's Linux platform-tools contain x86-64 binaries. Expo
        # invokes adb by SDK path, so PATH alone cannot replace them.
        sdk=$out/libexec/android-sdk
        rm "$sdk/platform-tools"
        mkdir "$sdk/platform-tools"
        cp -as ${androidPackages.platform-tools}/libexec/android-sdk/platform-tools/. "$sdk/platform-tools/"
        chmod u+w "$sdk/platform-tools"
        for tool in adb fastboot; do
          rm -f "$sdk/platform-tools/$tool" "$out/bin/$tool"
          ln -s ${pkgs.android-tools}/bin/$tool "$sdk/platform-tools/$tool"
          ln -s ${pkgs.android-tools}/bin/$tool "$out/bin/$tool"
        done
      '';
  });
  androidSdk = "${androidSdkPackage}/libexec/android-sdk";
  appleTools = pkgs.runCommand "xcode-tools" { } ''
    mkdir -p $out/bin
    for tool in xcodebuild xcrun xcode-select codesign security plutil; do
      ln -s /usr/bin/$tool $out/bin/$tool
    done
  '';
in
pkgs.mkShellNoCC {
  inputsFrom = [ defaultShell ];
  env = pkgs.lib.optionalAttrs (system == "aarch64-linux") {
    inherit (defaultShell) REACT_NATIVE_OVERRIDE_HERMES_DIR;
  };
  packages = [
    androidSdkPackage
    pkgs.android-tools
    pkgs.jdk17
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
  ]
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.cocoapods
    pkgs.watchman
    appleTools
  ];
  ANDROID_HOME = androidSdk;
  ANDROID_SDK_ROOT = androidSdk;
  ANDROID_NDK_HOME = "${androidSdk}/ndk/27.1.12297006";
  JAVA_HOME = pkgs.jdk17.home;
  EXPO_NO_TELEMETRY = "1";
  shellHook = ''
    export GRADLE_OPTS="''${GRADLE_OPTS:+''${GRADLE_OPTS} }-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/build-tools/37.0.0/aapt2 -Dorg.gradle.project.android.cmakeVersion=${pkgs.cmake.version}"
  ''
  + pkgs.lib.optionalString (system == "aarch64-linux") ''
    echo "ARM Linux: SDK/JDK and native adb are available; Google's x86-64 build-tools/NDK require an x86-64 Linux or macOS build host." >&2
  ''
  + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
    if [[ -z "''${DEVELOPER_DIR:-}" ]]; then
      DEVELOPER_DIR="$(/usr/bin/xcode-select --print-path 2>/dev/null || true)"
      export DEVELOPER_DIR
    fi
    if [[ ! -x "''${DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
      echo "Install full Xcode, complete its first-launch setup, and select it with xcode-select or DEVELOPER_DIR for iOS builds." >&2
    fi
    # Resolve Apple SDKs through the selected Xcode, not Nix's macOS SDK.
    unset SDKROOT
  '';
}
