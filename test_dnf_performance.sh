#!/bin/bash

# DNF Performance and Contention Test Script
# Tests different DNF parallelism configurations to find optimal settings

echo "=== DNF Performance and Contention Test ==="
echo "Testing different configurations to evaluate performance and reliability"
echo "Date: $(date)"
echo "System: $(uname -a)"
echo

# Test configurations
declare -a test_configs=(
    "default:Default settings"
    "serial:--dnf-serial"
    "low-parallel:--parallel 1"
    "conservative:--parallel 2" 
    "dry-run:--dry-run --debug 1"
    "name-filter:--name-filter 'kernel' --debug 1"
)

# Log directory for test results
test_log_dir="/tmp/dnf_perf_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$test_log_dir"

echo "Test results will be saved in: $test_log_dir"
echo

# Function to run a single test
run_test() {
    local test_name="$1"
    local test_description="$2"
    local test_args="$3"
    local log_file="$test_log_dir/${test_name}.log"
    
    echo "----------------------------------------"
    echo "TEST: $test_name ($test_description)"
    echo "Args: $test_args"
    echo "Log:  $log_file"
    echo "----------------------------------------"
    
    local start_time=$(date +%s)
    echo "Start time: $(date)" | tee "$log_file"
    
    # Run the test with timeout to prevent hanging
    if timeout 600 bash ./myrepo.sh $test_args --max-packages 50 2>&1 | tee -a "$log_file"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        echo "SUCCESS: Test completed in ${duration}s" | tee -a "$log_file"
        
        # Extract key metrics
        local dnf_calls=$(grep -c "Fetching metadata" "$log_file" || echo "0")
        local retries=$(grep -c "retrying" "$log_file" || echo "0")
        local errors=$(grep -c "ERROR" "$log_file" || echo "0")
        local warnings=$(grep -c "WARN" "$log_file" || echo "0")
        local packages_processed=$(grep "packages processed" "$log_file" | tail -1 | grep -o '[0-9]\+' | head -1 || echo "0")
        
        echo "METRICS:" | tee -a "$log_file"
        echo "  Duration: ${duration}s" | tee -a "$log_file"
        echo "  DNF calls: $dnf_calls" | tee -a "$log_file"
        echo "  Retries: $retries" | tee -a "$log_file"
        echo "  Errors: $errors" | tee -a "$log_file"
        echo "  Warnings: $warnings" | tee -a "$log_file"
        echo "  Packages processed: $packages_processed" | tee -a "$log_file"
        
        # Check for specific performance indicators
        if grep -q "Reducing DNF parallelism" "$log_file"; then
            echo "  Note: Adaptive parallelism reduction occurred" | tee -a "$log_file"
        fi
        if grep -q "Using serial DNF mode" "$log_file"; then
            echo "  Note: Serial DNF mode was used" | tee -a "$log_file"
        fi
        if grep -q "database lock" "$log_file"; then
            echo "  Note: Database lock issues detected" | tee -a "$log_file"
        fi
        
        echo "  Rate: $((packages_processed * 60 / (duration + 1))) pkg/min" | tee -a "$log_file"
        
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "FAILED: Test timed out or failed after ${duration}s" | tee -a "$log_file"
        
        # Look for failure reasons
        if grep -q "timeout" "$log_file"; then
            echo "  Reason: DNF timeout" | tee -a "$log_file"
        fi
        if grep -q "lock" "$log_file"; then
            echo "  Reason: Database lock contention" | tee -a "$log_file"
        fi
        if grep -q "Failed to fetch" "$log_file"; then
            echo "  Reason: Network/repository issues" | tee -a "$log_file"
        fi
    fi
    
    echo
}

# Pre-test system check
echo "=== PRE-TEST SYSTEM CHECK ==="
echo "DNF version: $(dnf --version 2>/dev/null || echo 'DNF not found')"
echo "Available memory: $(free -h | grep Mem: | awk '{print $7}')"
echo "Load average: $(uptime | awk -F'load average:' '{print $2}')"
echo "Active DNF processes: $(pgrep -c dnf || echo 0)"
echo

