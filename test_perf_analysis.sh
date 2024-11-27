#!/bin/bash

TEST_DIR="perf_test"

# Define better event groups for comprehensive microarchitecture analysis
EVENT_GROUP_1="cycles,instructions,branch-instructions,branch-misses"
EVENT_GROUP_2="L1-dcache-loads,L1-dcache-load-misses,L1-icache-load-misses"
EVENT_GROUP_3="LLC-loads,LLC-load-misses,LLC-stores,LLC-store-misses"
EVENT_GROUP_4="dTLB-loads,dTLB-load-misses"
EVENT_GROUP_5="iTLB-loads,iTLB-load-misses"
EVENT_GROUP_6="mem-loads,mem-stores,cache-misses,\
node-loads,node-load-misses"

# Attempt to add L2 TLB and PTW events if available
# Check for L2 TLB events
if perf list | grep -q 'dtlb_load_misses.stlb_hit'; then
    EVENT_GROUP_4+=",dtlb_load_misses.stlb_hit"
fi
if perf list | grep -q 'dtlb_load_misses.walk_completed'; then
    EVENT_GROUP_4+=",dtlb_load_misses.walk_completed"
fi
if perf list | grep -q 'dtlb_load_misses.walk_duration'; then
    EVENT_GROUP_4+=",dtlb_load_misses.walk_duration"
fi
# Check for L2 TLB events
if perf list | grep -q 'itlb_misses.walk_completed'; then
    EVENT_GROUP_5+=",itlb_misses.walk_completed"
fi
if perf list | grep -q 'itlb_load_misses.walk_completed'; then
    EVENT_GROUP_5+=",itlb_load_misses.walk_completed"
fi
if perf list | grep -q 'itlb_load_misses.walk_duration'; then
    EVENT_GROUP_5+=",itlb_load_misses.walk_duration"
fi
   
function setup_test() {
    mkdir -p $TEST_DIR
    # Disable kernel pointer restriction and perf paranoid mode
    echo 0 | sudo tee /proc/sys/kernel/kptr_restrict
    echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid
    # Disable NMI watchdog
    echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog
    
    # Ensure proper permissions
    sudo sysctl -w kernel.perf_event_paranoid=-1
    sudo sysctl -w kernel.kptr_restrict=0
    
    # Clear system caches before test
    sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
}

function cleanup_test() {
    # Re-enable NMI watchdog after measurements
    echo 1 | sudo tee /proc/sys/kernel/nmi_watchdog
}

function run_test_workload() {
    local cpu_core=0
    local duration=10
    local result_dir="$TEST_DIR/raw_results"
    mkdir -p "$result_dir"

    # Pin process to CPU and disable frequency scaling
    echo performance | sudo tee /sys/devices/system/cpu/cpu${cpu_core}/cpufreq/scaling_governor

    # Run each group with default perf output format
    for group in {1..6}; do
        eval events=\$EVENT_GROUP_${group}
        sudo perf stat -r 3 \
            -e ${events} \
            --cpu ${cpu_core} \
            -o "$result_dir/perf_group${group}.txt" \
            taskset -c ${cpu_core} stress-ng --cpu 1 --timeout ${duration}s
    done

    # Restore CPU governor
    echo powersave | sudo tee /sys/devices/system/cpu/cpu${cpu_core}/cpufreq/scaling_governor
}

