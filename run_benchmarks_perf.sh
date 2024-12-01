#!/bin/bash

# Add output directories
OUTPUT_DIR="benchmark_results"
PERF_DATA_DIR="$OUTPUT_DIR/perf_data"
LOG_DIR="$OUTPUT_DIR/logs"
REPORT_DIR="$OUTPUT_DIR/reports"
ANALYSIS_DIR="$OUTPUT_DIR/analysis"

# Define perf event groups
EVENT_GROUP_1="cycles,instructions,branch-instructions,branch-misses"
EVENT_GROUP_2="L1-dcache-loads,L1-dcache-load-misses"
EVENT_GROUP_3="LLC-loads,LLC-load-misses"
EVENT_GROUP_4="iTLB-loads,iTLB-load-misses"
EVENT_GROUP_5="dTLB-loads,dTLB-load-misses"
EVENT_GROUP_6="mem-loads,mem-stores,node-loads,node-load-misses"

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
        6) events=$EVENT_GROUP_6 ;;
        *) events=$EVENT_GROUP_1 ;;
    esac
    
    # Start perf monitoring for this container
    local perf_output="$PERF_DATA_DIR/${container_name}_group${SELECTED_GROUP}.txt"
    if sudo perf stat -e $events -p $pid -I $MONITOR_INTERVAL -o $perf_output 2>/dev/null & then
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
    local perf_file="$PERF_DATA_DIR/${benchmark}_group${SELECTED_GROUP}.txt"
    local analysis_file="$ANALYSIS_DIR/${benchmark}_analysis_group${SELECTED_GROUP}.txt"

    # Debug: Print raw perf data
    echo "Raw perf data for $benchmark:" >> "$LOG_FILE"
    cat "$perf_file" >> "$LOG_FILE"

    {
        echo "=== Performance Analysis for $benchmark (Event Group $SELECTED_GROUP) ==="
        echo "Time: $(date)"

        echo -e "\nInstructions per Cycle (IPC):"
        awk '
            /^ *[0-9]+/ {
                value = $1
                event = $2
                gsub(",", "", value)
                if (event == "instructions") inst = value
                else if (event == "cycles") cycles = value
            }
            END {
                if (inst && cycles) {
                    print "Instructions:", inst
                    print "Cycles:", cycles
                    printf "IPC: %.2f\n", inst / cycles
                } else {
                    print "IPC data not available."
                }
            }
        ' "$perf_file"

        echo -e "\nCache Statistics:"
        awk '
            /^ *[0-9]+/ {
                value = $1
                event = $2
                gsub(",", "", value)
                if (event == "L1-dcache-loads") l1_total = value
                else if (event == "L1-dcache-load-misses") l1_miss = value
            }
            END {
                if (l1_total && l1_miss) {
                    print "L1 total loads:", l1_total
                    print "L1 load misses:", l1_miss
                    printf "L1 Miss Rate: %.2f%%\n", (l1_miss / l1_total) * 100
                } else {
                    print "L1 cache data not available."
                }
            }
        ' "$perf_file"

        echo -e "\nBranch Statistics:"
        awk '
            /^ *[0-9]+/ {
                value = $1
                event = $2
                gsub(",", "", value)
                if (event == "branch-instructions") branch_total = value
                else if (event == "branch-misses") branch_miss = value
            }
            END {
                if (branch_total && branch_miss) {
                    print "Total branch instructions:", branch_total
                    print "Branch misses:", branch_miss
                    printf "Branch Miss Rate: %.2f%%\n", (branch_miss / branch_total) * 100
                } else {
                    print "Branch data not available."
                }
            }
        ' "$perf_file"

        # Add more sections as needed

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
    echo "  data-analytics            - Run Data Analytics benchmark"
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
    echo "  4 - iTLB metrics"
    echo "  5 - dTLB metrics"
    echo "  6 - Memory metrics"
    echo "  all - Run all event groups sequentially"
}

