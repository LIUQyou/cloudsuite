#!/bin/bash

# Add output directories
OUTPUT_DIR="benchmark_results"
LOG_DIR="$OUTPUT_DIR/logs"
REPORT_DIR="$OUTPUT_DIR/reports"

function setup_dirs() {
    mkdir -p $LOG_DIR
    mkdir -p $REPORT_DIR
    timestamp=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="$LOG_DIR/benchmark_${timestamp}.log"
    REPORT_FILE="$REPORT_DIR/report_${timestamp}.txt"
}

function log_system_info() {
    {
        echo "=== System Information ==="
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo "CPU Info:"
        lscpu | grep -E "Model name|Socket|Thread|CPU\(s\)|NUMA|CPU MHz"
        echo "Memory Info:"
        free -h
        echo "=======================" 
    } | tee -a $REPORT_FILE
}

function print_usage() {
    echo "Usage: $0 <benchmark> [options]"
    echo "Available benchmarks:"
    echo "  data-serving              - Run Data Serving benchmark"
    echo "  data-serving-relational   - Run Data Serving Relational benchmark"
    echo "  data-caching             - Run Data Caching benchmark"
    echo "  graph-analytics          - Run Graph Analytics benchmark"
    echo "  in-memory-analytics      - Run In-Memory Analytics benchmark"
    echo "  media-streaming          - Run Media Streaming benchmark"
    echo "  web-search              - Run Web Search benchmark"
    echo "  web-serving             - Run Web Serving benchmark"
    echo "  data-analytics           - Run Data Analytics benchmark"
}

function run_data_serving() {
    echo "Running Data Serving benchmark..." | tee -a $LOG_FILE
    {
        # Start server
        docker run -d --name cassandra-server --net host cloudsuite/data-serving:server
        sleep 30  # Wait for server to initialize
        
        # Start client and run warmup
        docker run -it --name cassandra-client --net host cloudsuite/data-serving:client bash -c \
            "./warmup.sh localhost 10000000 4 && ./load.sh localhost 10000000 5000 4"
    } 2>&1 | tee -a $LOG_FILE
    
    # Collect results
    echo "Data Serving Results:" >> $REPORT_FILE
    docker logs cassandra-client 2>&1 | grep -E "Runtime|Throughput|Latency" >> $REPORT_FILE
}

function run_data_serving_relational() {
    echo "Running Data Serving Relational benchmark..." | tee -a $LOG_FILE
    {
        # Start server
        docker run -d --name postgresql-server --net host cloudsuite/data-serving-relational:server
        sleep 30  # Wait for server to initialize
        
        # Run client with TPCC benchmark
        docker run --name sysbench-client --net host cloudsuite/data-serving-relational:client \
            --warmup --tpcc --server-ip=127.0.0.1
        docker run --name sysbench-client-run --net host cloudsuite/data-serving-relational:client \
            --run --tpcc --server-ip=127.0.0.1
    } 2>&1 | tee -a $LOG_FILE
    
    # Collect results
    echo "Data Serving Relational Results:" >> $REPORT_FILE
    docker logs sysbench-client-run 2>&1 | grep -E "transactions|queries|latency" >> $REPORT_FILE
}

function run_data_caching() {
    echo "Running Data Caching benchmark..." | tee -a $LOG_FILE
    {
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
    } 2>&1 | tee -a $LOG_FILE
    
    # Collect results
    echo "Data Caching Results:" >> $REPORT_FILE
    docker logs dc-client 2>&1 | grep -E "Runtime|Throughput|Latency" >> $REPORT_FILE
}

function run_graph_analytics() {
    echo "Running Graph Analytics benchmark..." | tee -a $LOG_FILE
    {
        # Create dataset
        docker create --name twitter-data cloudsuite/twitter-dataset-graph
        
        # Run benchmark
        docker run --rm --volumes-from twitter-data -e WORKLOAD_NAME=pr \
            cloudsuite/graph-analytics --driver-memory 8g --executor-memory 8g
    } 2>&1 | tee -a $LOG_FILE
    
    # Collect results
    echo "Graph Analytics Results:" >> $REPORT_FILE
    docker logs twitter-data 2>&1 | grep -E "Runtime|Throughput|Latency" >> $REPORT_FILE
}

function run_in_memory_analytics() {
    echo "Running In-Memory Analytics benchmark..." | tee -a $LOG_FILE
    {
        # Create dataset
        docker create --name movielens-data cloudsuite/movielens-dataset
        
        # Run benchmark
        docker run --rm --volumes-from movielens-data \
            cloudsuite/in-memory-analytics /data/ml-latest-small /data/myratings.csv \
            --driver-memory 4g --executor-memory 4g
    } 2>&1 | tee -a $LOG_FILE
    
    # Collect results
    echo "In-Memory Analytics Results:" >> $REPORT_FILE
    docker logs movielens-data 2>&1 | grep -E "Runtime|Throughput|Latency" >> $REPORT_FILE
}

