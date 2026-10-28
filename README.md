# fumo-gateway

A small, headless LLM gateway. See [ROADMAP.md](ROADMAP.md) for the planned scope.
Only the development environment and executable scaffold are initialized so far.

## Development

### Recommended: Nix

With Nix and flakes enabled, enter the dev shell:

```sh
nix develop
```

The shell provides Zig **0.17.0**, the latest stable release at initialization,
pinned through `flake.lock`.

For automatic shell loading, install direnv and nix-direnv, enable the direnv
shell hook, then run:

```sh
direnv allow
```

Format the Nix flake with `nix fmt flake.nix`.

### Without Nix

Install [Zig 0.17.0](https://ziglang.org/download/) and put `zig` on your `PATH`.
Nix and direnv are optional; Zig is sufficient to build, run, and test the project.

### Build, run, and test

With Zig available through either setup:

```sh
zig version
zig build
zig build run
zig build test
zig fmt --check build.zig build.zig.zon src/
```

The executable is installed at `zig-out/bin/fumo-gateway`. It currently only prints
its name; the test target compiles the scaffold, with no application tests yet.
