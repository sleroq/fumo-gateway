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
              ];
            };
            nativeBuildInputs = [ pkgs.zig_0_17.hook ];
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
          packages = [ (pkgsFor system).zig_0_17 ];
        };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
