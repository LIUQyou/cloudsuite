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
    {
        echo -e "\nRunning Data Serving benchmark with performance monitoring..."

        start_perf_record "data_serving"

        echo -e "\nStarting Cassandra server..."
        # Start server and redirect output to log file
        docker run -d --name cassandra-server --net host \
            -v "$CONTAINER_LOGS_DIR:/var/log/cassandra" \
            cloudsuite/data-serving:server \
            2>&1 | tee -a $LOG_FILE
        sleep 30  # Wait for server to initialize

        # Monitor and start logging server
        monitor_container "cassandra-server"

        # Run warmup to populate the database in detached mode
        docker run -d --name cassandra-client-warmup --net host cloudsuite/data-serving:client \
            bash -c "./warmup.sh localhost 5000000 4" \
            2>&1 | tee -a $LOG_FILE

        # Monitor and start logging warmup client
        monitor_container "cassandra-client-warmup"

        # Wait for warmup to complete
        docker wait cassandra-client-warmup

        # Stop logging and remove warmup client
        stop_container_logging "cassandra-client-warmup"
        docker rm cassandra-client-warmup

        # Run load to apply workload in detached mode
        docker run -d --name cassandra-client-load --net host cloudsuite/data-serving:client \
            bash -c "./load.sh localhost 5000000 5000 4" \
            > "$LOG_DIR/cassandra-client-load.log" 2>&1

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
    } 2>&1 | tee -a $LOG_FILE
}

function run_data_serving_relational() {
    {
        echo -e "\nRunning Data Serving Relational benchmark with performance monitoring..."

        start_perf_record "data_serving_relational"

        # Start the PostgreSQL server with -dit to keep it running in background
        docker run -dit --name postgresql-server --net host \
            -v "$CONTAINER_LOGS_DIR:/var/log/postgresql" \
            cloudsuite/data-serving-relational:server

        # Wait for PostgreSQL to initialize and start accepting connections
        echo -e "\nWaiting for PostgreSQL to initialize..." | tee -a $LOG_FILE
        sleep 10

        if ! wait_for_container "postgresql-server"; then
            echo -e "\nError: PostgreSQL server failed to start" >&2
            return 1
        fi

        # Verify PostgreSQL is accepting connections
        for i in {1..30}; do
            if docker exec postgresql-server pg_isready -h localhost; then
                echo -e "\nPostgreSQL is ready to accept connections" | tee -a $LOG_FILE
                break
            fi
            echo -e "\nWaiting for PostgreSQL to accept connections... (attempt $i/30)" | tee -a $LOG_FILE
            sleep 2
        done

        # Monitor the server container
        monitor_container "postgresql-server"

        # Run warmup client in detached mode
        docker run -d --name sysbench-client-warmup --net host cloudsuite/data-serving-relational:client \
            --warmup --tpcc --server-ip=127.0.0.1 \
            2>&1 | tee -a $LOG_FILE
        monitor_container "sysbench-client-warmup"

        # Wait for warmup to complete
        docker wait sysbench-client-warmup

        # Stop logging and remove warmup client
        stop_container_logging "sysbench-client-warmup"
        docker rm sysbench-client-warmup

        # Run load client in detached mode
        docker run -d --name sysbench-client-load --net host cloudsuite/data-serving-relational:client \
            --run --tpcc --server-ip=127.0.0.1 \
            > "$LOG_DIR/sysbench-client-warmup.log" 2>&1
        monitor_container "sysbench-client-load"

        # Wait for load to complete
        docker wait sysbench-client-load

        # Stop logging and remove load client
        stop_container_logging "sysbench-client-load"
        docker rm sysbench-client-load

        # Stop logging and cleanup server
        stop_container_logging "postgresql-server"
        docker stop postgresql-server
        docker rm postgresql-server

        stop_perf_record

        # Collect and append results to the report file
        echo "Data Serving Relational Warmup Results:" >> $REPORT_FILE
        docker logs sysbench-client-warmup 2>&1 | grep -E "transactions|queries" >> $REPORT_FILE

        echo "Data Serving Relational Load Results:" >> $REPORT_FILE
        docker logs sysbench-client-load 2>&1 | grep -E "transactions|queries" >> $REPORT_FILE
    } 2>&1 | tee -a $LOG_FILE
}

