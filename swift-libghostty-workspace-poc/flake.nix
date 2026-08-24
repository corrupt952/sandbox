{
  description = "swift-libghostty-workspace-poc dev shell (gettext for libghostty's msgfmt step)";

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
          # gettext supplies msgfmt, which upstream ghostty-org/ghostty's
          # `zig build -Demit-macos-app=false` needs for its locale (.mo)
          # generation step. zig itself comes from mise (pinned in
          # mise.toml) rather than nixpkgs: nixpkgs' zig bundles its own
          # macOS SDK, which is older than what ghostty's build requires
          # (Xcode 26 / macOS 26 SDK) and fails compiling pkg/macos. The
          # Swift toolchain itself comes from Xcode.
          packages = [ pkgs.gettext ];
        };
      });
}
