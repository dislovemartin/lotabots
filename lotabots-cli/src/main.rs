use clap::Parser;
use lotabots_core::{ModelConfig, ModelQuantizer, PyTorchQuantizer};
use lotabots_whatsapp::{TwilioClient, AppState, SharedState, create_router};
use std::sync::Arc;
use tracing::{info, error};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use dotenv::dotenv;
use std::{env, path::PathBuf};
use redis::Client as RedisClient;
use axum::Server;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(short, long, help = "Model identifier on Hugging Face")]
    model: Option<String>,

    #[arg(short, long, help = "Output repository name")]
    output: Option<String>,

    #[arg(short, long, help = "Quantization precision (4 or 8 bits)")]
    bits: Option<u8>,

    #[arg(short, long, help = "Hugging Face API token (or set HF_API_TOKEN env var)")]
    api_token: Option<String>,

    #[arg(long, help = "Cache directory for models (default: ~/.cache/lotabots)")]
    cache_dir: Option<String>,

    #[arg(long, help = "Run as a WhatsApp bot")]
    whatsapp: bool,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Load environment variables
    dotenv().ok();

    // Initialize logging
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let args = Args::parse();

    if args.whatsapp {
        run_whatsapp_bot().await?;
    } else if args.model.is_some() && args.output.is_some() && args.bits.is_some() {
        run_quantization(args).await?;
    } else {
        println!("Please provide the required arguments or use --whatsapp for bot mode.");
    }

    Ok(())
}

async fn run_quantization(args: Args) -> Result<(), Box<dyn std::error::Error>> {
    let model_id = args.model.unwrap();
    let output_repo = args.output.unwrap();
    let bits = args.bits.unwrap();
    let api_token = args.api_token
        .or_else(|| env::var("HF_API_TOKEN").ok())
        .expect("HF_API_TOKEN must be set or passed as an argument");
    
    let cache_dir = args.cache_dir
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = env::var("HOME").unwrap();
            PathBuf::from(home).join(".cache/lotabots")
        });

    info!("Starting model quantization for {} to {} bits", model_id, bits);
    info!("Using cache directory: {}", cache_dir.display());
    info!("Using API token: {}", api_token);

    let config = ModelConfig {
        model_id,
        cache_dir,
        quantization_bits: bits,
    };

    let quantizer = PyTorchQuantizer::new(api_token.clone());
    let quantized_path = quantizer.fetch_and_quantize(&config).await?;
    info!("Model quantized successfully to {:?}", quantized_path);

    info!("Uploading quantized model to {}", output_repo);
    quantizer.upload_model(&quantized_path, &output_repo).await?;
    info!("Model uploaded successfully!");

    println!("Model quantization and upload completed successfully!");
    Ok(())
}

async fn run_whatsapp_bot() -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WhatsApp bot...");

    let twilio_auth_token = env::var("TWILIO_AUTH_TOKEN")
        .expect("TWILIO_AUTH_TOKEN must be set");
    let redis_url = env::var("REDIS_URL")
        .expect("REDIS_URL must be set");
    
    let redis_client = RedisClient::open(redis_url)
        .expect("Failed to create redis client");

    let app_state = Arc::new(AppState {
        twilio_client: TwilioClient::new(twilio_auth_token),
        redis_client,
    });

    let app = create_router(app_state);

    let port = env::var("PORT")
        .unwrap_or_else(|_| "3000".to_string())
        .parse::<u16>()?;
    let addr = format!("0.0.0.0:{}", port);

    info!("Starting server on {}", addr);

    Server::bind(&addr.parse()?)
        .serve(app.into_make_service())
        .await?;

    Ok(())
} 