function run_graph_analytics() {
    echo -e "\nRunning Graph Analytics benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "graph_analytics"

    # Create dataset container
    docker create --name twitter-data cloudsuite/twitter-dataset-graph

    # Run benchmark in detached mode and redirect output to log file
    docker run -d --name graph-analytics --volumes-from twitter-data -e WORKLOAD_NAME=pr \
        cloudsuite/graph-analytics --driver-memory 8g --executor-memory 8g \
        2>&1 | tee -a $LOG_FILE
    monitor_container "graph-analytics"

    # Wait for benchmark to complete
    docker wait graph-analytics

    # Stop logging and remove benchmark container
    stop_container_logging "graph-analytics"
    docker rm graph-analytics

    # Stop and remove dataset container
    docker rm twitter-data

    stop_perf_record

    # Collect and append results to the report file
    echo "Graph Analytics Results:" >> $REPORT_FILE
    docker logs graph-analytics 2>&1 | grep -E "Time taken|Iterations" >> $REPORT_FILE
}

function run_in_memory_analytics() {
    echo -e "\nRunning In-Memory Analytics benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "in_memory_analytics"

    # Create dataset container
    docker create --name movielens-data cloudsuite/movielens-dataset
    sleep 10  # Wait for dataset to initialize

    # Run benchmark in detached mode and redirect output to log file
    docker run -d --name in-memory-analytics --volumes-from movielens-data \
        cloudsuite/in-memory-analytics /data/ml-latest-small /data/myratings.csv \
        --driver-memory 4g --executor-memory 4g \
        2>&1 | tee -a $LOG_FILE
    monitor_container "in-memory-analytics"

    # Wait for benchmark to complete
    docker wait in-memory-analytics

    # Stop logging and remove benchmark container
    stop_container_logging "in-memory-analytics"
    docker rm in-memory-analytics

    # Stop and remove dataset container
    docker rm movielens-data

    stop_perf_record

    # Collect and append results to the report file
    echo "In-Memory Analytics Results:" >> $REPORT_FILE
    docker logs in-memory-analytics 2>&1 | grep -E "RMSE|Time" >> $REPORT_FILE
}

function run_media_streaming() {
    {
        echo -e "\nRunning Media Streaming benchmark with performance monitoring..."

        start_perf_record "media_streaming"

        # Define variables
        DATASET_SIZE=5            # GB, adjust as needed
        SESSION_COUNT=10          # Number of sessions per resolution
        NGINX_WORKERS=2000        # Adjust based on server resources
        SERVER_IP="localhost"
        VIDEOPERF_PROCESSES=4     # Number of videoperf processes
        VIDEO_COUNT=1000          # Total number of videos to request
        RATE=10                   # Videos per second
        ENCRYPTION_MODE="PT"      # "PT" for plain text or "TLS" for TLS encryption

        # Start dataset container
        docker run --name streaming_dataset cloudsuite/media-streaming:dataset $DATASET_SIZE $SESSION_COUNT \
            2>&1 | tee -a $LOG_FILE
        if ! monitor_container "streaming_dataset"; then
            echo -e "\nError: Failed to monitor streaming_dataset" >&2
            return 1
        fi

        # Wait for dataset to initialize
        sleep 25

        # Start server container
        docker run -d --name streaming_server --volumes-from streaming_dataset \
            --net host \
            -v "$CONTAINER_LOGS_DIR:/var/log/nginx" \
            cloudsuite/media-streaming:server $NGINX_WORKERS \
            2>&1 | tee -a $LOG_FILE
        if ! monitor_container "streaming_server"; then
            echo -e "\nError: Failed to monitor streaming_server" >&2
            return 1
        fi

        sleep 30  # Wait for server to initialize

        # Copy session lists from dataset container to local directory
        SESSION_LIST_DIR="$(pwd)/$OUTPUT_DIR/session_lists"
        mkdir -p "$SESSION_LIST_DIR"
        docker cp streaming_dataset:/videos/logs "$SESSION_LIST_DIR"

        # Start client container
        RESULTS_DIR="$(pwd)/$OUTPUT_DIR/client_results"
        mkdir -p "$RESULTS_DIR"
        docker run -t --name streaming_client \
            -v "${SESSION_LIST_DIR}/logs:/videos/logs" \
            -v "${RESULTS_DIR}:/output" \
            --net host cloudsuite/media-streaming:client \
            $SERVER_IP $VIDEOPERF_PROCESSES $VIDEO_COUNT $RATE $ENCRYPTION_MODE \
            > "$LOG_DIR/streaming_client.log" 2>&1
        if ! monitor_container "streaming_client"; then
            echo -e "\nError: Failed to monitor streaming_client" >&2
            return 1
        fi

        # Wait for client to finish
        docker wait streaming_client

        # Stop logging and remove client container
        stop_container_logging "streaming_client"
        docker rm streaming_client

        # Stop logging and remove server container
        stop_container_logging "streaming_server"
        docker stop streaming_server
        docker rm streaming_server

        # Stop logging and remove dataset container
        stop_container_logging "streaming_dataset"
        docker rm streaming_dataset

        stop_perf_record

        # Collect and append results to the report file
        echo "Media Streaming Results:" >> $REPORT_FILE
        docker logs streaming_client 2>&1 | grep -E "Throughput|Latency" >> $REPORT_FILE
    } 2>&1 | tee -a $LOG_FILE
}

