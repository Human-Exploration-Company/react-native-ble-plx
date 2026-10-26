{
  description = "react-native-ble-plx development shell";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };
      hermesFor = system: (pkgsFor system).callPackage ./nix/hermes.nix { };
    in
    {
      packages = forSystems (system: {
        hermesc = hermesFor system;
      });
      devShells = forSystems (
        system:
        let
          pkgs = pkgsFor system;
          bun = import ./nix/bun.nix { inherit pkgs system systems; };
          defaultShell = pkgs.mkShell {
            packages = [
              bun
              pkgs.nodejs_24
            ];
            EXPO_NO_TELEMETRY = "1";
            shellHook = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            '';
            # npm has no Linux ARM64 binary; build its exact compiler source.
            env = pkgs.lib.optionalAttrs (system == "aarch64-linux") {
              REACT_NATIVE_OVERRIDE_HERMES_DIR = hermesFor system;
            };
          };
        in
        {
          default = defaultShell;
          native = import ./nix/native-shell.nix { inherit pkgs system defaultShell; };
        }
      );
    };
}
