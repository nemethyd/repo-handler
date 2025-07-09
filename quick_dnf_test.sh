#!/bin/bash

# Quick DNF Performance Comparison Test
echo "=== Quick DNF Performance Comparison ==="
echo "Testing parallel vs serial DNF modes with the same workload"
echo

test_args="--user-mode --dry-run --max-packages 15 --name-filter 'bash'"

echo "Test configuration: $test_args"
echo

# Test 1: Parallel mode (default)
echo "TEST 1: Parallel DNF Mode (default)"
echo "====================================="
start_time=$(date +%s)
./myrepo.sh $test_args 2>&1 | grep -E "(Using .* DNF mode|Repository metadata download completed|Batch completed)" | head -10
end_time=$(date +%s)
parallel_duration=$((end_time - start_time))
echo "Parallel mode total time: ${parallel_duration}s"
echo

# Brief pause
sleep 3

# Test 2: Serial mode  
echo "TEST 2: Serial DNF Mode"
echo "======================="
start_time=$(date +%s)
./myrepo.sh $test_args --dnf-serial 2>&1 | grep -E "(Using .* DNF mode|Repository metadata download completed|Batch completed)" | head -10
end_time=$(date +%s)
serial_duration=$((end_time - start_time))
echo "Serial mode total time: ${serial_duration}s"
echo

# Comparison
echo "PERFORMANCE COMPARISON:"
echo "======================"
echo "Parallel mode: ${parallel_duration}s"
echo "Serial mode:   ${serial_duration}s"

if [[ $serial_duration -lt $parallel_duration ]]; then
    improvement=$(( (parallel_duration - serial_duration) * 100 / parallel_duration ))
    echo "Result: Serial mode is ${improvement}% faster!"
    echo "Recommendation: Use --dnf-serial flag for better performance"
else
    degradation=$(( (serial_duration - parallel_duration) * 100 / serial_duration ))
    echo "Result: Parallel mode is ${degradation}% faster"
    echo "Recommendation: Keep default parallel mode"
fi
