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

function get_container_cgroup() {
    local container_name=$1
    local pid=$(docker inspect --format '{{.State.Pid}}' $container_name)
    if [ -z "$pid" ] || [ "$pid" -eq 0 ]; then
        echo "Error: Could not get PID for container $container_name" >&2
        return 1
    fi
    local cgroup=$(cat /proc/$pid/cgroup | grep '^0::' | cut -d':' -f3)
    if [ -z "$cgroup" ]; then
        echo "Error: Could not determine cgroup for container $container_name" >&2
        return 1
    fi
    echo "$cgroup"
}

function get_container_cpu_affinity() {
    local pid=$1
    if [ -e "/proc/$pid" ]; then
        taskset -p $pid 2>/dev/null | awk '{print $NF}' || echo "0"
    else
        echo "0"
    fi
}

# Modify start_container_logging function to ensure proper output formatting
function start_container_logging() {
    local container_name=$1
    local log_file="$CONTAINER_LOGS_DIR/${container_name}.log"
    # Start following logs in background and save the PID
    docker logs -f $container_name > "$log_file" 2>&1 &
    echo $! > "$CONTAINER_LOGS_DIR/${container_name}.pid"
    echo -e "\nStarted real-time logging for $container_name to $log_file" | tee -a $LOG_FILE
}

# Add new function to stop log collection
function stop_container_logging() {
    local container_name=$1
    local pid_file="$CONTAINER_LOGS_DIR/${container_name}.pid"
    if [ -f "$pid_file" ]; then
        kill $(cat "$pid_file") 2>/dev/null
        rm "$pid_file"
    fi
}

# Update monitor_container function to improve output formatting
function monitor_container() {
    local container_name=$1
    local container_id=$(docker inspect --format '{{.Id}}' $container_name)

    echo -e "\nStarting monitoring for container: $container_name" | tee -a $LOG_FILE

    # Start real-time logging
    start_container_logging "$container_name"

    # Wait for container to be running
    if ! wait_for_container "$container_name"; then
        echo -e "\nError: Container $container_name failed to start" >&2
        return 1
    fi

    # Get cgroup path
    local cgroup_path=$(get_container_cgroup "$container_id")
    if [ $? -ne 0 ]; then
        echo -e "\nError: Could not get cgroup path for container $container_name" >&2
        return 1
    fi

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

    # Start perf monitoring for this container using cgroup
    local perf_output="$PERF_DATA_DIR/${container_name}_group${SELECTED_GROUP}.txt"
    if sudo perf stat -e $events -a --cgroup $cgroup_path -I $MONITOR_INTERVAL -o $perf_output 2>/dev/null & then
        PERF_PIDS+=($!)
        echo -e "\nStarted monitoring container $container_name (Cgroup: $cgroup_path)" | tee -a $LOG_FILE
    else
        echo -e "\nError: Failed to start perf monitoring for container $container_name" >&2
        return 1
    fi
}

