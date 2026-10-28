{
  description = "Development environment for fumo-gateway";

  inputs.nixpkgs.url = "https://github.com/NixOS/nixpkgs/archive/nixpkgs-unstable.tar.gz";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      devShells = forAllSystems (system: {
        default = (pkgsFor system).mkShell {
          packages = [ (pkgsFor system).zig_0_17 ];
        };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
