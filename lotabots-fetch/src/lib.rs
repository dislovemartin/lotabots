//! Model fetching implementation for Hugging Face models.

use std::path::PathBuf;
use async_trait::async_trait;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};
use lotabots_core::{Model, ModelError, ModelFetcher};

/// Configuration for Hugging Face model fetching
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HuggingFaceConfig {
    /// API token for authentication
    pub token: Option<String>,

    /// Model revision/tag to fetch (defaults to "main")
    pub revision: Option<String>,

    /// Specific filename to fetch (defaults to "model.safetensors")
    pub filename: Option<String>,
}

/// Hugging Face model fetcher implementation
pub struct HuggingFaceFetcher {
    client: Client,
    config: HuggingFaceConfig,
}

impl HuggingFaceFetcher {
    /// Create a new Hugging Face fetcher instance
    pub fn new(config: HuggingFaceConfig) -> Self {
        let client = Client::new();
        Self { client, config }
    }

    /// Build the model URL
    fn build_url(&self, model_name: &str) -> String {
        let revision = self.config.revision.as_deref().unwrap_or("main");
        let filename = self.config.filename.as_deref().unwrap_or("model.safetensors");

        format!(
            "https://huggingface.co/{}/resolve/{}/{}",
            model_name, revision, filename
        )
    }
}

#[async_trait]
impl ModelFetcher for HuggingFaceFetcher {
    async fn fetch(&self, name: &str, dest: &PathBuf) -> Result<Model, ModelError> {
        let url = self.build_url(name);
        info!("Fetching model from {}", url);

        // Build request with optional authentication
        let mut request = self.client.get(&url);
        if let Some(token) = &self.config.token {
            request = request.header("Authorization", format!("Bearer {}", token));
        }

        // Send request and get response
        let response = request.send().await
            .map_err(|e| ModelError::FetchError(e.to_string()))?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await
                .unwrap_or_else(|_| "Unknown error".to_string());
            return Err(ModelError::FetchError(
                format!("HTTP {} - {}", status, text)
            ));
        }

        // Get content length if available
        let size = response.content_length()
            .unwrap_or(0);

        // Stream response to file
        let bytes = response.bytes().await
            .map_err(|e| ModelError::FetchError(e.to_string()))?;

        // Create parent directories if needed
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)
                .map_err(ModelError::IoError)?;
        }

        // Write to file
        std::fs::write(dest, bytes)
            .map_err(ModelError::IoError)?;

        info!("Model downloaded to {:?}", dest);

        Ok(Model {
            id: name.to_string(),
            name: name.to_string(),
            path: dest.clone(),
            format: "safetensors".to_string(),
            size,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::test;

    #[test]
    async fn test_fetch_small_model() {
        let config = HuggingFaceConfig {
            token: None,
            revision: None,
            filename: Some("config.json".into()),
        };

        let fetcher = HuggingFaceFetcher::new(config);
        let dest = PathBuf::from("test_model.json");

        let result = fetcher.fetch("bert-base-uncased", &dest).await;
        assert!(result.is_ok());

        // Cleanup
        std::fs::remove_file(dest).ok();
    }
}
