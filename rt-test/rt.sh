#!/bin/bash
# ==============================================================================
# RT Test Tool — unified setup / test / verify for PREEMPT_RT on Qualcomm boards
#
# Usage:
#   sudo ./rt.sh setup   [--platform <name>]
#   sudo ./rt.sh test    [--platform <name>] [-t <minutes>] [--verbose]
#   sudo ./rt.sh verify  [--platform <name>]
#
# Commands:
#   setup    Install linux-qcom-rt kernel, configure GRUB CPU isolation, reboot.
#   test     Apply runtime optimizations and run cyclictest.
#            Runs in quiet mode by default (use --verbose for live output).
#            Optionally drive background CPU load with stress-ng (--load).
#   verify   Check that all RT parameters are correctly configured.
#
# The platform is auto-detected from the device-tree model.
# Use --platform to override.
# ==============================================================================

set -euo pipefail

STATE_DIR="/var/lib/rt-test"
PREV_KERNEL_FILE="${STATE_DIR}/prev_kernel"
GRUB_CFG="/etc/default/grub.d/98_realtime.cfg"

# ------------------------------------------------------------------------------
# Platform device-tree model matching
#
# Detection reads /proc/device-tree/model (falls back to
# /sys/firmware/devicetree/base/model) and matches it against these
# case-insensitive extended-regex patterns. Order matters: the first match
# in PLATFORM_ORDER wins.
#
# Reference DT model strings:
#   rb8      Qualcomm Technologies, Inc. IQ-9075-evk Addons Mezzanin
#   amr      Qualcomm Technologies, Inc. Addons Lemans AMR
#   rb4      Qualcomm Technologies, Inc. IQ8 8275 Pro SKU EVK
#   monza2   Qualcomm Technologies, Inc. Monaco Monza addons
#   hamoa    Qualcomm Technologies, Inc. Hamoa IoT EVK
#   rb3lite  Qualcomm Technologies, Inc. qcs5430 fp1 addons rb3gen2 vision mezz platform
#   rb3      Qualcomm Technologies, Inc. Robotics RB3gen2 addons vision mezz platform
# ------------------------------------------------------------------------------
# rb3lite is checked before rb3 because both DT strings contain "rb3gen2".
PLATFORM_ORDER=(hamoa rb8 amr rb4 monza2 rb3lite rb3)

PLATFORM_REGEX_rb8='9075'
PLATFORM_REGEX_amr='lemans amr'
PLATFORM_REGEX_rb4='iq8 8275'
PLATFORM_REGEX_monza2='monza'
PLATFORM_REGEX_hamoa='hamoa'
PLATFORM_REGEX_rb3lite='qcs5430 fp1'
PLATFORM_REGEX_rb3='robotics rb3gen2'

# ------------------------------------------------------------------------------
# Extra kernel command-line arguments
#
# Appended to GRUB_CMDLINE_LINUX during 'setup', on top of the CPU-isolation
# parameters, and verified against /proc/cmdline during 'verify'. Every
# platform except hamoa gets EXTRA_CMDLINE_COMMON; hamoa gets none. Override
# per platform inside configure_platform() if a board needs different args.
#
# TODO: set the actual extra args required by the non-hamoa platforms.
# Example: EXTRA_CMDLINE_COMMON="pcie_aspm=off clk_ignore_unused"
# ------------------------------------------------------------------------------
EXTRA_CMDLINE_COMMON=" rcupdate.rcu_expedited=1 "

