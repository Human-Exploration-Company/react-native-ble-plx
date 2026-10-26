{
  pkgs,
  system,
  systems,
}:
let
  sources = {
    x86_64-linux = {
      name = "linux-x64-baseline";
      hash = "sha512-2/ZDBwYirPDHTHDVKg/mVleVePxqv/rq0mo1aEvdUbCNeTvTyYS2qB8hHbdUQ+n70Z+08kyGmNbq3MHv/LlQ+g==";
    };
    aarch64-linux = {
      name = "linux-aarch64";
      hash = "sha512-R5vAR6McjtiRvOgTVjdf2eOM/56HUX6QHaxogOHFV4I6b3tB7UQrAMzL0g6jbpcUaoJBvsm/4kLljMVAoUSK+w==";
    };
    aarch64-darwin = {
      name = "darwin-aarch64";
      hash = "sha512-Cx6jvAv5L5oxTY61owJPZmxAW2WjlkUBXkm39lDb8EkAz5G3iuvew2aI5GFX5eBaAS2om3htRNuqakK4uzGhEA==";
    };
  };
  # Match packageManager and CI. A dated npm archive is immutable; "canary" is not.
in
pkgs.bun.overrideAttrs (
  final: previous: {
    version = pkgs.lib.removeSuffix "\n" (builtins.readFile ../.bun-version);
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@oven/bun-${sources.${system}.name}/-/bun-${sources.${system}.name}-${final.version}.tgz";
      hash = sources.${system}.hash;
    };
    sourceRoot = "package/bin";
    meta = previous.meta // {
      platforms = systems;
    };
  }
)
