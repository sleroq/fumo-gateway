{
  description = "Headless Responses gateway with Sign in with ChatGPT";

  inputs.nixpkgs.url = "https://github.com/NixOS/nixpkgs/archive/nixpkgs-unstable.tar.gz";

  outputs =
    { self, nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (
        system:
        let
          package = (pkgsFor system).callPackage ./nix/package.nix { };
        in
        {
          default = package;
          fumo-gateway = package;
        }
      );

      nixosModules.default = import ./nix/module.nix { inherit self; };

      checks = forAllSystems (system: {
        module = import ./nix/module-test.nix {
          inherit self nixpkgs;
          pkgs = pkgsFor system;
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_17
              pkgs.bun
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
