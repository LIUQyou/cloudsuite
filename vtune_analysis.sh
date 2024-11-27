
#!/bin/bash

# Setup environment
source /opt/intel/oneapi/vtune/latest/vtune-vars.sh

# Basic hotspot analysis
vtune -collect hotspots \
      -knob sampling-mode=hw \
      -knob sampling-interval=1 \
      -- ./your_program

# Memory access analysis
vtune -collect memory-access \
      -knob analyze-mem-objects=true \
      -- ./your_program

# Microarchitecture analysis (similar to perf)
vtune -collect uarch-exploration \
      -knob collect-memory-bandwidth=true \
      -knob enable-stack-collection=true \
      -- ./your_program

# Generate report in text format
vtune -report summary \
      -format text \
      -report-output report.txt \
      -result-dir r000hs