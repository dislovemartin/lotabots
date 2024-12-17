#!/bin/bash
set -euo pipefail

# Color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ENVIRONMENT="development"
DEPLOY_DIR="../deploy"
FEATURES="gemini"
SKIP_TESTS=false
VERBOSE=false

# Help message
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -e, --environment ENV    Set deployment environment (development/production) [default: development]"
    echo "  -d, --deploy-dir DIR     Set deployment directory [default: ../deploy]"
    echo "  -f, --features LIST      Set cargo features [default: gemini]"
    echo "  -s, --skip-tests         Skip running tests"
    echo "  -v, --verbose            Enable verbose output"
    echo "  -h, --help              Show this help message"
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -d|--deploy-dir)
            DEPLOY_DIR="$2"
            shift 2
            ;;
        -f|--features)
            FEATURES="$2"
            shift 2
            ;;
        -s|--skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            ;;
    esac
done

# Function to log messages
log() {
    local level=$1
    local message=$2
    local color=$NC
    local prefix=""

    case $level in
        "INFO")
            color=$GREEN
            prefix="ℹ️"
            ;;
        "WARN")
            color=$YELLOW
            prefix="⚠️"
            ;;
        "ERROR")
            color=$RED
            prefix="❌"
            ;;
        "DEBUG")
            if [ "$VERBOSE" = true ]; then
                color=$BLUE
                prefix="🔍"
            else
                return
            fi
            ;;
    esac

    echo -e "${color}${prefix} ${message}${NC}"
}

# Function to check dependencies
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        log "ERROR" "Required dependency not found: $1"
        echo "Please install $1 and try again"
        exit 1
    fi
}

# Function to setup environment
setup_environment() {
    local env_file=".env"
    if [ "$ENVIRONMENT" = "production" ]; then
        env_file=".env.production"
    fi

    if [ ! -f "$env_file" ]; then
        log "WARN" "$env_file file not found, using default .env"
        env_file=".env"
        if [ ! -f "$env_file" ]; then
            log "ERROR" "No environment file found"
            echo "Please create either .env or .env.production"
            exit 1
        fi
    fi

    log "INFO" "Using environment file: $env_file"
    # shellcheck source=/dev/null
    source "$env_file"
}

# Function to configure GPU settings
configure_gpu() {
    log "INFO" "Checking GPU configuration..."
    if command -v nvidia-smi &> /dev/null; then
        DRIVER_VERSION=$(modinfo nvidia | grep "^version:" | awk '{print $2}' || echo "unknown")
        log "DEBUG" "NVIDIA driver version: ${DRIVER_VERSION}"

        NVIDIA_SMI_OUTPUT=$(nvidia-smi --query-gpu=name,memory.total,compute_mode,temperature.gpu --format=csv,noheader 2>&1)
        if echo "$NVIDIA_SMI_OUTPUT" | grep -q "Failed to initialize NVML\|NVML library version"; then
            handle_nvidia_error
        else
            handle_nvidia_success
        fi
    else
        log "WARN" "NVIDIA GPU not detected - falling back to CPU mode"
        export RUSTFLAGS="-C target-cpu=native"
    fi
}

# Function to handle NVIDIA driver errors
handle_nvidia_error() {
    NVML_VERSION=$(echo "$NVIDIA_SMI_OUTPUT" | grep "NVML library version" | awk '{print $NF}' || echo "unknown")
    log "WARN" "NVIDIA driver/library version mismatch detected"
    log "DEBUG" "Current driver version: ${DRIVER_VERSION}"
    log "DEBUG" "NVML library version: ${NVML_VERSION}"

    if [ "$ENVIRONMENT" = "production" ]; then
        log "ERROR" "GPU configuration error in production environment"
        exit 1
    fi

    log "WARN" "Continuing with CPU-only mode..."
    export RUSTFLAGS="-C target-cpu=native"
}

# Function to handle successful NVIDIA detection
handle_nvidia_success() {
    log "INFO" "NVIDIA GPU detected and NVML initialized successfully"
    log "DEBUG" "GPU Information:"
    log "DEBUG" "$NVIDIA_SMI_OUTPUT"

    CUDA_VERSION=$(nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>/dev/null || echo "unknown")
    log "DEBUG" "CUDA Version: ${CUDA_VERSION}"

    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        export RUSTFLAGS="-C target-cpu=native -C target-feature=+avx2"
    else
        export RUSTFLAGS="-C target-cpu=native"
    fi
}

# Main deployment function
deploy() {
    log "INFO" "Starting deployment in ${ENVIRONMENT} mode..."

    # Check dependencies
    log "INFO" "Checking dependencies..."
    check_dependency "cargo"
    check_dependency "rustc"

    # Check directory
    if [ ! -f "lotabots-cli/Cargo.toml" ]; then
        log "ERROR" "Must be run from the root directory containing lotabots-cli/"
        exit 1
    fi

    # Setup environment
    setup_environment

    # Configure GPU
    configure_gpu

    # Clean and build
    log "INFO" "Cleaning previous builds..."
    cd lotabots-cli
    cargo clean

    log "INFO" "Building with optimizations..."
    if [ "$VERBOSE" = true ]; then
        cargo build --release --features "$FEATURES" --verbose
    else
        cargo build --release --features "$FEATURES"
    fi

    # Run tests if not skipped
    if [ "$SKIP_TESTS" = false ]; then
        log "INFO" "Running tests..."
        if [ "$VERBOSE" = true ]; then
            cargo test --release --features "$FEATURES" --verbose
        else
            cargo test --release --features "$FEATURES"
        fi
    else
        log "WARN" "Skipping tests"
    fi

    # Setup deployment directory
    log "INFO" "Setting up deployment directory..."
    mkdir -p "$DEPLOY_DIR"
    mkdir -p "$DEPLOY_DIR/config"

    # Copy files
    log "INFO" "Copying files..."
    cp target/release/lotabots-cli "$DEPLOY_DIR/"
    cp ../README.md "$DEPLOY_DIR/" 2>/dev/null || true

    if [ "$ENVIRONMENT" = "production" ]; then
        cp ../.env.production "$DEPLOY_DIR/config/.env" 2>/dev/null || true
    else
        cp ../.env "$DEPLOY_DIR/config/.env" 2>/dev/null || true
    fi

    # Set permissions
    chmod +x "$DEPLOY_DIR/lotabots-cli"

    # Verify deployment
    log "INFO" "Verifying deployment..."
    if [ -x "$DEPLOY_DIR/lotabots-cli" ]; then
        log "INFO" "Binary successfully deployed and executable"
        "$DEPLOY_DIR/lotabots-cli" --version || true
    else
        log "ERROR" "Deployment verification failed"
        exit 1
    fi

    # Print deployment information
    log "INFO" "Deployment complete!"
    log "INFO" "Binary is available in ${DEPLOY_DIR}/"
    log "INFO" "Run the bot with: ${DEPLOY_DIR}/lotabots-cli"

    log "DEBUG" "Deployment Information:"
    log "DEBUG" "Timestamp: $(date)"
    log "DEBUG" "Rust Version: $(rustc --version)"
    log "DEBUG" "OS: $(uname -a)"
}

# Run deployment
deploy
