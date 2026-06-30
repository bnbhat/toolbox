#!/bin/bash
# ==============================================================================
# RT Test Setup — Part 2 (Post-Reboot)
# Run this script after rebooting into the RT kernel.
#
# Usage: sudo ./rt_setup_post_reboot.sh --board <rb8|rb4|hamoa|rb3lite> --hours <N>
#
# What it does:
#   1. Verifies RT kernel is running
#   2. Applies runtime optimizations (non-persistent)
#   3. Runs cyclictest and saves report + histogram
# ==============================================================================

set -euo pipefail

configure_board() {
    case "${BOARD}" in
        rb8)
            RT_CPU=7
            HOUSEKEEP_RANGE="0-6"
            IRQ_MASK="7f"
            WQ_MASK="7F"
            BOARD_LABEL="RB8"
            ;;
        rb4)
            RT_CPU=3
            HOUSEKEEP_RANGE="0-2,4-7"
            IRQ_MASK="f7"
            WQ_MASK="F7"
            BOARD_LABEL="RB4"
            ;;
        hamoa)
            RT_CPU=11
            HOUSEKEEP_RANGE="0-10"
            IRQ_MASK="7ff"
            WQ_MASK="7FF"
            BOARD_LABEL="Hamoa (IQ-X7181)"
            ;;
        rb3lite)
            RT_CPU=1
            HOUSEKEEP_RANGE="0,2-5"
            IRQ_MASK="3d"
            WQ_MASK="3D"
            BOARD_LABEL="RB3 Lite"
            ;;
        *)
            echo "ERROR: Unknown board '${BOARD}'. Supported: rb8, rb4, hamoa, rb3lite"
            exit 1
            ;;
    esac

    echo "Board          : ${BOARD_LABEL}"
    echo "RT CPU         : ${RT_CPU}"
    echo "Housekeeping   : CPUs ${HOUSEKEEP_RANGE}"
    echo "IRQ mask       : 0x${IRQ_MASK}"
    echo "Workqueue mask : 0x${WQ_MASK}"
    echo ""
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root (sudo)."
        exit 1
    fi
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

step_verify_kernel() {
    log "==> Step 1: Verifying RT kernel..."
    log "  Running kernel: $(uname -r)"

    if ! uname -r | grep -qiE 'rt|PREEMPT_RT'; then
        echo ""
        echo "ERROR: Not running an RT kernel ($(uname -r))."
        echo "       Check your GRUB config and ensure the RT kernel entry is selected."
        echo "       You may need to set GRUB_DEFAULT in /etc/default/grub to match"
        echo "       the RT kernel menu entry, then run: update-grub && reboot"
        exit 1
    fi

    log "  RT kernel confirmed: $(uname -r)"
    uname -a
    echo ""
}

step_optimize() {
    log "==> Step 2: Applying runtime optimizations..."

    log "  Setting scaling_governor to 'performance'..."
    for file in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        [[ -w "${file}" ]] && echo performance > "${file}"
    done

    log "  Disabling CPU C-states..."
    for cpu in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
        [[ -w "${cpu}" ]] && echo 1 > "${cpu}"
    done

    log "  Disabling kernel tracing..."
    [[ -w /sys/kernel/tracing/tracing_on ]] && echo 0 > /sys/kernel/tracing/tracing_on

    log "  Disabling timer migration..."
    echo 0 > /proc/sys/kernel/timer_migration

    log "  Setting workqueue cpumask to 0x${WQ_MASK}..."
    for file in /sys/devices/virtual/workqueue/*/cpumask; do
        [[ -w "${file}" ]] && echo "${WQ_MASK}" > "${file}"
    done

    log "  Disabling RT throttling..."
    echo -1 > /proc/sys/kernel/sched_rt_runtime_us

    log "  Stopping irqbalanced (if present)..."
    systemctl is-active --quiet irqbalanced 2>/dev/null && systemctl stop irqbalanced || true

    log "  Setting IRQ smp_affinity to 0x${IRQ_MASK}..."
    for irq in /proc/irq/[0-9]*/smp_affinity; do
        [[ -w "${irq}" ]] && echo "${IRQ_MASK}" > "${irq}" 2>/dev/null || true
    done

    log "  Optimizations applied (non-persistent, will reset on reboot)."
    echo ""
}

