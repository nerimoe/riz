mod config;
mod db;
mod files;
mod provider;
mod server;
mod skills;
mod state;
mod terminal;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use config::{Config, data_dir};
use db::Database;
use state::AppState;
use std::net::SocketAddr;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "rizd", version, about = "Riz remote agent daemon")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}
#[derive(Subcommand)]
enum Commands {
    Init {
        #[arg(long, default_value = "127.0.0.1:7497")]
        listen: SocketAddr,
    },
    Serve,
    Token {
        #[command(subcommand)]
        command: TokenCommand,
    },
    Doctor,
}
#[derive(Subcommand)]
enum TokenCommand {
    Rotate,
    Issue {
        #[arg(long, default_value = "client")]
        name: String,
    },
    List,
    Revoke {
        id: uuid::Uuid,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("rizd=info,tower_http=info")),
        )
        .init();
    let cli = Cli::parse();
    let home = data_dir();
    let config_path = home.join("config.json");
    match cli.command.unwrap_or(Commands::Serve) {
        Commands::Init { listen } => {
            let (c, token) = Config::create(&config_path, listen)?;
            println!(
                "Riz daemon initialized\nDaemon ID: {}\nEndpoint: ws://{}/ws\nToken: {}\n\nThe token is shown once. Store it securely.",
                c.daemon_id, c.listen, token
            );
        }
        Commands::Serve => {
            let config = Config::load(&config_path).with_context(|| {
                format!(
                    "Riz is not initialized. Run `rizd init` first (expected {})",
                    config_path.display()
                )
            })?;
            let db = Database::open(&home.join("riz.db"))?;
            server::serve(AppState::new(config, db)).await?;
        }
        Commands::Token {
            command: TokenCommand::Rotate,
        } => {
            let mut config = Config::load(&config_path)?;
            let token = config.rotate_token(&config_path)?;
            println!("{token}");
        }
        Commands::Token {
            command: TokenCommand::Issue { name },
        } => {
            let mut config = Config::load(&config_path)?;
            let (id, token) = config.issue_token(&config_path, name)?;
            println!("Token ID: {id}\nToken: {token}");
        }
        Commands::Token {
            command: TokenCommand::List,
        } => {
            let config = Config::load(&config_path)?;
            let tokens = config
                .issued_tokens
                .iter()
                .map(|token| {
                    serde_json::json!({
                        "id": token.id,
                        "name": token.name,
                        "createdAt": token.created_at,
                    })
                })
                .collect::<Vec<_>>();
            println!("{}", serde_json::to_string_pretty(&tokens)?);
        }
        Commands::Token {
            command: TokenCommand::Revoke { id },
        } => {
            let mut config = Config::load(&config_path)?;
            if !config.revoke_token(&config_path, id)? {
                anyhow::bail!("token not found: {id}");
            }
            println!("revoked {id}");
        }
        Commands::Doctor => {
            let config = Config::load(&config_path).ok();
            let agy = std::process::Command::new("agy")
                .arg("--help")
                .output()
                .ok()
                .is_some_and(|o| o.status.success());
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &serde_json::json!({"config":config,"agyInstalled":agy,"dataDir":home})
                )?
            );
        }
    }
    Ok(())
}
