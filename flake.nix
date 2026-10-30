{
  description = "Headless Responses gateway with Sign in with ChatGPT";

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
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          webDependencies = pkgs.stdenvNoCC.mkDerivation {
            pname = "fumo-gateway-web-dependencies";
            version = "0.0.0";
            src = nixpkgs.lib.fileset.toSource {
              root = ./web;
              fileset = nixpkgs.lib.fileset.unions [
                ./web/package.json
                ./web/bun.lock
              ];
            };
            nativeBuildInputs = [ pkgs.bun ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME="$TMPDIR"
              bun install --frozen-lockfile --ignore-scripts --os='*' --cpu='*'
            '';
            installPhase = ''
              cp -R node_modules "$out"
            '';
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-fM3lkEjidsJjSMRK3um3nLEmKrjclIPploPbLCzlmic=";
          };
          package = pkgs.stdenvNoCC.mkDerivation {
            pname = "fumo-gateway";
            version = "0.0.0";
            src = nixpkgs.lib.fileset.toSource {
              root = ./.;
              fileset = nixpkgs.lib.fileset.unions [
                ./build.zig
                ./build.zig.zon
                ./src
                ./tests
                ./assets
                (nixpkgs.lib.fileset.difference ./web (
                  nixpkgs.lib.fileset.unions [
                    (nixpkgs.lib.fileset.maybeMissing ./web/node_modules)
                    (nixpkgs.lib.fileset.maybeMissing ./web/dist)
                  ]
                ))
              ];
            };
            nativeBuildInputs = [
              pkgs.zig_0_17.hook
              pkgs.bun
            ];
            preConfigure = ''
              cp -R ${webDependencies} web/node_modules
              chmod -R u+w web/node_modules
              substituteInPlace web/node_modules/typescript/bin/tsc web/node_modules/vite/bin/vite.js \
                --replace-fail '#!/usr/bin/env node' '#!${pkgs.bun}/bin/bun'
            '';
            doCheck = true;
            __darwinAllowLocalNetworking = true;
            meta = {
              description = "Headless Responses gateway with Sign in with ChatGPT";
              mainProgram = "fumo-gateway";
              platforms = nixpkgs.lib.platforms.unix;
            };
          };
        in
        {
          default = package;
          fumo-gateway = package;
        }
      );

      devShells = forAllSystems (system: {
        default = (pkgsFor system).mkShell {
          packages = [
            (pkgsFor system).zig_0_17
            (pkgsFor system).bun
          ];
        };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
