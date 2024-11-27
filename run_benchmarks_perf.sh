#!/bin/bash

# Add output directories
OUTPUT_DIR="benchmark_results"
PERF_DATA_DIR="$OUTPUT_DIR/perf_data"
LOG_DIR="$OUTPUT_DIR/logs"
REPORT_DIR="$OUTPUT_DIR/reports"
ANALYSIS_DIR="$OUTPUT_DIR/analysis"

# Define perf event groups
EVENT_GROUP_1="cycles,instructions,branch-instructions,branch-misses"
EVENT_GROUP_2="L1-dcache-loads,L1-dcache-load-misses,L1-icache-load-misses"
EVENT_GROUP_3="LLC-loads,LLC-load-misses,LLC-stores,LLC-store-misses"
EVENT_GROUP_4="dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses"
EVENT_GROUP_5="mem-loads,mem-stores,cache-misses,node-loads,node-load-misses"

# Add new variables for monitoring control
MONITOR_INTERVAL=1000  # ms
SELECTED_GROUP=1       # default group
CONTAINER_PIDS=()
CONTAINER_CPUS=()
PERF_PIDS=()

function wait_for_container() {
    local container_name=$1
    local max_retries=30
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        if docker inspect --format='{{.State.Running}}' $container_name 2>/dev/null | grep -q "true"; then
            sleep 2  # Give the process a moment to stabilize
            return 0
        fi
        sleep 1
        ((retry++))
    done
    return 1
}

function get_container_pid() {
    local container_name=$1
    local max_retries=5
    local retry=0
    local pid
    
    while [ $retry -lt $max_retries ]; do
        pid=$(docker inspect --format '{{.State.Pid}}' $container_name 2>/dev/null)
        if [ -n "$pid" ] && [ "$pid" -gt 0 ]; then
            echo $pid
            return 0
        fi
        sleep 1
        ((retry++))
    done
    return 1
}

function get_container_cpu_affinity() {
    local pid=$1
    if [ -e "/proc/$pid" ]; then
        taskset -p $pid 2>/dev/null | awk '{print $NF}' || echo "0"
    else
        echo "0"
    fi
}

function monitor_container() {
    local container_name=$1
    
    # Wait for container to be running
    if ! wait_for_container "$container_name"; then
        echo "Error: Container $container_name failed to start" >&2
        return 1
    fi
    
    # Get container PID
    local pid=$(get_container_pid "$container_name")
    if [ -z "$pid" ] || [ "$pid" -eq 0 ]; then
        echo "Error: Could not get PID for container $container_name" >&2
        return 1
    fi
    
    local cpu_affinity=$(get_container_cpu_affinity $pid)
    
    CONTAINER_PIDS+=($pid)
    CONTAINER_CPUS+=($cpu_affinity)
    
    # Select events based on group
    local events
    case $SELECTED_GROUP in
        1) events=$EVENT_GROUP_1 ;;
        2) events=$EVENT_GROUP_2 ;;
        3) events=$EVENT_GROUP_3 ;;
        4) events=$EVENT_GROUP_4 ;;
        5) events=$EVENT_GROUP_5 ;;
        *) events=$EVENT_GROUP_1 ;;
    esac
    
    # Start perf monitoring for this container
    local perf_output="$PERF_DATA_DIR/${container_name}_group${SELECTED_GROUP}.txt"
    if sudo perf stat -x ',' -e $events -p $pid -I $MONITOR_INTERVAL -o $perf_output 2>/dev/null & then
        PERF_PIDS+=($!)
        echo "Started monitoring container $container_name (PID: $pid)" | tee -a $LOG_FILE
    else
        echo "Error: Failed to start perf monitoring for container $container_name" >&2
        return 1
    fi
}

function setup_dirs() {
    mkdir -p $PERF_DATA_DIR
    mkdir -p $LOG_DIR
    mkdir -p $REPORT_DIR
    mkdir -p $ANALYSIS_DIR
    timestamp=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="$LOG_DIR/perf_benchmark_${timestamp}.log"
    REPORT_FILE="$REPORT_DIR/perf_report_${timestamp}.txt"
}

