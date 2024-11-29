#!/bin/bash

./run_benchmarks.sh data-serving > data-serving.log
./run_benchmarks.sh data-serving-relational > data-serving-relational.log
./run_benchmarks.sh data-caching > data-caching.log
./run_benchmarks.sh graph-analytics > graph-analytics.log
./run_benchmarks.sh in-memory-analytics > in-memory-analytics.log
./run_benchmarks.sh media-streaming > media-streaming.log
./run_benchmarks.sh web-search > web-search.log
./run_benchmarks.sh web-serving > web-serving.log