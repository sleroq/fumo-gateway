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
          container = (pkgsFor system).dockerTools.buildLayeredImage {
            name = "fumo-gateway";
            tag = "latest";
            contents = [ package ];
            config = {
              Entrypoint = [ "${package}/bin/fumo-gateway" ];
              Env = [
                "SSL_CERT_FILE=${(pkgsFor system).cacert}/etc/ssl/certs/ca-bundle.crt"
                "HOME=/data"
              ];
            };
          };
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
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
            packages = [
              pkgs.rustc
              pkgs.cargo
              pkgs.clippy
              pkgs.rustfmt
              pkgs.bun
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