step_test() {
    local interval_us=1000
    local hist_buckets=100
    local iter_per_sec=$(( 1000000 / interval_us ))
    local loop_count=$(( TEST_HOURS * 3600 * iter_per_sec ))

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local base="rt_report_${BOARD}_${timestamp}"
    local report_file="${base}.txt"
    local hist_file="${base}.hist"

    log "==> Step 3: Running cyclictest..."
    log "  Duration         : ${TEST_HOURS} hour(s)"
    log "  Interval         : ${interval_us} us"
    log "  Total iterations : ${loop_count}"
    log "  Histogram buckets: 0-${hist_buckets} us"
    log "  Report file      : ${report_file}"
    log "  Histogram file   : ${hist_file}"
    echo ""

    if ! command -v cyclictest &>/dev/null; then
        log "  cyclictest not found. Installing rt-tests..."
        apt-get install -y rt-tests
    fi

    {
        echo "============================================================"
        echo " Cyclictest RT Latency Report"
        echo "============================================================"
        echo "Date           : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Board          : ${BOARD_LABEL}"
        echo "Kernel         : $(uname -r)"
        echo "Hostname       : $(hostname)"
        echo "RT CPU         : ${RT_CPU}"
        echo "Housekeeping   : CPUs ${HOUSEKEEP_RANGE}"
        echo "IRQ mask       : 0x${IRQ_MASK}"
        echo "Duration       : ${TEST_HOURS} hour(s)"
        echo "Interval       : ${interval_us} us"
        echo "Total loops    : ${loop_count}"
        echo "Histogram      : 0-${hist_buckets} us  =>  ${hist_file}"
        echo "Command        : cyclictest -a ${RT_CPU} -t 1 -m \\\""
        echo "                   -l ${loop_count} -i ${interval_us} -p 95 \\\""
        echo "                   -h ${hist_buckets} --histfile=${hist_file}"
        echo "============================================================"
        echo ""
    } | tee "${report_file}"

    log "  Launching cyclictest... (Press Ctrl+C to stop early)"
    echo ""

    local exit_code=0
    cyclictest \
        -a "${RT_CPU}" \
        -t 1 \
        -m \
        -l "${loop_count}" \
        -i "${interval_us}" \
        -p 95 \
        -h "${hist_buckets}" \
        --histfile="${hist_file}" \
        2>&1 | tee -a "${report_file}" || exit_code=$?

    if [[ -f "${hist_file}" && -s "${hist_file}" ]]; then
        {
            echo ""
            echo "============================================================"
            echo " Histogram Summary  (from ${hist_file})"
            echo " Format: latency_us   hit_count"
            echo "------------------------------------------------------------"
            awk '!/^#/ && NF>=2 && $2>0 { printf "  %6s us   %s\n", $1, $2 }' "${hist_file}" \
                | sort -k1 -rn \
                | head -20
            echo "------------------------------------------------------------"
            echo " Full histogram data: ${hist_file}"
            echo "============================================================"
        } | tee -a "${report_file}"
    fi

    {
        echo ""
        echo "============================================================"
        echo " Test Complete"
        echo "============================================================"
        echo "End time       : $(date '+%Y-%m-%d %H:%M:%S')"
        if [[ ${exit_code} -eq 0 ]]; then
            echo "Exit status    : 0 (SUCCESS)"
        else
            echo "Exit status    : ${exit_code} (check output above)"
        fi
        echo "Report file    : ${report_file}"
        echo "Histogram file : ${hist_file}"
        echo "============================================================"
    } | tee -a "${report_file}"

    log ""
    log "Report   : ${report_file}"
    log "Histogram: ${hist_file}"
}

usage() {
    cat <<EOF
Usage: sudo $0 --board <rb8|rb4|hamoa|rb3lite> --hours <N>

Boards:
  rb8      Snapdragon RB8      — 8  CPUs (0-7),  RT CPU=7,  housekeeping=0-6
  rb4      Snapdragon RB4      — 8  CPUs (0-7),  RT CPU=3,  housekeeping=0-2,4-7
  hamoa    Hamoa/IQ-X7181      — 12 CPUs (0-11), RT CPU=11, housekeeping=0-10
  rb3lite  RB3 Lite            — 6  CPUs (0-5),  RT CPU=1,  housekeeping=0,2-5

Options:
  --hours N   Duration for cyclictest in hours (required, must be >= 1)

Output files:
  rt_report_<board>_<timestamp>.txt   Human-readable report
  rt_report_<board>_<timestamp>.hist  Raw histogram TSV from cyclictest
EOF
    exit 1
}

BOARD=""
TEST_HOURS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --board) BOARD="${2,,}"; shift 2 ;;
        --hours)
            TEST_HOURS="$2"
            if ! [[ "${TEST_HOURS}" =~ ^[1-9][0-9]*$ ]]; then
                echo "ERROR: --hours must be a positive integer. Got: '${TEST_HOURS}'"
                exit 1
            fi
            shift 2
            ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "${BOARD}" ]] && { echo "ERROR: --board is required."; usage; }
[[ -z "${TEST_HOURS}" ]] && { echo "ERROR: --hours is required."; usage; }

check_root
configure_board

echo "=================================================="
echo " RT Setup Part 2 (Post-Reboot)  |  Board: ${BOARD_LABEL}  |  Hours: ${TEST_HOURS}"
echo "=================================================="
echo ""

step_verify_kernel
step_optimize
step_test

log "Done."