function analyze_perf_data() {
    local result_dir="$TEST_DIR/raw_results"
    local analysis_file="$TEST_DIR/analysis.txt"

    echo "=== Microarchitecture Performance Analysis ===" > "$analysis_file"
    echo "Time: $(date)" >> "$analysis_file"

    # Frontend Analysis
    echo -e "\n=== Frontend Pressure Analysis ===" >> "$analysis_file"
    awk '
        /instructions|branch-misses|L1-icache-load-misses/ {
            if (NF > 1) {
                value = $1
                gsub(/,/, "", value)
                metric = $2
                for (i=3; i<=NF; i++) metric = metric " " $i
                printf "%-40s %15s\n", metric, value
            }
        }
    ' "$result_dir"/perf_group*.txt >> "$analysis_file"

    # Backend Analysis
    echo -e "\n=== Backend Pressure Analysis ===" >> "$analysis_file"
    awk '
        /uops_|int_misc.recovery_cycles/ {
            if (NF > 1) {
                value = $1
                gsub(/,/, "", value)
                metric = $2
                for (i=3; i<=NF; i++) metric = metric " " $i
                printf "%-40s %15s\n", metric, value
            }
        }
    ' "$result_dir"/perf_group*.txt >> "$analysis_file"

    # Cache Analysis
    echo -e "\n=== Cache Pressure Analysis ===" >> "$analysis_file"
    awk '
        /L1-dcache|LLC|cache-misses/ {
            if (NF > 1) {
                value = $1
                gsub(/,/, "", value)
                metric = $2
                for (i=3; i<=NF; i++) metric = metric " " $i
                printf "%-40s %15s\n", metric, value
            }
        }
    ' "$result_dir"/perf_group*.txt >> "$analysis_file"

    # Memory & TLB Analysis
    echo -e "\n=== Memory & TLB Pressure Analysis ===" >> "$analysis_file"
    awk '
        /TLB|mem-/ {
            if (NF > 1) {
                value = $1
                gsub(/,/, "", value)
                metric = $2
                for (i=3; i<=NF; i++) metric = metric " " $i
                printf "%-40s %15s\n", metric, value
            }
        }
    ' "$result_dir"/perf_group*.txt >> "$analysis_file"

    # Calculate derived metrics
    echo -e "\n=== Derived Metrics ===" >> "$analysis_file"
    awk '
        /instructions/ { 
            if (NF > 1) {
                gsub(/,/, "", $1)
                instructions = $1
            }
        }
        /cycles/ { 
            if (NF > 1) {
                gsub(/,/, "", $1)
                cycles = $1
            }
        }
        /LLC-loads/ { 
            if (NF > 1) {
                gsub(/,/, "", $1)
                llc_loads = $1
            }
        }
        /LLC-load-misses/ { 
            if (NF > 1) {
                gsub(/,/, "", $1)
                llc_misses = $1
            }
        }
        END {
            if (cycles > 0) printf "IPC:              %15.2f\n", instructions/cycles
            if (llc_loads > 0) printf "LLC Miss Rate:     %15.2f%%\n", (llc_misses/llc_loads)*100
        }
    ' "$result_dir"/perf_group*.txt >> "$analysis_file"

    # Add detailed TLB analysis section
    echo -e "\n=== Detailed TLB Analysis ===" >> "$analysis_file"
    awk '
        /dTLB-loads/          { dtlb_loads=$1; gsub(/,/,"",dtlb_loads) }
        /dTLB-load-misses/    { dtlb_misses=$1; gsub(/,/,"",dtlb_misses) }
        /stlb_hit/            { stlb_hits=$1; gsub(/,/,"",stlb_hits) }
        /walk_completed.*d/   { dtlb_walks=$1; gsub(/,/,"",dtlb_walks) }
        /walk_duration.*d/    { dtlb_walk_cycles=$1; gsub(/,/,"",dtlb_walk_cycles) }
        /iTLB-loads/          { itlb_loads=$1; gsub(/,/,"",itlb_loads) }
        /iTLB-load-misses/    { itlb_misses=$1; gsub(/,/,"",itlb_misses) }
        END {
            if (dtlb_loads > 0) {
                printf "DTLB Miss Rate:               %15.4f%%\n", (dtlb_misses/dtlb_loads)*100
                if (stlb_hits > 0) {
                    printf "STLB Hit Rate:                %15.4f%%\n", (stlb_hits/dtlb_misses)*100
                }
                if (dtlb_walks > 0) {
                    printf "Page Walk Rate:              %15.4f%%\n", (dtlb_walks/dtlb_misses)*100
                }
                if (dtlb_walk_cycles > 0) {
                    printf "Avg Page Walk Cycles:        %15.2f\n", dtlb_walk_cycles/dtlb_walks
                }
            }
            if (itlb_loads > 0) {
                printf "ITLB Miss Rate:               %15.4f%%\n", (itlb_misses/itlb_loads)*100
            }
        }
    ' "$result_dir"/perf_group*.txt >> "$analysis_file"

    # Calculate overall TLB pressure metrics
    echo -e "\n=== TLB Pressure Summary ===" >> "$analysis_file"
    awk '
        /dTLB-load-misses/    { dtlb_misses=$1; gsub(/,/,"",dtlb_misses) }
        /iTLB-load-misses/    { itlb_misses=$1; gsub(/,/,"",itlb_misses) }
        /cycles/              { cycles=$1; gsub(/,/,"",cycles) }
        END {
            if (cycles > 0) {
                total_tlb_misses = dtlb_misses + itlb_misses
                printf "TLB Misses per 1K Cycles:    %15.2f\n", (total_tlb_misses/cycles)*1000
            }
        }
    ' "$result_dir"/perf_group*.txt >> "$analysis_file"

    cat "$analysis_file"
}

# Install test dependencies
sudo apt-get install -y stress-ng

# Run test
setup_test
run_test_workload
analyze_perf_data
cleanup_test