function analyze_perf_data() {
    local benchmark=$1
    local perf_file="$PERF_DATA_DIR/${benchmark}_stats.txt"
    local analysis_file="$ANALYSIS_DIR/${benchmark}_analysis.txt"
    
    # Debug: Print raw perf data
    echo "Raw perf data for $benchmark:" >> "$LOG_FILE"
    cat "$perf_file" >> "$LOG_FILE"
    
    {
        echo "=== Performance Analysis for $benchmark ==="
        echo "Time: $(date)"
        
        echo -e "\nInstructions per Cycle (IPC):"
        awk -F',' '
            /instructions/ { 
                inst=$1
                gsub("[^0-9.]", "", inst)
                print "Instructions:", inst
            }
            /cycles/ {
                cycles=$1
                gsub("[^0-9.]", "", cycles)
                print "Cycles:", cycles
            }
            END {
                if (cycles > 0) printf "IPC: %.2f\n", inst/cycles
                else print "IPC: N/A"
            }
        ' "$perf_file"
        
        echo -e "\nCache Statistics:"
        awk -F',' '
            /L1-dcache-load-misses/ {
                l1miss=$1
                gsub("[^0-9.]", "", l1miss)
                print "L1 misses:", l1miss
            }
            /L1-dcache-loads/ {
                l1total=$1
                gsub("[^0-9.]", "", l1total)
                print "L1 total:", l1total
            }
            END {
                if (l1total > 0 && l1miss <= l1total) 
                    printf "L1 Miss Rate: %.2f%%\n", (l1miss/l1total)*100
                else print "L1 Miss Rate: N/A"
            }
        ' "$perf_file"
        
        echo -e "\nBranch Statistics:"
        awk -F',' '
            /branch-misses/ {
                bmiss=$1
                gsub("[^0-9.]", "", bmiss)
                print "Branch misses:", bmiss
            }
            /branch-instructions/ {
                btotal=$1
                gsub("[^0-9.]", "", btotal)
                print "Branch total:", btotal
            }
            END {
                if (btotal > 0 && bmiss <= btotal) 
                    printf "Branch Miss Rate: %.2f%%\n", (bmiss/btotal)*100
                else print "Branch Miss Rate: N/A"
            }
        ' "$perf_file"
        
    } > "$analysis_file"
    
    echo "----------------------------------------" >> "$REPORT_FILE"
    cat "$analysis_file" >> "$REPORT_FILE"
}

function setup_perf() {
    mkdir -p $PERF_DATA_DIR
    echo 0 | sudo tee /proc/sys/kernel/kptr_restrict
    echo 0 | sudo tee /proc/sys/kernel/perf_event_paranoid
}

function start_perf_record() {
    local benchmark=$1
    PERF_PIDS=()
    CONTAINER_PIDS=()
    CONTAINER_CPUS=()
}

function stop_perf_record() {
    # Stop all perf processes
    for pid in "${PERF_PIDS[@]}"; do
        sudo kill -SIGINT $pid 2>/dev/null
        wait $pid 2>/dev/null
    done
    PERF_PIDS=()
}

function print_usage() {
    echo "Usage: $0 <benchmark> [group_number]"
    echo "Available benchmarks:"
    echo "  data-serving              - Run Data Serving benchmark"
    echo "  data-serving-relational   - Run Data Serving Relational benchmark"
    echo "  data-caching             - Run Data Caching benchmark"
    echo "  graph-analytics          - Run Graph Analytics benchmark"
    echo "  in-memory-analytics      - Run In-Memory Analytics benchmark"
    echo "  media-streaming          - Run Media Streaming benchmark"
    echo "  web-search              - Run Web Search benchmark"
    echo "  web-serving             - Run Web Serving benchmark"
    echo "Event groups (optional, default=1):"
    echo "  1 - Basic CPU metrics (cycles, instructions, branches)"
    echo "  2 - L1 cache metrics"
    echo "  3 - LLC metrics"
    echo "  4 - TLB metrics"
    echo "  5 - Memory metrics"
}