# Kill any existing DNF processes to start clean
if pgrep dnf >/dev/null; then
    echo "WARNING: Found existing DNF processes. Waiting for them to finish..."
    timeout 60 bash -c 'while pgrep dnf >/dev/null; do sleep 5; done' || echo "DNF processes still running, proceeding anyway"
fi

# Run each test configuration
for config in "${test_configs[@]}"; do
    IFS=':' read -r test_name test_description <<< "$config"
    
    case "$test_name" in
        "default")
            run_test "$test_name" "$test_description" ""
            ;;
        "serial")
            run_test "$test_name" "$test_description" "--dnf-serial"
            ;;
        "low-parallel")
            run_test "$test_name" "$test_description" "--parallel 1"
            ;;
        "conservative")
            run_test "$test_name" "$test_description" "--parallel 2"
            ;;
        "dry-run")
            run_test "$test_name" "$test_description" "--dry-run --debug 1"
            ;;
        "name-filter")
            run_test "$test_name" "$test_description" "--name-filter 'kernel' --debug 1"
            ;;
    esac
    
    # Brief pause between tests
    sleep 5
done

# Generate summary report
echo "=== TEST SUMMARY REPORT ==="
summary_file="$test_log_dir/summary.txt"

{
    echo "DNF Performance Test Summary"
    echo "Generated: $(date)"
    echo "Test directory: $test_log_dir"
    echo
    echo "Configuration Results:"
    echo "======================"
    
    for config in "${test_configs[@]}"; do
        IFS=':' read -r test_name test_description <<< "$config"
        log_file="$test_log_dir/${test_name}.log"
        
        if [[ -f "$log_file" ]]; then
            echo
            echo "Test: $test_name ($test_description)"
            if grep -q "SUCCESS:" "$log_file"; then
                duration=$(grep "Duration:" "$log_file" | awk '{print $2}')
                rate=$(grep "Rate:" "$log_file" | awk '{print $2}')
                retries=$(grep "Retries:" "$log_file" | awk '{print $2}')
                errors=$(grep "Errors:" "$log_file" | awk '{print $2}')
                echo "  Status: SUCCESS"
                echo "  Duration: $duration"
                echo "  Rate: $rate"
                echo "  Retries: $retries"
                echo "  Errors: $errors"
            else
                echo "  Status: FAILED"
                if grep -q "Reason:" "$log_file"; then
                    grep "Reason:" "$log_file" | head -1
                fi
            fi
        else
            echo "Test: $test_name - NO LOG FILE"
        fi
    done
    
    echo
    echo "RECOMMENDATIONS:"
    echo "================"
    
    # Find the fastest successful test
    fastest_test=""
    fastest_duration=999999
    for config in "${test_configs[@]}"; do
        IFS=':' read -r test_name _ <<< "$config"
        log_file="$test_log_dir/${test_name}.log"
        
        if [[ -f "$log_file" ]] && grep -q "SUCCESS:" "$log_file"; then
            duration=$(grep "Duration:" "$log_file" | awk '{print $2}' | sed 's/s//')
            if [[ $duration -lt $fastest_duration ]]; then
                fastest_duration=$duration
                fastest_test=$test_name
            fi
        fi
    done
    
    if [[ -n "$fastest_test" ]]; then
        echo "Fastest successful configuration: $fastest_test (${fastest_duration}s)"
    fi
    
    # Check for reliability issues
    problematic_tests=""
    for config in "${test_configs[@]}"; do
        IFS=':' read -r test_name _ <<< "$config"
        log_file="$test_log_dir/${test_name}.log"
        
        if [[ -f "$log_file" ]]; then
            retries=$(grep "Retries:" "$log_file" | awk '{print $2}')
            if [[ $retries -gt 0 ]]; then
                problematic_tests="$problematic_tests $test_name"
            fi
        fi
    done
    
    if [[ -n "$problematic_tests" ]]; then
        echo "Configurations with retry issues:$problematic_tests"
        echo "Consider using --dnf-serial for environments with DNF contention"
    fi
    
} | tee "$summary_file"

echo
echo "=== TESTING COMPLETE ==="
echo "Detailed results: $test_log_dir"
echo "Summary report: $summary_file"
echo
echo "To view results:"
echo "  cat $summary_file"
echo "  ls -la $test_log_dir"
