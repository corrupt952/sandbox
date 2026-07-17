{
  description = "swift-discord-voice-poc dev shell (opus decode via pkg-config)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShellNoCC {
          # The Swift toolchain comes from Xcode; this shell only provides the C library
          # for Opus decoding, resolved by SwiftPM's systemLibrary(pkgConfig: "opus")
          # through pkg-config.
          packages = [ pkgs.opus pkgs.pkg-config ];
        };
      });
}