# ------------------------------------------------------------------------------
# Per-platform parameters
# ------------------------------------------------------------------------------
configure_platform() {
    case "${PLATFORM}" in
        rb8)
            RT_CPU=7
            TOTAL_CPUS=8
            HOUSEKEEP_RANGE="0-6"
            IRQ_MASK="7f"
            WQ_MASK="7F"
            PLATFORM_LABEL="RB8 (IQ-9075)"
            EXTRA_CMDLINE="${EXTRA_CMDLINE_COMMON}"
            ;;
        amr)
            # Same configuration as rb8.
            RT_CPU=7
            TOTAL_CPUS=8
            HOUSEKEEP_RANGE="0-6"
            IRQ_MASK="7f"
            WQ_MASK="7F"
            PLATFORM_LABEL="AMR (Lemans)"
            EXTRA_CMDLINE="${EXTRA_CMDLINE_COMMON}"
            ;;
        rb4)
            RT_CPU=3
            TOTAL_CPUS=8
            HOUSEKEEP_RANGE="0-2,4-7"
            IRQ_MASK="f7"
            WQ_MASK="F7"
            PLATFORM_LABEL="RB4 (IQ8 8275)"
            EXTRA_CMDLINE="${EXTRA_CMDLINE_COMMON}"
            ;;
        monza2)
            # Same configuration as rb4.
            RT_CPU=3
            TOTAL_CPUS=8
            HOUSEKEEP_RANGE="0-2,4-7"
            IRQ_MASK="f7"
            WQ_MASK="F7"
            PLATFORM_LABEL="Monza2 (Monaco)"
            EXTRA_CMDLINE="${EXTRA_CMDLINE_COMMON}"
            ;;
        hamoa)
            RT_CPU=11
            TOTAL_CPUS=12
            HOUSEKEEP_RANGE="0-10"
            IRQ_MASK="7ff"
            WQ_MASK="7FF"
            PLATFORM_LABEL="Hamoa (IoT EVK)"
            EXTRA_CMDLINE=""
            ;;
        rb3lite)
            RT_CPU=5
            TOTAL_CPUS=6
            HOUSEKEEP_RANGE="0-4"
            IRQ_MASK="1f"
            WQ_MASK="1F"
            PLATFORM_LABEL="RB3 Gen2 Lite (QCS5430)"
            EXTRA_CMDLINE="${EXTRA_CMDLINE_COMMON}"
            ;;
        rb3)
            # Same configuration as rb8.
            RT_CPU=7
            TOTAL_CPUS=8
            HOUSEKEEP_RANGE="0-6"
            IRQ_MASK="7f"
            WQ_MASK="7F"
            PLATFORM_LABEL="RB3 Gen2"
            EXTRA_CMDLINE="${EXTRA_CMDLINE_COMMON}"
            ;;
        *)
            echo "ERROR: Unknown platform '${PLATFORM}'."
            echo "       Supported: ${PLATFORM_ORDER[*]}"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root (sudo)."
        exit 1
    fi
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

read_dt_model() {
    local f
    for f in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
        if [[ -r "${f}" ]]; then
            tr -d '\0' < "${f}"
            return 0
        fi
    done
    return 1
}

detect_platform() {
    DT_MODEL="$(read_dt_model || true)"

    if [[ -n "${PLATFORM}" ]]; then
        log "Platform override : ${PLATFORM} (from --platform)"
        [[ -n "${DT_MODEL}" ]] && log "Device-tree model : ${DT_MODEL}"
        return
    fi

    if [[ -z "${DT_MODEL}" ]]; then
        echo "ERROR: Could not read device-tree model and --platform was not given."
        echo "       Specify the platform manually: --platform <${PLATFORM_ORDER[*]}>"
        exit 1
    fi

    local candidate regex_var
    for candidate in "${PLATFORM_ORDER[@]}"; do
        regex_var="PLATFORM_REGEX_${candidate}"
        if grep -qiE "${!regex_var}" <<<"${DT_MODEL}"; then
            PLATFORM="${candidate}"
            break
        fi
    done

    if [[ -z "${PLATFORM}" ]]; then
        echo "ERROR: Device-tree model did not match any known platform."
        echo "       DT model: '${DT_MODEL}'"
        echo "       Specify the platform manually: --platform <${PLATFORM_ORDER[*]}>"
        exit 1
    fi

    log "Device-tree model : ${DT_MODEL}"
    log "Detected platform : ${PLATFORM}"
}

