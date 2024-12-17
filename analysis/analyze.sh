#!/bin/bash
set -euo pipefail

# Color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Timestamp for logs
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="logs"
METRICS_DIR="metrics"

echo -e "${GREEN}📊 Starting System Analysis...${NC}"

# Function to check system resources
check_system_resources() {
    echo -e "\n${YELLOW}💻 System Resources:${NC}"
    echo "CPU Usage:"
    top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' > "$METRICS_DIR/cpu_usage_$TIMESTAMP.txt"
    free -m | tee "$METRICS_DIR/memory_usage_$TIMESTAMP.txt"
    df -h | tee "$METRICS_DIR/disk_usage_$TIMESTAMP.txt"
}

# Function to check GPU status if available
check_gpu_status() {
    if command -v nvidia-smi &> /dev/null; then
        echo -e "\n${YELLOW}🎮 GPU Status:${NC}"
        nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv > "$METRICS_DIR/gpu_metrics_$TIMESTAMP.csv"
        cat "$METRICS_DIR/gpu_metrics_$TIMESTAMP.csv"
    else
        echo -e "\n${YELLOW}⚠️ No NVIDIA GPU detected${NC}"
    fi
}

# Function to analyze logs
analyze_logs() {
    echo -e "\n${YELLOW}📝 Log Analysis:${NC}"
    if [ -d "../deploy/logs" ]; then
        echo "Analyzing deployment logs..."
        grep -i "error\|warning\|critical" ../deploy/logs/* 2>/dev/null | tee "$LOG_DIR/error_summary_$TIMESTAMP.txt" || true
    fi
}

# Function to check Rust binary health
check_binary_health() {
    echo -e "\n${YELLOW}🔍 Binary Health Check:${NC}"
    if [ -f "../deploy/lotabots-cli" ]; then
        file "../deploy/lotabots-cli" > "$METRICS_DIR/binary_info_$TIMESTAMP.txt"
        ldd "../deploy/lotabots-cli" 2>/dev/null > "$METRICS_DIR/dependencies_$TIMESTAMP.txt" || true
    else
        echo -e "${RED}❌ Binary not found in deploy directory${NC}"
    fi
}

# Function to generate performance report
generate_report() {
    echo -e "\n${YELLOW}📊 Generating Performance Report...${NC}"
    {
        echo "=== Performance Report ==="
        echo "Generated at: $(date)"
        echo -e "\nSystem Resources:"
        cat "$METRICS_DIR/cpu_usage_$TIMESTAMP.txt" 2>/dev/null || echo "No CPU data"
        echo -e "\nMemory Usage:"
        cat "$METRICS_DIR/memory_usage_$TIMESTAMP.txt" 2>/dev/null || echo "No memory data"
        echo -e "\nGPU Status:"
        cat "$METRICS_DIR/gpu_metrics_$TIMESTAMP.csv" 2>/dev/null || echo "No GPU data"
        echo -e "\nError Summary:"
        cat "$LOG_DIR/error_summary_$TIMESTAMP.txt" 2>/dev/null || echo "No errors found"
    } > "reports/performance_report_$TIMESTAMP.txt"
}

# Create necessary directories
mkdir -p "$LOG_DIR" "$METRICS_DIR" "reports"

# Run all checks
check_system_resources
check_gpu_status
analyze_logs
check_binary_health
generate_report

echo -e "\n${GREEN}✅ Analysis Complete!${NC}"
echo -e "Reports available in: ${YELLOW}$(pwd)/reports${NC}" 