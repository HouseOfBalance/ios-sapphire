#!/bin/bash
# sapphire-perf-monitor.sh - Real-time performance monitoring for Sapphire iOS port
# Run on device: ./sapphire-perf-monitor.sh [interval_ms]
# Default interval: 1000ms (1 second)

INTERVAL_MS=${1:-1000}
INTERVAL_S=$(echo "scale=3; $INTERVAL_MS / 1000" | bc -l 2>/dev/null || echo "1")

echo "=== Sapphire Performance Monitor ==="
echo "Interval: ${INTERVAL_MS}ms"
echo "Press Ctrl+C to stop"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    printf "%-12s %-10s %-10s %-12s %-12s %-10s %-10s %-12s\n" \
        "TIME" "FPS" "FRAMETIME" "GPU_UTIL" "RSCALE" "SCHED" "TOUCH" "FLIP_Q"
}

print_row() {
    local fps=$1 frametime=$2 gpu_util=$3 rscale=$4 sched=$5 touch=$6 flip_q=$7
    local fps_color=$NC
    if (( $(echo "$fps >= 115" | bc -l 2>/dev/null || echo 0) )); then
        fps_color=$GREEN
    elif (( $(echo "$fps >= 90" | bc -l 2>/dev/null || echo 0) )); then
        fps_color=$YELLOW
    else
        fps_color=$RED
    fi
    printf "%-12s ${fps_color}%-10s${NC} %-10s %-12s %-12s %-10s %-10s %-12s\n" \
        "$(date '+%H:%M:%S')" "$fps" "$frametime" "$gpu_util" "$rscale" "$sched" "$touch" "$flip_q"
}

print_header

while true; do
    # Read all sysctls
    GPU_UTIL=$(sysctl -n kern.sweet_fb_dynamic_rscale 2>/dev/null | grep -o 'gpu_util:[0-9]*' | cut -d: -f2)
    RSCALE=$(sysctl -n kern.sweet_fb_dynamic_rscale 2>/dev/null | grep -o 'current:[0-9]*' | cut -d: -f2)
    SCHED_POLICY=$(sysctl -n kern.sweet_sched_policy 2>/dev/null)
    FLIP_Q=$(sysctl -n kern.sweet_fb_pipeline 2>/dev/null | grep -o 'inflight:[0-9]*' | cut -d: -f2)
    TOUCH_STATS=$(sysctl -n kern.sweet_touch_stats 2>/dev/null)
    FENCE_HIST=$(sysctl -n kern.sapphire_gpu_fence_hist 2>/dev/null)
    GPU_BATCH=$(sysctl -n kern.sapphire_gpu_batch 2>/dev/null)
    DL_STATS=$(sysctl -n kern.sapphire_dl_stats 2>/dev/null)

    # Calculate FPS from display link stats if available
    FPS=0
    FRAMETIME=0
    if [ -n "$DL_STATS" ]; then
        MISSED=$(echo "$DL_STATS" | grep -o 'missed:[0-9]*' | cut -d: -f2)
        TOTAL=$(echo "$DL_STATS" | grep -o 'total:[0-9]*' | cut -d: -f2)
        if [ -n "$MISSED" ] && [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
            # Estimate: 120fps ideal, missed frames reduce it
            FPS=$(echo "scale=1; 120 * (1 - $MISSED / $TOTAL)" | bc -l 2>/dev/null || echo "0")
            FRAMETIME=$(echo "scale=2; 1000 / $FPS" | bc -l 2>/dev/null || echo "0")
        fi
    fi

    # Defaults
    [ -z "$GPU_UTIL" ] && GPU_UTIL="N/A"
    [ -z "$RSCALE" ] && RSCALE="N/A"
    [ -z "$SCHED_POLICY" ] && SCHED_POLICY="N/A"
    [ -z "$FLIP_Q" ] && FLIP_Q="N/A"
    [ -z "$FPS" ] && FPS="N/A"
    [ -z "$FRAMETIME" ] && FRAMETIME="N/A"

    print_row "$FPS" "$FRAMETIME" "${GPU_UTIL}‰" "${RSCALE}‰" "$SCHED_POLICY" "OK" "$FLIP_Q"

    sleep "$INTERVAL_S"
done