function run_data_serving() {
    echo "Running Data Serving benchmark with performance monitoring..." | tee -a $LOG_FILE
    {
        # Start server
        docker run -d --name cassandra-server --net host cloudsuite/data-serving:server
        if ! wait_for_container "cassandra-server"; then
            echo "Error: Cassandra server failed to start" >&2
            return 1
        fi
        sleep 30  # Wait for server to initialize

        # Start monitoring server
        if ! monitor_container "cassandra-server"; then
            echo "Error: Failed to monitor Cassandra server" >&2
            return 1
        fi

        # Run client directly without background
        docker run --name cassandra-client --net host cloudsuite/data-serving:client bash -c \
            "./warmup.sh localhost 10000000 4 && ./load.sh localhost 10000000 5000 4"

        # Monitor the results
        docker logs cassandra-client 2>&1 | grep -E "Runtime|Throughput|Latency" >> $REPORT_FILE
    } 2>&1 | tee -a $LOG_FILE

    stop_perf_record
    analyze_perf_data "data_serving"
}

function run_data_serving_relational() {
    echo "Running Data Serving Relational benchmark with performance monitoring..."
    start_perf_record "data_serving_relational"
    
    # Start server
    docker run -d --name postgresql-server --net host cloudsuite/data-serving-relational:server
    sleep 30  # Wait for server to initialize
    
    # Run client with TPCC benchmark
    docker run --name sysbench-client --net host cloudsuite/data-serving-relational:client \
        --warmup --tpcc --server-ip=127.0.0.1
    docker run --name sysbench-client-run --net host cloudsuite/data-serving-relational:client \
        --run --tpcc --server-ip=127.0.0.1
    
    stop_perf_record
}

function run_data_caching() {
    echo "Running Data Caching benchmark with performance monitoring..."
    start_perf_record "data_caching"
    
    # Start server
    docker run -d --name dc-server --net host cloudsuite/data-caching:server -t 4 -m 10240 -n 550
    
    # Create server config
    mkdir -p docker_servers
    echo "127.0.0.1, 11211" > docker_servers/docker_servers.txt
    
    # Start client and run benchmark
    docker run -d --name dc-client --net host \
        -v $PWD/docker_servers:/usr/src/memcached/memcached_client/docker_servers/ \
        cloudsuite/data-caching:client
    
    # Scale, warmup and run
    docker exec -it dc-client /bin/bash /entrypoint.sh --m="S&W" --S=28 --D=10240 --w=8 --T=1
    docker exec -it dc-client /bin/bash /entrypoint.sh --m="RPS" --S=28 --g=0.8 --c=200 --w=8 --T=1 --r=100000
    
    stop_perf_record
}

function run_graph_analytics() {
    echo "Running Graph Analytics benchmark with performance monitoring..."
    start_perf_record "graph_analytics"
    
    # Create dataset
    docker create --name twitter-data cloudsuite/twitter-dataset-graph
    
    # Run benchmark
    docker run --rm --volumes-from twitter-data -e WORKLOAD_NAME=pr \
        cloudsuite/graph-analytics --driver-memory 8g --executor-memory 8g
    
    stop_perf_record
}

function run_in_memory_analytics() {
    echo "Running In-Memory Analytics benchmark with performance monitoring..."
    start_perf_record "in_memory_analytics"
    
    # Create dataset
    docker create --name movielens-data cloudsuite/movielens-dataset
    
    # Run benchmark
    docker run --rm --volumes-from movielens-data \
        cloudsuite/in-memory-analytics /data/ml-latest-small /data/myratings.csv \
        --driver-memory 4g --executor-memory 4g
    
    stop_perf_record
}

function run_media_streaming() {
    echo "Running Media Streaming benchmark with performance monitoring..."
    start_perf_record "media_streaming"
    
    # Start dataset and server
    docker run --name streaming_dataset cloudsuite/media-streaming:dataset 5 10
    docker run -d --name streaming_server --volumes-from streaming_dataset \
        --net host cloudsuite/media-streaming:server 4
    
    sleep 30  # Wait for server to initialize
    
    # Run client
    docker run --name streaming_client --net host \
        cloudsuite/media-streaming:client localhost 10
    
    stop_perf_record
}

function run_web_search() {
    echo "Running Web Search benchmark with performance monitoring..."
    start_perf_record "web_search"
    
    # Setup dataset and server
    docker run --name web_search_dataset cloudsuite/web-search:dataset
    docker run -d --name server --volumes-from web_search_dataset \
        --net host cloudsuite/web-search:server 14g 1
    
    sleep 30  # Wait for server to initialize
    
    # Run client
    docker run --rm --name web_search_client --net host \
        cloudsuite/web-search:client localhost 8
    
    stop_perf_record
}