# In setup_dirs function, add creation of CONTAINER_LOGS_DIR
function setup_dirs() {
    mkdir -p $PERF_DATA_DIR
    mkdir -p $LOG_DIR
    mkdir -p $REPORT_DIR
    mkdir -p $ANALYSIS_DIR
    CONTAINER_LOGS_DIR="$OUTPUT_DIR/container_logs"
    mkdir -p $CONTAINER_LOGS_DIR
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

# Define a function to collect logs from a container
function collect_container_logs() {
    local container_name=$1
    local log_file="$CONTAINER_LOGS_DIR/${container_name}.log"
    docker logs $container_name > $log_file 2>&1
    echo "Collected logs for $container_name into $log_file" | tee -a $LOG_FILE
}

# Update run_data_serving (and similar functions) to improve output formatting
function run_data_serving() {
    echo -e "\nRunning Data Serving benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "data_serving"

    echo -e "\nStarting Cassandra server..." | tee -a $LOG_FILE
    # Start server
    docker run -d --name cassandra-server --net host cloudsuite/data-serving:server
    sleep 30  # Wait for server to initialize

    # Monitor and start logging server
    monitor_container "cassandra-server"

    # Run warmup to populate the database in detached mode
    docker run -d --name cassandra-client-warmup --net host cloudsuite/data-serving:client \
        bash -c "./warmup.sh localhost 5000000 4"

    # Monitor and start logging warmup client
    monitor_container "cassandra-client-warmup"

    # Wait for warmup to complete
    docker wait cassandra-client-warmup

    # Stop logging and remove warmup client
    stop_container_logging "cassandra-client-warmup"
    docker rm cassandra-client-warmup

    # Run load to apply workload in detached mode
    docker run -d --name cassandra-client-load --net host cloudsuite/data-serving:client \
        bash -c "./load.sh localhost 5000000 5000 4"

    # Monitor and start logging load client
    monitor_container "cassandra-client-load"

    # Wait for load to complete
    docker wait cassandra-client-load

    # Stop logging and remove load client
    stop_container_logging "cassandra-client-load"
    docker rm cassandra-client-load

    # Stop logging and cleanup server
    stop_container_logging "cassandra-server"
    docker stop cassandra-server
    docker rm cassandra-server

    stop_perf_record

    # Collect warmup results
    echo "Data Serving Warmup Results:" >> $REPORT_FILE
    docker logs cassandra-client-warmup 2>&1 | grep -E "Throughput|AverageLatency" >> $REPORT_FILE

    # Collect load results
    echo "Data Serving Load Results:" >> $REPORT_FILE
    docker logs cassandra-client-load 2>&1 | grep -E "Throughput|AverageLatency" >> $REPORT_FILE
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

    # Run warmup client in detached mode
    docker run -d --name sysbench-client --net host cloudsuite/data-serving-relational:client \
        --warmup --tpcc --server-ip=127.0.0.1

    # Monitor warmup client container
    monitor_container "sysbench-client"

    # Wait for warmup to complete
    docker wait sysbench-client

    # Collect logs from warmup client before removing it
    collect_container_logs "sysbench-client"
    docker rm sysbench-client

    # Run load client in detached mode
    docker run -d --name sysbench-client-run --net host cloudsuite/data-serving-relational:client \
        --run --tpcc --server-ip=127.0.0.1

    # Monitor load client container
    monitor_container "sysbench-client-run"

    # Wait for load to complete
    docker wait sysbench-client-run

    # Collect logs from load client before removing it
    collect_container_logs "sysbench-client-run"
    docker rm sysbench-client-run

    stop_perf_record

    # Collect logs from server before removing it
    collect_container_logs "postgresql-server"
    docker rm -f postgresql-server 2>/dev/null || true
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

    # Start client in detached mode
    docker run -d --name dc-client --net host \
        -v $PWD/docker_servers:/usr/src/memcached/memcached_client/docker_servers/ \
        cloudsuite/data-caching:client
    if ! wait_for_container "dc-client"; then
        echo "Error: Data Caching client failed to start" >&2
        return 1
    fi

    # Monitor client container
    monitor_container "dc-client"

    # Scale, warmup and run
    docker exec -it dc-client /bin/bash /entrypoint.sh --m="S&W" --S=28 --D=10240 --w=8 --T=1
    docker exec -it dc-client /bin/bash /entrypoint.sh --m="RPS" --S=28 --g=0.8 --c=200 --w=8 --T=1 --r=100000

    stop_perf_record
    # analyze_perf_data "data_caching"

    # Collect logs from client before removing it
    collect_container_logs "dc-client"
    docker rm -f dc-client

    # Collect logs from server before removing it
    collect_container_logs "dc-server"
    docker rm -f dc-server
}


function run_graph_analytics() {
    echo "Running Graph Analytics benchmark with performance monitoring..."
    start_perf_record "graph_analytics"
    
    # Create dataset
    docker create --name twitter-data cloudsuite/twitter-dataset-graph

    # Monitor dataset container
    monitor_container "twitter-data"
    
    # Run benchmark in detached mode
    docker run -d --name graph-analytics --volumes-from twitter-data -e WORKLOAD_NAME=pr \
        cloudsuite/graph-analytics --driver-memory 8g --executor-memory 8g

    # Monitor benchmark container
    monitor_container "graph-analytics"

    # Wait for benchmark to complete
    docker wait graph-analytics

    # Collect logs from benchmark container
    collect_container_logs "graph-analytics"
    docker rm graph-analytics

    stop_perf_record
    # analyze_perf_data "graph_analytics"

    # Collect logs from dataset container if needed
    collect_container_logs "twitter-data"
    docker rm -f twitter-data 2>/dev/null || true
}

function run_in_memory_analytics() {
    echo "Running In-Memory Analytics benchmark with performance monitoring..."
    start_perf_record "in_memory_analytics"
    
    # Create dataset
    docker create --name movielens-data cloudsuite/movielens-dataset

    # Monitor dataset container
    monitor_container "movielens-data"
    
    # Run benchmark in detached mode
    docker run -d --name in-memory-analytics --volumes-from movielens-data \
        cloudsuite/in-memory-analytics /data/ml-latest-small /data/myratings.csv \
        --driver-memory 4g --executor-memory 4g

    # Monitor benchmark container
    monitor_container "in-memory-analytics"

    # Wait for benchmark to complete
    docker wait in-memory-analytics

    # Collect logs from benchmark container
    collect_container_logs "in-memory-analytics"
    docker rm in-memory-analytics

    stop_perf_record
    # analyze_perf_data "in_memory_analytics"

    # Collect logs from dataset container if needed
    collect_container_logs "movielens-data"
    docker rm -f movielens-data 2>/dev/null || true
}

function run_media_streaming() {
    echo "Running Media Streaming benchmark with performance monitoring..."
    start_perf_record "media_streaming"
    
    # Start dataset and server
    docker run --name streaming_dataset cloudsuite/media-streaming:dataset 5 10

    # Monitor dataset container
    monitor_container "streaming_dataset"
    
    docker run -d --name streaming_server --volumes-from streaming_dataset \
        --net host cloudsuite/media-streaming:server 4

    # Monitor server container
    monitor_container "streaming_server"
    
    sleep 30  # Wait for server to initialize
    
    # Start client in detached mode
    docker run -d --name streaming_client --net host \
        cloudsuite/media-streaming:client localhost 10

    # Monitor client container
    monitor_container "streaming_client"

    # Wait for client to finish
    docker wait streaming_client

    stop_perf_record
    # analyze_perf_data "media_streaming"

    # Collect logs from client
    collect_container_logs "streaming_client"
    docker rm streaming_client

    # Collect logs from server
    collect_container_logs "streaming_server"
    docker stop streaming_server
    docker rm streaming_server

    # Collect logs from dataset container if needed
    collect_container_logs "streaming_dataset"
    docker rm -f streaming_dataset 2>/dev/null || true
}

function run_web_search() {
    echo "Running Web Search benchmark with performance monitoring..."
    start_perf_record "web_search"
    
    # Setup dataset and server
    docker run --name web_search_dataset cloudsuite/web-search:dataset

    # Monitor dataset container
    monitor_container "web_search_dataset"
    
    docker run -d --name server --volumes-from web_search_dataset \
        --net host cloudsuite/web-search:server 14g 1

    # Monitor server container
    monitor_container "server"
    
    sleep 30  # Wait for server to initialize
    
    # Run client in detached mode
    docker run -d --name web_search_client --net host \
        cloudsuite/web-search:client localhost 8

    # Monitor client container
    monitor_container "web_search_client"

    # Wait for client to finish
    docker wait web_search_client

    stop_perf_record
    # analyze_perf_data "web_search"

    # Collect logs from client
    collect_container_logs "web_search_client"
    docker rm web_search_client

    # Collect logs from server
    collect_container_logs "server"
    docker stop server
    docker rm server

    # Collect logs from dataset container if needed
    collect_container_logs "web_search_dataset"
    docker rm -f web_search_dataset 2>/dev/null || true
}

function run_web_serving() {
    echo "Running Web Serving benchmark with performance monitoring..."
    start_perf_record "web_serving"
    
    # Start database server
    docker run -d --name database_server --net host \
        cloudsuite/web-serving:db_server

    # Monitor database server
    monitor_container "database_server"
    
    # Start memcached server
    docker run -d --name memcache_server --net host \
        cloudsuite/web-serving:memcached_server

    # Monitor memcached server
    monitor_container "memcache_server"
    
    # Start web server
    docker run -d --name web_server --net host \
        cloudsuite/web-serving:web_server /etc/bootstrap.sh \
        http localhost localhost localhost 4 auto

    # Monitor web server
    monitor_container "web_server"
    
    sleep 30  # Wait for services to initialize
    
    # Run client in detached mode
    docker run -d --name faban_client --net host \
        cloudsuite/web-serving:faban_client localhost 1

    # Monitor client container
    monitor_container "faban_client"

    # Wait for client to finish
    docker wait faban_client

    stop_perf_record
    # analyze_perf_data "web_serving"

    # Collect logs from client
    collect_container_logs "faban_client"
    docker rm faban_client

    # Collect logs from web server
    collect_container_logs "web_server"
    docker stop web_server
    docker rm web_server

    # Collect logs from memcache server
    collect_container_logs "memcache_server"
    docker stop memcache_server
    docker rm memcache_server

    # Collect logs from database server
    collect_container_logs "database_server"
    docker stop database_server
    docker rm database_server
}

function run_data_analytics() {
    echo "Running Data Analytics benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "data_analytics"
    
    # Step 1: Create the dataset container
    docker create --name wikimedia-dataset cloudsuite/wikimedia-pages-dataset
    # Step 1.5: Create a User-Defined Network
    docker network create hadoop-net

    # Step 2: Start the Hadoop master node with desired configurations
    docker run -d --net hadoop-net --volumes-from wikimedia-dataset --name data-master \
        cloudsuite/data-analytics --master \
        --hdfs-block-size=64 \
        --yarn-cores=4 \
        --mapreduce-mem=4096

    if ! wait_for_container "data-master"; then
        echo "Error: Data Analytics master failed to start" >&2
        return 1
    fi

    # Monitor the master container
    monitor_container "data-master"
    
    # Step 3: Start the Hadoop slave nodes
    NUM_SLAVES=4  # Adjust based on your resources
    for i in $(seq 1 $NUM_SLAVES); do
        docker run -d --net hadoop-net --name data-slave0$i \
            cloudsuite/data-analytics --slave --master-ip=data-master
        if ! wait_for_container "data-slave0$i"; then
            echo "Error: Data Analytics slave data-slave0$i failed to start" >&2
            return 1
        fi
        # Monitor each slave container
        monitor_container "data-slave0$i"
    done

    # Step 4: Wait briefly to ensure the cluster is fully initialized
    sleep 30  # Adjust the sleep time as needed

    # Step 5: Run the benchmark inside the master container
    echo "Starting benchmark inside the master container..." | tee -a $LOG_FILE
    docker exec data-master benchmark

    # Step 6: Collect logs and performance data
    stop_perf_record
    collect_container_logs "data-master"

    for i in $(seq 1 $NUM_SLAVES); do
        collect_container_logs "data-slave0$i"
    done

    collect_container_logs "wikimedia-dataset"

    # Step 7: Clean up the containers
    docker rm -f data-master
    for i in $(seq 1 $NUM_SLAVES); do
        docker rm -f data-slave0$i
    done
    docker rm -f wikimedia-dataset
    docker network rm hadoop-net

    echo "Data Analytics benchmark completed." | tee -a $LOG_FILE
}


# Update cleanup function to ensure clean output
function cleanup() {
    echo -e "\nCleaning up containers and performance data..." | tee -a $LOG_FILE
    docker rm -f $(docker ps -aq --filter "name=cassandra-server") 2>/dev/null
    docker rm -f $(docker ps -aq --filter "name=cassandra-client-") 2>/dev/null
    docker volume prune -f
    rm -rf docker_servers
    
    # Kill any remaining log collection processes
    for pid_file in "$CONTAINER_LOGS_DIR"/*.pid; do
        if [ -f "$pid_file" ]; then
            kill $(cat "$pid_file") 2>/dev/null
            rm "$pid_file"
        fi
    done
}

function run_all_groups() {
    local benchmark=$1
    
    # Run each event group sequentially
    for group in {1..5}; do
        echo -e "\nRunning $benchmark with event group $group..." | tee -a $LOG_FILE
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
        
        echo -e "\nCompleted group $group for $benchmark" | tee -a $LOG_FILE
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
        echo -e "\nRunning all event groups sequentially" | tee -a $LOG_FILE
        for group in {1..6}; do
            SELECTED_GROUP=$group
            echo -e "\n=== Running event group $group ===" | tee -a $LOG_FILE
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

# Update final output message
echo -e "\nBenchmark completed! Results available in:"
echo "- Logs: $LOG_FILE"
echo "- Performance Data: $PERF_DATA_DIR"
echo "- Analysis: $ANALYSIS_DIR"
echo "- Summary Report: $REPORT_FILE"