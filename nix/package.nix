{
  lib,
  stdenvNoCC,
  bun,
  zig_0_17,
}:
let
  webDependencies = stdenvNoCC.mkDerivation {
    pname = "fumo-gateway-web-dependencies";
    version = "0.0.0";
    src = lib.fileset.toSource {
      root = ../web;
      fileset = lib.fileset.unions [
        ../web/package.json
        ../web/bun.lock
      ];
    };
    nativeBuildInputs = [ bun ];
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
    outputHash = "sha256-WYiZ881jIVSlXgjUmboMcchfSVbmrvxiyoqSdmgLgBY=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "fumo-gateway";
  version = "0.0.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../tests
      ../assets
      ../schemas
      ../gateway.example.json
      (lib.fileset.difference ../web (
        lib.fileset.unions [
          (lib.fileset.maybeMissing ../web/node_modules)
          (lib.fileset.maybeMissing ../web/dist)
        ]
      ))
    ];
  };
  nativeBuildInputs = [
    zig_0_17.hook
    bun
  ];
  preConfigure = ''
    cp -R ${webDependencies} web/node_modules
    chmod -R u+w web/node_modules
    substituteInPlace web/node_modules/typescript/bin/tsc web/node_modules/vite/bin/vite.js \
      --replace-fail '#!/usr/bin/env node' '#!${bun}/bin/bun'
  '';
  doCheck = true;
  __darwinAllowLocalNetworking = true;
  meta = {
    description = "Headless Responses gateway with Sign in with ChatGPT";
    mainProgram = "fumo-gateway";
    platforms = lib.platforms.unix;
  };
}
