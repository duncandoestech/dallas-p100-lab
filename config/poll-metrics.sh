#!/bin/bash
# 2 s telemetry from local exporters (:9835 GPU, :9100 node) -> CSV. Run on the GPU host during a benchmark.
OUT=$1; echo "ts,gpu,power_w,temp_c,sm_mhz,util_pct,mem_used_mib,mem_avail_gib,load1" > "$OUT"
while true; do
  ts=$(date +%s); n=$(curl -s --max-time 2 localhost:9100/metrics)
  ma=$(awk "/^node_memory_MemAvailable_bytes/{printf \"%.1f\", \$2/1073741824}" <<<"$n"); l1=$(awk "/^node_load1 /{print \$2}" <<<"$n")
  nvidia-smi --query-gpu=index,power.draw,temperature.gpu,clocks.sm,utilization.gpu,memory.used --format=csv,noheader,nounits | while IFS=", " read -r i p t c u m; do echo "$ts,$i,$p,$t,$c,$u,$m,$ma,$l1"; done >> "$OUT"
  sleep 2
done
