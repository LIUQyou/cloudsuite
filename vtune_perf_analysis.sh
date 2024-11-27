#!/bin/bash

TEST_DIR="vtune_test"
RESULT_DIR="$TEST_DIR/results"

function setup_vtune() {
    mkdir -p $TEST_DIR
    mkdir -p $RESULT_DIR
    source /opt/intel/oneapi/vtune/latest/vtune-vars.sh
}

function run_vtune_analysis() {
    local cpu_core=0
    local duration=10  # Match test script duration
    
    # Pin to specific CPU core and set performance governor
    echo performance | sudo tee /sys/devices/system/cpu/cpu${cpu_core}/cpufreq/scaling_governor
    
    # Start workload (matching test script)
    taskset -c ${cpu_core} stress-ng --cpu 1 --timeout ${duration}s &
    local program_pid=$!
    
    # Collect memory analysis
    vtune -collect memory-access \
          -knob analyze-mem-objects=true \
          -duration $duration \
          -result-dir "$RESULT_DIR/memory" \
          -target-pid $program_pid
    
    # Collect cache analysis
    vtune -collect memory-consumption \
          -duration $duration \
          -result-dir "$RESULT_DIR/cache" \
          -target-pid $program_pid
    
    # Collect microarchitecture analysis
    vtune -collect uarch-exploration \
          -knob collect-memory-bandwidth=true \
          -duration $duration \
          -result-dir "$RESULT_DIR/uarch" \
          -target-pid $program_pid
    
    wait $program_pid
    
    # Restore CPU governor
    echo powersave | sudo tee /sys/devices/system/cpu/cpu${cpu_core}/cpufreq/scaling_governor
}

function generate_reports() {
    # Generate detailed reports for each analysis type
    for analysis in memory cache uarch; do
        vtune -report summary \
              -format text \
              -result-dir "$RESULT_DIR/$analysis" \
              -report-output "$TEST_DIR/${analysis}_summary.txt"
              
        vtune -report hotspots \
              -format text \
              -result-dir "$RESULT_DIR/$analysis" \
              -report-output "$TEST_DIR/${analysis}_hotspots.txt"
    done
}

# Main execution
setup_vtune
run_vtune_analysis
generate_reports