function run_web_serving() {
    echo "Running Web Serving benchmark with performance monitoring..."
    start_perf_record "web_serving"
    
    # Start database server
    docker run -d --name database_server --net host \
        cloudsuite/web-serving:db_server
    
    # Start memcached server
    docker run -d --name memcache_server --net host \
        cloudsuite/web-serving:memcached_server
    
    # Start web server
    docker run -d --name web_server --net host \
        cloudsuite/web-serving:web_server /etc/bootstrap.sh \
        http localhost localhost localhost 4 auto
    
    sleep 30  # Wait for services to initialize
    
    # Run client
    docker run --name faban_client --net host \
        cloudsuite/web-serving:faban_client localhost 1
    
    stop_perf_record
}

function cleanup() {
    echo "Cleaning up containers and performance data..."
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker volume prune -f
    rm -rf docker_servers
}

function run_all_groups() {
    local benchmark=$1
    
    # Run each event group sequentially
    for group in {1..5}; do
        echo "Running $benchmark with event group $group..." | tee -a $LOG_FILE
        SELECTED_GROUP=$group
        
        # Clean up before each run
        cleanup
        
        # Run the benchmark with current group
        case $benchmark in
            "data-serving")
                { run_data_serving; } 2>&1 | tee -a $LOG_FILE
                ;;
            "data-serving-relational")
                run_data_serving_relational
                ;;
            "data-caching")
                run_data_caching
                ;;
            "graph-analytics")
                run_graph_analytics
                ;;
            "in-memory-analytics")
                run_in_memory_analytics
                ;;
            "media-streaming")
                run_media_streaming
                ;;
            "web-search")
                run_web_search
                ;;
            "web-serving")
                run_web_serving
                ;;
        esac
        
        echo "Completed group $group for $benchmark"
        sleep 10  # Brief pause between groups
    done
}

# Main script execution
setup_dirs
setup_perf

if [ $# -lt 1 ]; then
    print_usage
    exit 1
fi

# Set event group if specified
if [ $# -ge 2 ]; then
    SELECTED_GROUP=$2
    if [ $SELECTED_GROUP -lt 1 ] || [ $SELECTED_GROUP -gt 5 ]; then
        echo "Invalid group number. Using default group 1."
        SELECTED_GROUP=1
    fi
fi

# Clean up before running
cleanup

case $1 in
    "all")
        for benchmark in "data-serving" "data-serving-relational" "data-caching" \
            "graph-analytics" "in-memory-analytics" "media-streaming" \
            "web-search" "web-serving"; do
            echo "=== Starting benchmark: $benchmark ===" | tee -a $LOG_FILE
            run_all_groups $benchmark
            echo "=== Completed benchmark: $benchmark ===" | tee -a $LOG_FILE
        done
        ;;
    *)
        if [ $# -ge 2 ]; then
            SELECTED_GROUP=$2
            if [ $SELECTED_GROUP -lt 1 ] || [ $SELECTED_GROUP -gt 5 ]; then
                echo "Invalid group number. Using default group 1."
                SELECTED_GROUP=1
            fi
            # Run single benchmark with specified group
            case $1 in
                "data-serving")
                    run_data_serving
                    ;;
                "data-serving-relational")
                    run_data_serving_relational
                    ;;
                "data-caching")
                    run_data_caching
                    ;;
                "graph-analytics")
                    run_graph_analytics
                    ;;
                "in-memory-analytics")
                    run_in_memory_analytics
                    ;;
                "media-streaming")
                    run_media_streaming
                    ;;
                "web-search")
                    run_web_search
                    ;;
                "web-serving")
                    run_web_serving
                    ;;
                *)
                    echo "Unknown benchmark: $1"
                    print_usage
                    exit 1
                    ;;
            esac
        else
            # Run all groups for single benchmark
            run_all_groups $1
        fi
        ;;
esac

echo "Benchmark completed! Results available in:"
echo "- Logs: $LOG_FILE"
echo "- Performance Data: $PERF_DATA_DIR"
echo "- Analysis: $ANALYSIS_DIR"
echo "- Summary Report: $REPORT_FILE"