function run_data_serving() {
    echo "Running Data Serving benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "data_serving"

    # Start server
    docker run -d --name cassandra-server --net host cloudsuite/data-serving:server
    sleep 30  # Wait for server to initialize

    # Monitor server performance
    monitor_container "cassandra-server"

    # Run warmup to populate the database
    docker run --name cassandra-client-warmup --net host cloudsuite/data-serving:client \
        bash -c "./warmup.sh localhost 10000000 4"

    # Collect warmup results
    echo "Data Serving Warmup Results:" >> $REPORT_FILE
    docker logs cassandra-client-warmup 2>&1 | grep -E "Throughput|AverageLatency" >> $REPORT_FILE

    # Remove warmup client container
    docker rm cassandra-client-warmup

    # Run load to apply workload
    docker run --name cassandra-client-load --net host cloudsuite/data-serving:client \
        bash -c "./load.sh localhost 10000000 5000 4"

    # Collect load results
    echo "Data Serving Load Results:" >> $REPORT_FILE
    docker logs cassandra-client-load 2>&1 | grep -E "Throughput|AverageLatency" >> $REPORT_FILE

    # Remove load client container
    docker rm cassandra-client-load

    stop_perf_record

    # Stop and remove server
    docker stop cassandra-server
    docker rm cassandra-server
}

function run_data_serving_relational() {
    echo "Running Data Serving Relational benchmark with performance monitoring..."
    start_perf_record "data_serving_relational"

    # Start server
    docker run -d --name postgresql-server --net host cloudsuite/data-serving-relational:server
    if ! wait_for_container "postgresql-server"; then
        echo "Error: PostgreSQL server failed to start" >&2
        return 1
    fi

    # Monitor server
    if ! monitor_container "postgresql-server"; then
        echo "Error: Failed to monitor PostgreSQL server" >&2
        return 1
    fi

    sleep 30  # Wait for server to initialize

    # Run client with TPCC benchmark
    docker run --name sysbench-client --net host cloudsuite/data-serving-relational:client \
        --warmup --tpcc --server-ip=127.0.0.1
    docker run --name sysbench-client-run --net host cloudsuite/data-serving-relational:client \
        --run --tpcc --server-ip=127.0.0.1

    stop_perf_record
    # analyze_perf_data "data_serving_relational"

    # Clean up containers
    docker rm -f postgresql-server sysbench-client sysbench-client-run 2>/dev/null || true
}

function run_data_caching() {
    echo "Running Data Caching benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "data_caching"

    # Start server
    docker run -d --name dc-server --net host cloudsuite/data-caching:server -t 4 -m 10240 -n 550
    if ! wait_for_container "dc-server"; then
        echo "Error: Data Caching server failed to start" >&2
        return 1
    fi

    # Monitor server
    if ! monitor_container "dc-server"; then
        echo "Error: Failed to monitor Data Caching server" >&2
        return 1
    fi

    # Create server config
    mkdir -p docker_servers
    echo "127.0.0.1, 11211" > docker_servers/docker_servers.txt

    # Start client and run benchmark
    docker run -d --name dc-client --net host \
        -v $PWD/docker_servers:/usr/src/memcached/memcached_client/docker_servers/ \
        cloudsuite/data-caching:client
    if ! wait_for_container "dc-client"; then
        echo "Error: Data Caching client failed to start" >&2
        return 1
    fi

    # Monitor client
    if ! monitor_container "dc-client"; then
        echo "Error: Failed to monitor Data Caching client" >&2
        return 1
    fi

    # Scale, warmup and run
    docker exec -it dc-client /bin/bash /entrypoint.sh --m="S&W" --S=28 --D=10240 --w=8 --T=1
    docker exec -it dc-client /bin/bash /entrypoint.sh --m="RPS" --S=28 --g=0.8 --c=200 --w=8 --T=1 --r=100000

    stop_perf_record
    # analyze_perf_data "data_caching"

    # Clean up containers
    docker rm -f dc-server dc-client 2>/dev/null || true
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
    # analyze_perf_data "graph_analytics"

    # Clean up containers
    docker rm -f twitter-data 2>/dev/null || true
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
    # analyze_perf_data "in_memory_analytics"

    # Clean up containers
    docker rm -f movielens-data 2>/dev/null || true
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
    # analyze_perf_data "media_streaming"

    # Clean up containers
    docker rm -f streaming_dataset streaming_server streaming_client 2>/dev/null || true
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
    # analyze_perf_data "web_search"

    # Clean up containers
    docker rm -f web_search_dataset server web_search_client 2>/dev/null || true
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
    # analyze_perf_data "web_serving"

    # Clean up containers
    docker rm -f database_server memcache_server web_server faban_client 2>/dev/null || true
}