print_platform_info() {
    echo "Platform       : ${PLATFORM_LABEL}"
    echo "Device-tree    : ${DT_MODEL:-N/A}"
    echo "RT CPU         : ${RT_CPU}"
    echo "Total CPUs     : ${TOTAL_CPUS}"
    echo "Housekeeping   : CPUs ${HOUSEKEEP_RANGE}"
    echo "IRQ mask       : 0x${IRQ_MASK}"
    echo "Workqueue mask : 0x${WQ_MASK}"
    echo "Extra cmdline  : ${EXTRA_CMDLINE:-<none>}"
    echo "Current kernel : $(uname -r)"
    if [[ -r "${PREV_KERNEL_FILE}" ]]; then
        echo "Pre-RT kernel  : $(cat "${PREV_KERNEL_FILE}")"
    fi
    echo ""
}

# ==============================================================================
# COMMAND: setup
# ==============================================================================
cmd_setup() {
    echo "=================================================="
    echo " RT Setup  |  Platform: ${PLATFORM_LABEL}"
    echo "=================================================="
    echo ""
    print_platform_info

    log "==> Recording current (pre-RT) kernel..."
    mkdir -p "${STATE_DIR}"
    uname -r > "${PREV_KERNEL_FILE}"
    log "  Saved pre-RT kernel: $(cat "${PREV_KERNEL_FILE}") -> ${PREV_KERNEL_FILE}"

    log "==> Step 1: Installing RT kernel (linux-qcom-rt)..."
    apt-get install -y linux-qcom-rt
    log "  RT kernel installed."

    log "==> Step 2: Configuring GRUB for CPU isolation..."
    mkdir -p /etc/default/grub.d
    local extra=""
    [[ -n "${EXTRA_CMDLINE}" ]] && extra=" ${EXTRA_CMDLINE}"
    cat > "${GRUB_CFG}" << EOF
# Generated by rt.sh for platform: ${PLATFORM_LABEL}
# Device-tree model: ${DT_MODEL:-N/A}
# Pre-RT kernel: $(cat "${PREV_KERNEL_FILE}")
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX} rcu_nocbs=${RT_CPU} isolcpus=${RT_CPU} irqaffinity=${HOUSEKEEP_RANGE}${extra}"
EOF
    log "  GRUB config written:"
    sed 's/^/    /' "${GRUB_CFG}"

    log "  Running update-grub..."
    update-grub
    log "  GRUB updated."

    echo ""
    log "All done. Rebooting in 5 seconds..."
    log "After reboot, run: sudo ${0##*/} test --platform ${PLATFORM} -t <minutes>"
    sleep 5
    reboot
}

# ==============================================================================
# COMMAND: test  (optimize + cyclictest)
# ==============================================================================
step_verify_kernel() {
    log "==> Verifying RT kernel..."
    log "  Running kernel: $(uname -r)"
    if [[ -r "${PREV_KERNEL_FILE}" ]]; then
        log "  Pre-RT kernel : $(cat "${PREV_KERNEL_FILE}")"
    fi

    if ! uname -r | grep -qiE 'rt|PREEMPT_RT'; then
        echo ""
        echo "ERROR: Not running an RT kernel ($(uname -r))."
        echo "       Check GRUB and ensure the RT kernel entry is selected, then reboot."
        exit 1
    fi

    log "  RT kernel confirmed: $(uname -r)"
    echo ""
}

step_optimize() {
    log "==> Applying runtime optimizations (non-persistent)..."

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

    log "  Optimizations applied (will reset on reboot)."
    echo ""
}

start_stress() {
    [[ -z "${STRESS_LOAD}" ]] && return 0

    if ! command -v stress-ng &>/dev/null; then
        log "  stress-ng not found. Installing stress-ng..."
        apt-get install -y stress-ng
    fi

    log "  Starting stress-ng background load at ${STRESS_LOAD}% on housekeeping CPUs..."
    local cpu
    for cpu in $(seq 0 $(( TOTAL_CPUS - 1 ))); do
        [[ "${cpu}" -eq "${RT_CPU}" ]] && continue
        taskset -c "${cpu}" stress-ng --cpu 1 --cpu-method matrixprod \
            --cpu-load "${STRESS_LOAD}" --temp-path . -t "${TEST_MINUTES}m" \
            >/dev/null 2>&1 &
        STRESS_PIDS+=("$!")
    done
    log "  stress-ng running on ${#STRESS_PIDS[@]} CPU(s), PIDs: ${STRESS_PIDS[*]}"
}