function run_web_search() {
    {
        echo -e "\nRunning Web Search benchmark with performance monitoring..."

        start_perf_record "web_search"

        # Create dataset container
        docker run --name web_search_dataset cloudsuite/web-search:dataset \
            2>&1 | tee -a $LOG_FILE

        # Start server container
        docker run -d --name server --volumes-from web_search_dataset \
            --net host cloudsuite/web-search:server 14g 1 \
            2>&1 | tee -a $LOG_FILE
        monitor_container "server"

        sleep 30  # Wait for server to initialize

        # Start client in detached mode
        docker run -d --name web_search_client --net host \
            cloudsuite/web-search:client localhost 8 \
            2>&1 | tee -a $LOG_FILE
        monitor_container "web_search_client"

        # Wait for client to finish
        docker wait web_search_client

        # Stop logging and remove client container
        stop_container_logging "web_search_client"
        docker rm web_search_client

        # Stop logging and remove server container
        stop_container_logging "server"
        docker stop server
        docker rm server

        # Stop and remove dataset container
        docker rm web_search_dataset

        stop_perf_record

        # Collect and append results to the report file
        echo "Web Search Results:" >> $REPORT_FILE
        docker logs web_search_client 2>&1 | grep -E "Queries per second|Latency" >> $REPORT_FILE
    } 2>&1 | tee -a $LOG_FILE
}

function run_web_serving() {
    echo -e "\nRunning Web Serving benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "web_serving"

    # Set variables
    WEB_SERVER_IP="127.0.0.1"
    DATABASE_SERVER_IP="127.0.0.1"
    MEMCACHED_SERVER_IP="127.0.0.1"
    PROTOCOL="http"
    MAX_PM_CHILDREN=4
    WORKER_PROCESS="auto"
    LOAD_SCALE=1

    # Start database server
    docker run -d --net=host --name=database_server cloudsuite/web-serving:db_server

    # Start memcached server
    docker run -d --net=host --name=memcached_server cloudsuite/web-serving:memcached_server

    # Start web server
    docker run -d --net=host --name=web_server cloudsuite/web-serving:web_server \
        /etc/bootstrap.sh $PROTOCOL $WEB_SERVER_IP $DATABASE_SERVER_IP $MEMCACHED_SERVER_IP \
        $MAX_PM_CHILDREN $WORKER_PROCESS

    # Monitor containers
    monitor_container "web_server"
    monitor_container "database_server"
    monitor_container "memcached_server"

    # Wait for web server to be ready
    sleep 30

    # Start client with correct web server IP
    docker run --net=host --name=faban_client cloudsuite/web-serving:faban_client \
        $WEB_SERVER_IP $LOAD_SCALE

    # Collect client logs
    collect_container_logs "faban_client"

    # Stop and remove containers
    docker stop faban_client web_server memcached_server database_server
    docker rm faban_client web_server memcached_server database_server

    stop_perf_record

    # Collect and append results to the report file
    echo "Web Serving Results:" >> $REPORT_FILE
}

function run_data_analytics() {
    echo -e "\nRunning Data Analytics benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "data_analytics"

    # Create dataset container
    docker create --name wikimedia-dataset cloudsuite/wikimedia-pages-dataset \
        2>&1 | tee -a $LOG_FILE
    monitor_container "wikimedia-dataset"

    # Create a User-Defined Network
    docker network create hadoop-net

    # Start the Hadoop master node
    docker run -d --net hadoop-net --volumes-from wikimedia-dataset --name data-master \
        cloudsuite/data-analytics --master \
        --hdfs-block-size=64 \
        --yarn-cores=4 \
        --mapreduce-mem=4096 \
        2>&1 | tee -a $LOG_FILE
    if ! wait_for_container "data-master"; then
        echo -e "\nError: Data Analytics master failed to start" >&2
        return 1
    fi
    monitor_container "data-master"

    # Start Hadoop slave nodes
    NUM_SLAVES=4
    for i in $(seq 1 $NUM_SLAVES); do
        docker run -d --net hadoop-net --name data-slave0$i \
            cloudsuite/data-analytics --slave --master-ip=data-master \
            2>&1 | tee -a $LOG_FILE
        if ! wait_for_container "data-slave0$i"; then
            echo -e "\nError: Data Analytics slave data-slave0$i failed to start" >&2
            return 1
        fi
        monitor_container "data-slave0$i"
    done

    sleep 30  # Wait for the cluster to initialize

    # Run the benchmark inside the master container
    docker exec data-master benchmark

    # Stop logging and remove master container
    stop_container_logging "data-master"
    docker rm data-master

    # Stop logging and remove slave containers
    for i in $(seq 1 $NUM_SLAVES); do
        stop_container_logging "data-slave0$i"
        docker rm data-slave0$i
    done

    # Stop logging and remove dataset container
    stop_container_logging "wikimedia-dataset"
    docker rm wikimedia-dataset

    # Remove the network
    docker network rm hadoop-net

    stop_perf_record

    # Collect and append results to the report file
    echo "Data Analytics Results:" >> $REPORT_FILE
    # Add commands to extract relevant results from the master container logs
}

