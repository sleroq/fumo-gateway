mod admin;
mod auth;
mod codex;
mod config;
mod gateway;
mod models;
mod outbound;

use std::path::Path;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("event=command_failed error={error:#}");
        std::process::exit(1);
    }
}

async fn run() -> anyhow::Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 || args[0] != "--config" {
        anyhow::bail!("usage: fumo-gateway --config <path>");
    }
    let config = config::Config::load(Path::new(&args[1]))?;
    gateway::serve(config).await
}