function run_data_analytics() {
    echo "Running Data Analytics benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "data_analytics"
    
    # Create dataset
    docker create --name wikimedia-dataset cloudsuite/wikimedia-pages-dataset
    
    # Start master with minimal configuration
    docker run -d --net host --volumes-from wikimedia-dataset --name data-master \
        cloudsuite/data-analytics --master \
        --hdfs-block-size=64 \
        --yarn-cores=2 \
        --mapreduce-mem=2048
        
    if ! wait_for_container "data-master"; then
        echo "Error: Data Analytics master failed to start" >&2
        return 1
    fi
    
    # Monitor master
    if ! monitor_container "data-master"; then
        echo "Error: Failed to monitor Data Analytics master" >&2
        return 1
    fi
    
    # Start one worker
    docker run -d --net host --name data-slave01 \
        cloudsuite/data-analytics --slave --master-ip=127.0.0.1
        
    if ! monitor_container "data-slave01"; then
        echo "Error: Failed to monitor Data Analytics worker" >&2
        return 1
    fi
    
    sleep 30  # Wait for initialization
    
    # Run benchmark
    docker exec data-master benchmark
    
    stop_perf_record
    # analyze_perf_data "data_analytics"

    # Clean up containers
    docker rm -f wikimedia-dataset data-master data-slave01 2>/dev/null || true
}

function cleanup() {
    echo "Cleaning up containers and performance data..."
    docker rm -f $(docker ps -aq --filter "name=cassandra-server") 2>/dev/null
    docker rm -f $(docker ps -aq --filter "name=cassandra-client-") 2>/dev/null
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
            "data-analytics")
                run_data_analytics
                ;;
        esac
        
        echo "Completed group $group for $benchmark"
        sleep 10  # Brief pause between groups
    done
}

# Add a function to run all event groups for a container
function monitor_container_all_groups() {
    local container_name=$1
    
    for group in {1..6}; do
        echo "Starting event group $group monitoring for $container_name..." | tee -a $LOG_FILE
        SELECTED_GROUP=$group
        if ! monitor_container "$container_name"; then
            echo "Error: Failed to monitor $container_name for group $group" >&2
            return 1
        fi
        sleep 5  # Brief pause between groups
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
    if ( [ "$2" = "all" ] || [ "$2" = "ALL" ] ); then
        echo "Running all event groups sequentially"
        for group in {1..6}; do
            SELECTED_GROUP=$group
            echo "=== Running event group $group ===" | tee -a $LOG_FILE
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
                "data-analytics")
                    run_data_analytics
                    ;;
                *)
                    echo "Unknown benchmark: $1"
                    print_usage
                    exit 1
                    ;;
            esac
            sleep 10  # Pause between groups
        done
    else
        SELECTED_GROUP=$2
        if [ $SELECTED_GROUP -lt 1 ] || [ $SELECTED_GROUP -gt 6 ]; then
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
            "data-analytics")
                run_data_analytics
                ;;
            *)
                echo "Unknown benchmark: $1"
                print_usage
                exit 1
                ;;
        esac
    fi
else
    # Run with default group
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
        "data-analytics")
            run_data_analytics
            ;;
        *)
            echo "Unknown benchmark: $1"
            print_usage
            exit 1
            ;;
    esac
fi

echo "Benchmark completed! Results available in:"
echo "- Logs: $LOG_FILE"
echo "- Performance Data: $PERF_DATA_DIR"
echo "- Analysis: $ANALYSIS_DIR"
echo "- Summary Report: $REPORT_FILE"