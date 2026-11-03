use std::{env, path::PathBuf, process::Command};

fn main() {
    for path in [
        "build.rs",
        "web/package.json",
        "web/bun.lock",
        "web/index.html",
        "web/src",
        "web/vite.config.ts",
        "web/tsconfig.json",
        "web/tsconfig.app.json",
        "web/tsconfig.node.json",
        "assets",
    ] {
        println!("cargo:rerun-if-changed={path}");
    }
    println!("cargo:rerun-if-env-changed=BUN");

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo must set OUT_DIR"));
    let status = Command::new(env::var_os("BUN").unwrap_or_else(|| "bun".into()))
        .current_dir("web")
        .args(["run", "build", "--outDir"])
        .arg(out_dir)
        .arg("--emptyOutDir")
        .status()
        .expect("failed to run Bun; install Bun and run `bun install --frozen-lockfile` in web");
    assert!(status.success(), "admin frontend build failed: {status}");
}
