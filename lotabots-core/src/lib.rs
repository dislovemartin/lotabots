//! Core traits and types for the Lotabots model quantization pipeline.

use std::path::PathBuf;
use async_trait::async_trait;
use thiserror::Error;
use sysinfo::System;

/// Errors that can occur during model operations
#[derive(Debug, Error)]
pub enum ModelError {
    #[error("Failed to fetch model: {0}")]
    FetchError(String),

    #[error("Failed to quantize model: {0}")]
    QuantizationError(String),

    #[error("Failed to upload model: {0}")]
    UploadError(String),

    #[error("GPU error: {0}")]
    GpuError(String),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("Request error: {0}")]
    RequestError(#[from] reqwest::Error),
}

/// Represents a model's metadata and location
#[derive(Debug, Clone)]
pub struct Model {
    /// Unique identifier for the model
    pub id: String,

    /// Model name/path on Hugging Face
    pub name: String,

    /// Local path where model is stored
    pub path: PathBuf,

    /// Model format (e.g., safetensors, pytorch)
    pub format: String,

    /// Model size in bytes
    pub size: u64,
}

/// Trait for fetching models from remote sources
#[async_trait]
pub trait ModelFetcher {
    /// Fetch a model from its source and store locally
    async fn fetch(&self, name: &str, dest: &PathBuf) -> Result<Model, ModelError>;
}

/// Trait for quantizing models
#[async_trait]
pub trait ModelQuantizer {
    /// Quantize a model to a specified format/precision
    async fn quantize(&self, model: &Model, config: QuantizationConfig) -> Result<Model, ModelError>;
}

/// Trait for uploading quantized models
#[async_trait]
pub trait ModelUploader {
    /// Upload a quantized model to a repository
    async fn upload(&self, model: &Model, repo: &str) -> Result<(), ModelError>;
}

/// Configuration for model quantization
#[derive(Debug, Clone)]
pub struct QuantizationConfig {
    /// Target bits per weight (e.g., 4 for 4-bit quantization)
    pub bits: u8,

    /// Whether to use mixed precision
    pub mixed_precision: bool,

    /// Target device (CPU, CUDA, ROCm)
    pub device: Device,

    /// Additional quantization parameters
    pub params: std::collections::HashMap<String, String>,
}

/// Supported compute devices
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Device {
    CPU,
    CUDA,
    ROCm,
}

/// GPU detection and initialization
pub mod gpu {
    use super::*;

    /// Detect available GPU devices
    pub fn detect_gpus() -> Result<Vec<Device>, ModelError> {
        let _sys = System::new();

        // Check for NVIDIA GPUs
        if std::path::Path::new("/dev/nvidia0").exists() {
            return Ok(vec![Device::CUDA]);
        }

        // Check for AMD GPUs
        if std::path::Path::new("/dev/kfd").exists() {
            return Ok(vec![Device::ROCm]);
        }

        Ok(vec![])
    }

    /// Initialize GPU context
    pub fn init_gpu(device: &Device) -> Result<(), ModelError> {
        match device {
            Device::CPU => Ok(()),
            Device::CUDA => {
                #[cfg(feature = "cuda")]
                {
                    // Initialize CUDA context
                    unsafe {
                        let mut device_id = 0;
                        let result = cuda_runtime_sys::cudaGetDevice(&mut device_id);
                        if result != cuda_runtime_sys::cudaError::cudaSuccess {
                            return Err(ModelError::GpuError(
                                format!("Failed to get CUDA device: error {:?}", result)
                            ));
                        }
                    }
                }
                Ok(())
            }
            Device::ROCm => {
                #[cfg(feature = "rocm")]
                {
                    // TODO: Initialize ROCm context
                }
                Ok(())
            }
        }
    }
}
