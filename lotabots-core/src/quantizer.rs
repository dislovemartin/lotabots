use crate::{ModelConfig, ModelQuantizer, ModelFetcher, ModelQuantization, Result, CoreError};
use async_trait::async_trait;
use std::path::PathBuf;
use tch::{Device, Tensor, nn};
use tracing::{info, warn};
use huggingface_hub::api::sync::ApiBuilder;

pub struct PyTorchQuantizer {
    api_token: String,
}

impl PyTorchQuantizer {
    pub fn new(api_token: String) -> Self {
        Self { api_token }
    }

    fn get_device() -> Device {
        if tch::Cuda::is_available() {
            info!("CUDA is available, using GPU");
            Device::Cuda(0)
        } else {
            warn!("CUDA is not available, falling back to CPU");
            Device::Cpu
        }
    }
}

#[async_trait]
impl ModelFetcher for PyTorchQuantizer {
    async fn fetch_model(&self, model_id: &str, cache_dir: &PathBuf) -> Result<PathBuf> {
        info!("Fetching model {} to {:?}", model_id, cache_dir);
        
        // Create cache directory if it doesn't exist
        tokio::fs::create_dir_all(cache_dir).await
            .map_err(|e| CoreError::IOError(e))?;

        // Initialize Hugging Face API client
        let api = ApiBuilder::new()
            .with_token(self.api_token.clone())
            .build()
            .map_err(|e| CoreError::ModelFetchError(e.to_string()))?;

        // Download model files
        let model_path = cache_dir.join(model_id.replace('/', "_"));
        api.model(model_id).get(&model_path)
            .map_err(|e| CoreError::ModelFetchError(e.to_string()))?;

        Ok(model_path)
    }
}

#[async_trait]
impl ModelQuantization for PyTorchQuantizer {
    async fn quantize(&self, model_path: &PathBuf, bits: u8) -> Result<PathBuf> {
        info!("Quantizing model at {:?} to {} bits", model_path, bits);

        // Load the model
        let device = Self::get_device();
        let model = tch::CModule::load(model_path)
            .map_err(|e| CoreError::QuantizationError(format!("Failed to load model: {}", e)))?;

        // Prepare quantization config based on bit depth
        let qconfig = match bits {
            4 => nn::QConfigBuilder::new()
                .with_activation_dtype(tch::Kind::QInt4)
                .with_weight_dtype(tch::Kind::QInt4)
                .build(),
            8 => nn::QConfigBuilder::new()
                .with_activation_dtype(tch::Kind::QInt8)
                .with_weight_dtype(tch::Kind::QInt8)
                .build(),
            _ => return Err(CoreError::QuantizationError(
                format!("Unsupported bit depth: {}", bits)
            )),
        };

        // Quantize the model
        let quantized_model = model.quantize(qconfig)
            .map_err(|e| CoreError::QuantizationError(format!("Quantization failed: {}", e)))?;

        // Save the quantized model
        let output_path = model_path.with_extension(format!("quantized_{}_bit.pt", bits));
        quantized_model.save(&output_path)
            .map_err(|e| CoreError::QuantizationError(format!("Failed to save quantized model: {}", e)))?;

        Ok(output_path)
    }
}

#[async_trait]
impl ModelQuantizer for PyTorchQuantizer {
    async fn fetch_and_quantize(&self, config: &ModelConfig) -> Result<PathBuf> {
        // First fetch the model
        let model_path = self.fetch_model(&config.model_id, &config.cache_dir).await?;
        
        // Then quantize it
        self.quantize(&model_path, config.quantization_bits).await
    }

    async fn upload_model(&self, model_path: &PathBuf, repo_id: &str) -> Result<()> {
        info!("Uploading quantized model to {}", repo_id);

        let api = ApiBuilder::new()
            .with_token(self.api_token.clone())
            .build()
            .map_err(|e| CoreError::ModelFetchError(e.to_string()))?;

        api.create_repo(repo_id, None)
            .map_err(|e| CoreError::ModelFetchError(format!("Failed to create repo: {}", e)))?;

        api.upload_file(repo_id, model_path)
            .map_err(|e| CoreError::ModelFetchError(format!("Failed to upload model: {}", e)))?;

        Ok(())
    }
} 