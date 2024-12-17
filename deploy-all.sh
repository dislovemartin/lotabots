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
DEPLOY_DIR="/opt/lotabots"
FEATURES="gemini"
SKIP_TESTS=false
VERBOSE=false
COMPONENTS=("cli" "whatsapp" "core" "gemini")

# Help message
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -e, --environment ENV    Set deployment environment (development/production) [default: development]"
    echo "  -d, --deploy-dir DIR     Set deployment directory [default: /opt/lotabots]"
    echo "  -f, --features LIST      Set cargo features [default: gemini]"
    echo "  -c, --components LIST    Comma-separated list of components to deploy [default: all]"
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
        -c|--components)
            IFS=',' read -ra COMPONENTS <<< "$2"
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
        log "DEBUG" "nvidia-smi found, checking driver..."

        # Capture driver version with error handling
        DRIVER_VERSION=$(modinfo nvidia 2>/dev/null | grep "^version:" | awk '{print $2}' || echo "unknown")
        log "DEBUG" "NVIDIA driver version: ${DRIVER_VERSION}"

        # Capture nvidia-smi output with timeout
        log "DEBUG" "Running nvidia-smi query..."
        NVIDIA_SMI_OUTPUT=$(timeout 10s nvidia-smi --query-gpu=name,memory.total,compute_mode,temperature.gpu --format=csv,noheader 2>&1)

        # Check the exit status of nvidia-smi
        if [ $? -ne 0 ]; then
            log "DEBUG" "nvidia-smi command failed with output: ${NVIDIA_SMI_OUTPUT}"
            handle_nvidia_error
        elif echo "$NVIDIA_SMI_OUTPUT" | grep -q "Failed to initialize NVML\|NVML library version"; then
            log "DEBUG" "NVML initialization failed"
            handle_nvidia_error
        else
            handle_nvidia_success
        fi
    else
        log "DEBUG" "nvidia-smi command not found"
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

# Function to deploy CLI component
deploy_cli() {
    log "INFO" "Deploying CLI component..."
    cd lotabots-cli

    if [ "$VERBOSE" = true ]; then
        cargo build --release --features "$FEATURES" --verbose
    else
        cargo build --release --features "$FEATURES"
    fi

    if [ "$SKIP_TESTS" = false ]; then
        log "INFO" "Running CLI tests..."
        cargo test --release --features "$FEATURES"
    fi

    mkdir -p "$DEPLOY_DIR/bin"
    cp target/release/lotabots-cli "$DEPLOY_DIR/bin/"
    chmod +x "$DEPLOY_DIR/bin/lotabots-cli"
    cd ..
}

# Function to deploy WhatsApp component
deploy_whatsapp() {
    log "INFO" "Deploying WhatsApp component..."
    cd lotabots-whatsapp

    if [ "$VERBOSE" = true ]; then
        cargo build --release --verbose
    else
        cargo build --release
    fi

    if [ "$SKIP_TESTS" = false ]; then
        log "INFO" "Running WhatsApp tests..."
        cargo test --release
    fi

    mkdir -p "$DEPLOY_DIR/bin"
    cp target/release/lotabots-whatsapp "$DEPLOY_DIR/bin/"
    chmod +x "$DEPLOY_DIR/bin/lotabots-whatsapp"

    # Setup systemd service if running as root
    if [ "$(id -u)" -eq 0 ]; then
        setup_whatsapp_service
    fi
    cd ..
}

# Function to setup WhatsApp systemd service
setup_whatsapp_service() {
    log "INFO" "Setting up WhatsApp systemd service..."
    cat > /etc/systemd/system/lotabots-whatsapp.service << EOF
[Unit]
Description=Lotabots WhatsApp Service
After=network.target redis.service

[Service]
Type=simple
User=lotabots
WorkingDirectory=$DEPLOY_DIR
Environment=RUST_LOG=info
EnvironmentFile=$DEPLOY_DIR/config/.env
ExecStart=$DEPLOY_DIR/bin/lotabots-whatsapp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lotabots-whatsapp
    systemctl restart lotabots-whatsapp
}

# Function to deploy core component
deploy_core() {
    log "INFO" "Deploying core component..."
    cd lotabots-core

    if [ "$VERBOSE" = true ]; then
        cargo build --release --verbose
    else
        cargo build --release
    fi

    if [ "$SKIP_TESTS" = false ]; then
        log "INFO" "Running core tests..."
        cargo test --release
    fi
    cd ..
}

# Function to deploy Gemini component
deploy_gemini() {
    log "INFO" "Deploying Gemini component..."
    cd lotabots-gemini

    if [ "$VERBOSE" = true ]; then
        cargo build --release --verbose
    else
        cargo build --release
    fi

    if [ "$SKIP_TESTS" = false ]; then
        log "INFO" "Running Gemini tests..."
        cargo test --release
    fi
    cd ..
}

# Main deployment function
deploy() {
    log "INFO" "Starting deployment in ${ENVIRONMENT} mode..."

    # Check dependencies
    log "INFO" "Checking dependencies..."
    check_dependency "cargo"
    check_dependency "rustc"

    # Setup environment
    setup_environment

    # Configure GPU
    configure_gpu

    # Create deployment directories
    log "INFO" "Creating deployment directories..."
    mkdir -p "$DEPLOY_DIR"
    mkdir -p "$DEPLOY_DIR/config"
    mkdir -p "$DEPLOY_DIR/logs"

    # Copy configuration
    log "INFO" "Copying configuration files..."
    if [ "$ENVIRONMENT" = "production" ]; then
        cp .env.production "$DEPLOY_DIR/config/.env" 2>/dev/null || true
    else
        cp .env "$DEPLOY_DIR/config/.env" 2>/dev/null || true
    fi

    # Deploy each component
    for component in "${COMPONENTS[@]}"; do
        case $component in
            "cli")
                deploy_cli
                ;;
            "whatsapp")
                deploy_whatsapp
                ;;
            "core")
                deploy_core
                ;;
            "gemini")
                deploy_gemini
                ;;
            *)
                log "WARN" "Unknown component: $component"
                ;;
        esac
    done

    # Print deployment information
    log "INFO" "Deployment complete!"
    log "INFO" "Deployed components: ${COMPONENTS[*]}"
    log "INFO" "Deployment directory: $DEPLOY_DIR"

    log "DEBUG" "Deployment Information:"
    log "DEBUG" "Timestamp: $(date)"
    log "DEBUG" "Rust Version: $(rustc --version)"
    log "DEBUG" "OS: $(uname -a)"
}

# Run deployment
deploy
