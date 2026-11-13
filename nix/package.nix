{
  lib,
  aws-lc,
  stdenvNoCC,
  bun,
  pkg-config,
  rustPlatform,
  zstd,
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
    outputHash = "sha256-3ubCt56pD0lX+q6DbKvRkc2Nh4fK/qqcZnSOaYnbVy4=";
  };
in
rustPlatform.buildRustPackage {
  pname = "fumo-gateway";
  version = "0.0.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../build.rs
      (lib.fileset.fileFilter (file: file.hasExt "rs") ../src)
      (lib.fileset.fileFilter (file: file.hasExt "rs" || file.hasExt "json") ../tests)
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
  cargoLock.lockFile = ../Cargo.lock;
  nativeBuildInputs = [
    bun
    pkg-config
  ];
  buildInputs = [
    aws-lc
    zstd
  ];
  preBuild = ''
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