function run_data_caching() {
    echo -e "\nRunning Data Caching benchmark with performance monitoring..." | tee -a $LOG_FILE
    start_perf_record "data_caching"

    # Start Memcached server
    docker run -d --name dc-server --net host cloudsuite/data-caching:server -t 4 -m 10240 -n 550 \
        2>&1 | tee -a $LOG_FILE
    if ! wait_for_container "dc-server"; then
        echo -e "\nError: Memcached server failed to start" >&2
        return 1
    fi
    monitor_container "dc-server"

    # Wait for server to initialize
    sleep 10

    # Create client configuration directory and file
    mkdir -p docker_servers
    echo "127.0.0.1, 11211" > docker_servers/docker_servers.txt

    # Start client container
    docker run -idt --name dc-client --net host -v "$PWD/docker_servers":/usr/src/memcached/memcached_client/docker_servers/ \
        cloudsuite/data-caching:client \
        2>&1 | tee -a $LOG_FILE
    if ! wait_for_container "dc-client"; then
        echo -e "\nError: Data Caching client failed to start" >&2
        return 1
    fi
    sleep 20
    monitor_container "dc-client"

    # Warm up the server
    echo -e "\nWarming up the server..." | tee -a $LOG_FILE
    docker exec dc-client /bin/bash /entrypoint.sh --m="S&W" --S=28 --D=10240 --w=8 --T=1 | tee -a $LOG_FILE

    # Run the benchmark to determine maximum throughput
    echo -e "\nDetermining maximum throughput..." | tee -a $LOG_FILE
    THROUGHPUT_OUTPUT=$(docker exec dc-client timeout 120 /bin/bash /entrypoint.sh --m="TH" --S=28 --g=0.8 --c=200 --w=8 --T=1 | tee -a $LOG_FILE)

    # Extract MAX_THROUGHPUT from the output by finding the maximum 'rps' value
    MAX_THROUGHPUT=$(echo "$THROUGHPUT_OUTPUT" | awk -F', *' '/^[0-9]+,/ {print $3}' | sort -n | tail -1)

    # Calculate TARGET_RPS as 90% of MAX_THROUGHPUT
    TARGET_RPS=$(echo "$MAX_THROUGHPUT * 0.9" | bc | awk '{printf "%.0f", $0}')

    # Run the benchmark with TARGET_RPS
    echo -e "\nRunning the benchmark with TARGET_RPS=$TARGET_RPS..." | tee -a $LOG_FILE
    docker exec dc-client timeout 60 /bin/bash /entrypoint.sh --m="RPS" --S=28 --g=0.8 --c=200 --w=8 --T=1 --r="$TARGET_RPS" | tee -a $LOG_FILE

    # Stop logging and remove client container
    stop_container_logging "dc-client"
    docker stop dc-client
    docker rm dc-client

    # Stop logging and remove server container
    stop_container_logging "dc-server"
    docker stop dc-server
    docker rm dc-server

    # Remove client configuration directory
    rm -rf docker_servers

    stop_perf_record

    # Collect and append results to the report file
    echo "Data Caching Results:" >> $REPORT_FILE
    docker logs dc-client 2>&1 | grep -E "Total Statistics|Average Latency|99th" >> $REPORT_FILE
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

if [ $# -ge 2 ]; then
    if [ "$2" == "all" ]; then
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
    SELECTED_GROUP=1  # Default group
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
echo "- Summary Report: $REPORT_FILE"echo "- Performance Data: $PERF_DATA_DIR"
echo "- Analysis: $ANALYSIS_DIR"
echo "- Summary Report: $REPORT_FILE"