stop_stress() {
    [[ ${#STRESS_PIDS[@]} -eq 0 ]] && return 0
    log "  Stopping stress-ng background load..."
    kill "${STRESS_PIDS[@]}" 2>/dev/null || true
    wait "${STRESS_PIDS[@]}" 2>/dev/null || true
    STRESS_PIDS=()
}

step_test() {
    local interval_us=1000
    local hist_buckets=100
    local iter_per_sec=$(( 1000000 / interval_us ))
    local loop_count=$(( TEST_MINUTES * 60 * iter_per_sec ))

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local base="rt_report_${PLATFORM}_${timestamp}"
    local report_file="${base}.txt"
    local hist_file="${base}.hist"
    local json_file="${base}.json"

    local quiet_flag="-q"
    local quiet_desc="quiet (summary only)"
    if [[ "${VERBOSE}" == true ]]; then
        quiet_flag=""
        quiet_desc="verbose (live output)"
    fi

    local load_desc="none (idle)"
    [[ -n "${STRESS_LOAD}" ]] && load_desc="stress-ng ${STRESS_LOAD}% on housekeeping CPUs"

    # Ensure background stress is cleaned up even if cyclictest is interrupted.
    trap stop_stress EXIT INT TERM

    log "==> Running cyclictest..."
    log "  Mode             : ${quiet_desc}"
    log "  Background load  : ${load_desc}"
    log "  Duration         : ${TEST_MINUTES} minute(s)"
    log "  Interval         : ${interval_us} us"
    log "  Total iterations : ${loop_count}"
    log "  Histogram buckets: 0-${hist_buckets} us"
    log "  Report file      : ${report_file}"
    log "  Histogram file   : ${hist_file}"
    log "  JSON final stats : ${json_file}"
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
        echo "Platform       : ${PLATFORM_LABEL}"
        echo "Device-tree    : ${DT_MODEL:-N/A}"
        echo "Kernel         : $(uname -r)"
        [[ -r "${PREV_KERNEL_FILE}" ]] && echo "Pre-RT kernel  : $(cat "${PREV_KERNEL_FILE}")"
        echo "Hostname       : $(hostname)"
        echo "RT CPU         : ${RT_CPU}"
        echo "Housekeeping   : CPUs ${HOUSEKEEP_RANGE}"
        echo "IRQ mask       : 0x${IRQ_MASK}"
        echo "Duration       : ${TEST_MINUTES} minute(s)"
        echo "Interval       : ${interval_us} us"
        echo "Total loops    : ${loop_count}"
        echo "Mode           : ${quiet_desc}"
        echo "CPU load       : ${load_desc}"
        echo "Histogram      : 0-${hist_buckets} us  =>  ${hist_file}"
        echo "JSON result    : ${json_file}"
        echo "============================================================"
        echo ""
    } > "${report_file}"

    start_stress

    log "  Launching cyclictest..."
    echo ""

    local exit_code=0
    # shellcheck disable=SC2086
    cyclictest \
        -a "${RT_CPU}" \
        -t 1 \
        -m \
        ${quiet_flag} \
        -l "${loop_count}" \
        -i "${interval_us}" \
        -p 95 \
        -h "${hist_buckets}" \
        --histfile="${hist_file}" \
        --json="${json_file}" || exit_code=$?

    stop_stress

    # Summarize key latency stats (min/avg/max/cycles from JSON, overflows from
    # the histogram footer) and derive a simple pass/fail verdict.
    local r_min r_avg r_max r_cycles r_over verdict
    r_min=$(grep -oE '"min":[[:space:]]*[0-9.]+' "${json_file}" 2>/dev/null | grep -oE '[0-9.]+$' | head -1)
    r_avg=$(grep -oE '"avg":[[:space:]]*[0-9.]+' "${json_file}" 2>/dev/null | grep -oE '[0-9.]+$' | head -1)
    r_max=$(grep -oE '"max":[[:space:]]*[0-9.]+' "${json_file}" 2>/dev/null | grep -oE '[0-9.]+$' | head -1)
    r_cycles=$(grep -oE '"cycles":[[:space:]]*[0-9]+' "${json_file}" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
    r_over=$(grep -m1 'Histogram Overflows' "${hist_file}" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    r_over=$(( 10#${r_over:-0} ))

    verdict="UNKNOWN (no result data)"
    if [[ -n "${r_max}" ]]; then
        if [[ ${r_over} -eq 0 && $(printf '%.0f' "${r_max}") -le ${hist_buckets} ]]; then
            verdict="PASS  (max ${r_max} us <= ${hist_buckets} us, no overflows)"
        else
            verdict="FAIL  (max ${r_max} us, overflows ${r_over}, limit ${hist_buckets} us)"
        fi
    fi

    {
        echo ""
        echo "============================================================"
        echo " Results"
        echo "============================================================"
        echo "Min latency    : ${r_min:-N/A} us"
        echo "Avg latency    : ${r_avg:-N/A} us"
        echo "Max latency    : ${r_max:-N/A} us"
        echo "Samples        : ${r_cycles:-N/A}"
        echo "Overflows      : ${r_over}  (latencies beyond ${hist_buckets} us)"
        echo "Verdict        : ${verdict}"
        echo "============================================================"
    } | tee -a "${report_file}"

    if [[ -f "${hist_file}" && -s "${hist_file}" ]]; then
        {
            echo ""
            echo "============================================================"
            echo " Histogram  (non-zero bins, ascending latency)"
            echo " Format: latency_us   hit_count"
            echo "------------------------------------------------------------"
            awk '!/^#/ && NF>=2 && $2+0>0 { printf "  %6d us   %12d\n", $1+0, $2+0 }' "${hist_file}" \
                | sort -n
            echo "------------------------------------------------------------"
            echo " Full histogram data: ${hist_file}"
            echo "============================================================"
        } >> "${report_file}"
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
            echo "Exit status    : ${exit_code} (check terminal output)"
        fi
        echo "Report file    : ${report_file}"
        echo "JSON file      : ${json_file}"
        echo "Histogram file : ${hist_file}"
        echo "============================================================"
    } >> "${report_file}"

    log ""
    log "Report   : ${report_file}"
    log "JSON     : ${json_file}"
    log "Histogram: ${hist_file}"
}

cmd_test() {
    echo "=================================================="
    echo " RT Test  |  Platform: ${PLATFORM_LABEL}  |  Minutes: ${TEST_MINUTES}"
    echo "=================================================="
    echo ""
    print_platform_info

    step_verify_kernel
    step_optimize
    step_test

    log "Done."
}

# ==============================================================================
# COMMAND: verify
# ==============================================================================
PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }
warn() { echo "  [WARN] $*"; (( WARN++ )) || true; }

section() {
    echo ""
    echo "----------------------------------------------------------------------"
    echo " $*"
    echo "----------------------------------------------------------------------"
}

check_rt_kernel() {
    section "1. RT Kernel"
    local kernel
    kernel=$(uname -r)
    echo "  Kernel: ${kernel}"
    if [[ -r "${PREV_KERNEL_FILE}" ]]; then
        echo "  Pre-RT kernel: $(cat "${PREV_KERNEL_FILE}")"
    fi

    if echo "${kernel}" | grep -qiE 'rt|PREEMPT_RT'; then
        pass "Running RT kernel: ${kernel}"
    else
        fail "NOT running an RT kernel (got: ${kernel})"
        fail "Run '${0##*/} setup' and reboot into the RT kernel first."
    fi

    if grep -qi 'PREEMPT_RT' /proc/version 2>/dev/null; then
        pass "PREEMPT_RT confirmed in /proc/version"
    else
        warn "PREEMPT_RT not found in /proc/version (may still be RT via uname)"
    fi
}

check_kernel_cmdline() {
    section "2. Kernel Command Line"
    local cmdline
    cmdline=$(cat /proc/cmdline)
    echo "  /proc/cmdline: ${cmdline}"

    if echo "${cmdline}" | grep -q "isolcpus=${RT_CPU}"; then
        pass "isolcpus=${RT_CPU} is set"
    else
        fail "isolcpus=${RT_CPU} is NOT set in kernel cmdline"
    fi

    if echo "${cmdline}" | grep -q "rcu_nocbs=${RT_CPU}"; then
        pass "rcu_nocbs=${RT_CPU} is set"
    else
        fail "rcu_nocbs=${RT_CPU} is NOT set in kernel cmdline"
    fi

    if echo "${cmdline}" | grep -q "irqaffinity=${HOUSEKEEP_RANGE}"; then
        pass "irqaffinity=${HOUSEKEEP_RANGE} is set"
    else
        fail "irqaffinity=${HOUSEKEEP_RANGE} is NOT set in kernel cmdline"
    fi

    if [[ -n "${EXTRA_CMDLINE}" ]]; then
        local arg
        for arg in ${EXTRA_CMDLINE}; do
            if echo "${cmdline}" | grep -qw -- "${arg}"; then
                pass "extra arg '${arg}' is set"
            else
                fail "extra arg '${arg}' is NOT set in kernel cmdline"
            fi
        done
    else
        pass "No extra cmdline args required for this platform"
    fi
}

check_grub_config() {
    section "3. GRUB Configuration"
    if [[ -f "${GRUB_CFG}" ]]; then
        pass "GRUB realtime config exists: ${GRUB_CFG}"
        echo "  Contents:"
        sed 's/^/    /' "${GRUB_CFG}"

        if grep -q "rcu_nocbs=${RT_CPU}" "${GRUB_CFG}" && \
           grep -q "isolcpus=${RT_CPU}" "${GRUB_CFG}" && \
           grep -q "irqaffinity=${HOUSEKEEP_RANGE}" "${GRUB_CFG}"; then
            pass "GRUB config contains correct CPU parameters"
        else
            fail "GRUB config is missing or has incorrect CPU parameters"
        fi
    else
        fail "GRUB realtime config not found: ${GRUB_CFG}"
        fail "Run '${0##*/} setup' to create it."
    fi
}

check_cpu_count() {
    section "4. CPU Count"
    local detected
    detected=$(nproc --all)
    echo "  Detected CPUs: ${detected}"
    echo "  Expected CPUs: ${TOTAL_CPUS}"
    if [[ "${detected}" -eq "${TOTAL_CPUS}" ]]; then
        pass "CPU count matches platform config (${TOTAL_CPUS})"
    else
        fail "CPU count mismatch: expected ${TOTAL_CPUS}, got ${detected}"
    fi
}

check_isolated_cpu() {
    section "5. CPU Isolation"
    local isolated_file="/sys/devices/system/cpu/isolated"
    if [[ -f "${isolated_file}" ]]; then
        local isolated
        isolated=$(cat "${isolated_file}")
        echo "  Isolated CPUs: ${isolated}"
        if [[ "${isolated}" == "${RT_CPU}" ]]; then
            pass "CPU ${RT_CPU} is isolated"
        else
            fail "Expected CPU ${RT_CPU} isolated, got: '${isolated}'"
        fi
    else
        warn "/sys/devices/system/cpu/isolated not found — cannot verify isolation"
    fi
}

check_scaling_governor() {
    section "6. CPU Frequency Governor"
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        local gov cpu
        gov=$(cat "${policy}/scaling_governor" 2>/dev/null || echo "N/A")
        cpu=$(basename "${policy}")
        if [[ "${gov}" == "performance" ]]; then
            pass "${cpu}: scaling_governor = ${gov}"
        else
            fail "${cpu}: scaling_governor = ${gov} (expected: performance)"
        fi
    done
}

check_cstates() {
    section "7. CPU C-States (Idle)"
    local any_enabled=false
    for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
        local val
        val=$(cat "${state}" 2>/dev/null || echo "N/A")
        if [[ "${val}" != "1" ]]; then
            fail "${state} = ${val} (expected: 1 / disabled)"
            any_enabled=true
        fi
    done
    if [[ "${any_enabled}" == false ]]; then
        pass "All CPU C-states are disabled"
    fi
}

check_tracing() {
    section "8. Kernel Tracing"
    local tracing_file="/sys/kernel/tracing/tracing_on"
    if [[ -f "${tracing_file}" ]]; then
        local val
        val=$(cat "${tracing_file}")
        if [[ "${val}" == "0" ]]; then
            pass "Kernel tracing is OFF (tracing_on = 0)"
        else
            fail "Kernel tracing is ON (tracing_on = ${val}, expected 0)"
        fi
    else
        warn "${tracing_file} not found — cannot verify"
    fi
}

check_timer_migration() {
    section "9. Timer Migration"
    local val
    val=$(cat /proc/sys/kernel/timer_migration 2>/dev/null || echo "N/A")
    if [[ "${val}" == "0" ]]; then
        pass "Timer migration is disabled (timer_migration = 0)"
    else
        fail "Timer migration is enabled (timer_migration = ${val}, expected 0)"
    fi
}

check_workqueue_mask() {
    section "10. Workqueue CPU Mask"
    local expected="${WQ_MASK,,}"
    local any_wrong=false
    for file in /sys/devices/virtual/workqueue/*/cpumask; do
        local val
        val=$(cat "${file}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "N/A")
        if [[ "${val}" != "${expected}" ]]; then
            fail "${file} = ${val} (expected: ${expected})"
            any_wrong=true
        fi
    done
    if [[ "${any_wrong}" == false ]]; then
        pass "All workqueue cpumasks = 0x${WQ_MASK}"
    fi
}

check_rt_throttling() {
    section "11. RT Throttling"
    local val
    val=$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || echo "N/A")
    if [[ "${val}" == "-1" ]]; then
        pass "RT throttling is disabled (sched_rt_runtime_us = -1)"
    else
        fail "RT throttling is active (sched_rt_runtime_us = ${val}, expected -1)"
    fi
}

check_irqbalanced() {
    section "12. irqbalanced"
    if systemctl is-active --quiet irqbalanced 2>/dev/null; then
        fail "irqbalanced is running (should be stopped)"
    else
        pass "irqbalanced is not running"
    fi
}

check_irq_affinity() {
    section "13. IRQ SMP Affinity"
    local expected="${IRQ_MASK,,}"
    local wrong=0
    local total=0
    for irq_file in /proc/irq/[0-9]*/smp_affinity; do
        local val
        val=$(cat "${irq_file}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
        [[ -z "${val}" ]] && continue
        (( total++ )) || true
        local val_norm expected_norm
        val_norm=$(printf '%x' "0x${val}" 2>/dev/null || echo "${val}")
        expected_norm=$(printf '%x' "0x${expected}" 2>/dev/null || echo "${expected}")
        if [[ "${val_norm}" != "${expected_norm}" ]]; then
            (( wrong++ )) || true
        fi
    done
    if [[ ${wrong} -eq 0 ]]; then
        pass "All ${total} IRQ smp_affinity masks = 0x${IRQ_MASK}"
    else
        fail "${wrong}/${total} IRQs have incorrect smp_affinity (expected 0x${IRQ_MASK})"
        warn "Some timer IRQs may ignore affinity — this can be normal"
    fi
}

check_cyclictest_installed() {
    section "14. cyclictest"
    if command -v cyclictest &>/dev/null; then
        local ver
        ver=$(cyclictest --help 2>&1 | grep -im1 -oE 'V[ ]*[0-9][0-9.]*' || true)
        [[ -n "${ver}" ]] && ver="cyclictest ${ver}" || ver="version unknown"
        pass "cyclictest is installed: ${ver}"
    else
        fail "cyclictest is not installed (run: apt install rt-tests)"
    fi
}

print_summary() {
    local total=$(( PASS + FAIL + WARN ))
    echo ""
    echo "======================================================================"
    echo " Verification Summary  |  Platform: ${PLATFORM_LABEL}"
    echo "======================================================================"
    echo "  Total checks : ${total}"
    echo "  Passed       : ${PASS}"
    echo "  Failed       : ${FAIL}"
    echo "  Warnings     : ${WARN}"
    echo "======================================================================"

    if [[ ${FAIL} -eq 0 ]]; then
        echo ""
        echo "  System is correctly configured for RT testing."
        echo ""
        return 0
    else
        echo ""
        echo "  ${FAIL} check(s) failed. Fix the issues above before running cyclictest."
        echo ""
        return 1
    fi
}

cmd_verify() {
    echo "======================================================================"
    echo " RT Setup Verification  |  Platform: ${PLATFORM_LABEL}  |  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================================"
    print_platform_info

    check_rt_kernel
    check_kernel_cmdline
    check_grub_config
    check_cpu_count
    check_isolated_cpu
    check_scaling_governor
    check_cstates
    check_tracing
    check_timer_migration
    check_workqueue_mask
    check_rt_throttling
    check_irqbalanced
    check_irq_affinity
    check_cyclictest_installed

    print_summary
}

# ==============================================================================
# Argument parsing
# ==============================================================================
usage() {
    cat <<EOF
Usage: sudo ${0##*/} <command> [options]

Commands:
  setup    Install linux-qcom-rt kernel, configure GRUB CPU isolation, reboot.
  test     Apply runtime optimizations and run cyclictest.
           Runs in quiet mode by default (use --verbose for live output).
  verify   Check that all RT parameters are correctly configured.

Options:
  -p, --platform <name>  Override device-tree platform auto-detection.
  -t, --time <minutes>   cyclictest duration in minutes (test only, default 60).
  -l, --load [PCT]       Run stress-ng background load on housekeeping CPUs
                         while testing (test only, default 60%).
  -v, --verbose          Run cyclictest with live output (test only).
  -h, --help             Show this help.

Platforms:
  rb8      IQ-9075                — 8  CPUs (0-7),  RT CPU=7,  housekeeping=0-6
  amr      Lemans AMR (=rb8)      — 8  CPUs (0-7),  RT CPU=7,  housekeeping=0-6
  rb4      IQ8 8275               — 8  CPUs (0-7),  RT CPU=3,  housekeeping=0-2,4-7
  monza2   Monaco Monza (=rb4)    — 8  CPUs (0-7),  RT CPU=3,  housekeeping=0-2,4-7
  hamoa    Hamoa IoT EVK          — 12 CPUs (0-11), RT CPU=11, housekeeping=0-10
  rb3lite  QCS5430 RB3gen2        — 6  CPUs (0-5),  RT CPU=5,  housekeeping=0-4
  rb3      Robotics RB3gen2 (=rb8)— 8  CPUs (0-7),  RT CPU=7,  housekeeping=0-6

Examples:
  sudo ${0##*/} setup
  sudo ${0##*/} test -t 720
  sudo ${0##*/} test -t 1440 --load 75
  sudo ${0##*/} test -p rb4 -t 360 -l -v
  sudo ${0##*/} verify
EOF
    exit 1
}

COMMAND=""
PLATFORM=""
TEST_MINUTES="60"
VERBOSE=false
DT_MODEL=""
STRESS_LOAD=""
STRESS_PIDS=()

[[ $# -eq 0 ]] && usage

case "$1" in
    setup|test|verify) COMMAND="$1"; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: Unknown command '$1'"; usage ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--platform) PLATFORM="${2,,}"; shift 2 ;;
        -t|--time)
            TEST_MINUTES="$2"
            if ! [[ "${TEST_MINUTES}" =~ ^[1-9][0-9]*$ ]]; then
                echo "ERROR: -t/--time must be a positive integer (minutes). Got: '${TEST_MINUTES}'"
                exit 1
            fi
            shift 2
            ;;
        -l|--load)
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                STRESS_LOAD="$2"
                shift 2
            else
                STRESS_LOAD=60
                shift
            fi
            if [[ "${STRESS_LOAD}" -lt 1 || "${STRESS_LOAD}" -gt 100 ]]; then
                echo "ERROR: --load must be between 1 and 100. Got: '${STRESS_LOAD}'"
                exit 1
            fi
            ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) usage ;;
        *) echo "ERROR: Unknown argument: $1"; usage ;;
    esac
done

check_root
detect_platform
configure_platform

case "${COMMAND}" in
    setup)  cmd_setup ;;
    test)   cmd_test ;;
    verify) cmd_verify ;;
esac