function run_media_streaming() {
    echo "Running Media Streaming benchmark..." | tee -a $LOG_FILE
    {
        # Start dataset and server
        docker run --name streaming_dataset cloudsuite/media-streaming:dataset 5 10
        docker run -d --name streaming_server --volumes-from streaming_dataset \
            --net host cloudsuite/media-streaming:server 4
        
        sleep 30  # Wait for server to initialize
        
        # Run client
        docker run --name streaming_client --net host \
            cloudsuite/media-streaming:client localhost 10
    } 2>&1 | tee -a $LOG_FILE
    
    # Collect results
    echo "Media Streaming Results:" >> $REPORT_FILE
    docker logs streaming_client 2>&1 | grep -E "Runtime|Throughput|Latency" >> $REPORT_FILE
}

function run_web_search() {
    echo "Running Web Search benchmark..." | tee -a $LOG_FILE
    {
        # Setup dataset and server
        docker run --name web_search_dataset cloudsuite/web-search:dataset
        docker run -d --name server --volumes-from web_search_dataset \
            --net host cloudsuite/web-search:server 14g 1
        
        sleep 30  # Wait for server to initialize
        
        # Run client
        docker run --rm --name web_search_client --net host \
            cloudsuite/web-search:client localhost 8
    } 2>&1 | tee -a $LOG_FILE
    
    # Collect results
    echo "Web Search Results:" >> $REPORT_FILE
    docker logs web_search_client 2>&1 | grep -E "Runtime|Throughput|Latency" >> $REPORT_FILE
}

function run_web_serving() {
    echo "Running Web Serving benchmark..." | tee -a $LOG_FILE
    {
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
    } 2>&1 | tee -a $LOG_FILE
    
    # Collect results
    echo "Web Serving Results:" >> $REPORT_FILE
    docker logs faban_client 2>&1 | grep -E "Runtime|Throughput|Latency" >> $REPORT_FILE
}

function run_data_analytics() {
    echo "Running Data Analytics benchmark..." | tee -a $LOG_FILE
    {
        # Create dataset
        docker create --name wikimedia-dataset cloudsuite/wikimedia-pages-dataset
        
        # Start master with proper initialization
        docker run -d --net host --volumes-from wikimedia-dataset --name data-master \
            cloudsuite/data-analytics \
            --master \
            --master-ip=127.0.0.1 \
            --hdfs-block-size=64 \
            --yarn-cores=4 \
            --mapreduce-mem=8192
        
        echo "Waiting for master node initialization..." | tee -a $LOG_FILE
        sleep 30  # Initial wait for master startup
        
        # Start worker with explicit memory settings
        docker run -d --net host --name data-slave01 \
            cloudsuite/data-analytics \
            --slave \
            --master-ip=127.0.0.1 \
            --mapreduce-mem=8192
        
        echo "Waiting for worker node registration..." | tee -a $LOG_FILE
        sleep 30
        
        # Verify HDFS and YARN status
        echo "Verifying Hadoop services..." | tee -a $LOG_FILE
        
        # Check if HDFS is running
        if ! docker exec data-master hdfs dfsadmin -report | grep "Live datanodes"; then
            echo "Error: HDFS datanodes not found" >&2
            return 1
        fi
        
        # Check if YARN ResourceManager is running
        if ! docker exec data-master yarn node -list | grep "Total Nodes:"; then
            echo "Error: YARN nodes not registered" >&2
            return 1
        fi
        
        # Format HDFS if needed
        if ! docker exec data-master hdfs dfs -ls / >/dev/null 2>&1; then
            echo "Formatting HDFS..." | tee -a $LOG_FILE
            docker exec data-master hdfs namenode -format -force
            
            # Restart services after format
            docker exec data-master /etc/init.d/hadoop-hdfs-namenode restart
            docker exec data-master /etc/init.d/hadoop-hdfs-datanode restart
            sleep 30
        fi
        
        echo "Running benchmark..." | tee -a $LOG_FILE
        docker exec data-master benchmark
        
        # Collect results
        echo "Data Analytics Results:" >> $REPORT_FILE
        docker logs data-master 2>&1 | grep -E "Runtime|Throughput|Completed" >> $REPORT_FILE
    } 2>&1 | tee -a $LOG_FILE
}

function cleanup() {
    echo "Cleaning up containers..."
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker volume prune -f
    rm -rf docker_servers
}

if [ $# -lt 1 ]; then
    print_usage
    exit 1
fi

# Clean up before running
cleanup

# Main script execution
setup_dirs
log_system_info

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

echo "Benchmark completed! Results available in:"
echo "- Logs: $LOG_FILE"
echo "- Report: $REPORT_FILE"