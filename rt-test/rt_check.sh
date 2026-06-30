#!/bin/bash
# ==============================================================================
# RT Setup Verification Script
# Checks all system parameters are correctly configured for RT testing.
#
# Usage: sudo ./rt_check.sh --board <rb8|rb4|hamoa|rb3lite>
# ==============================================================================

set -euo pipefail

configure_board() {
    case "${BOARD}" in
        rb8)
            RT_CPU=7
            TOTAL_CPUS=8
            HOUSEKEEP_RANGE="0-6"
            IRQ_MASK="7f"
            WQ_MASK="7F"
            BOARD_LABEL="RB8"
            ;;
        rb4)
            RT_CPU=3
            TOTAL_CPUS=8
            HOUSEKEEP_RANGE="0-2,4-7"
            IRQ_MASK="f7"
            WQ_MASK="F7"
            BOARD_LABEL="RB4"
            ;;
        hamoa)
            RT_CPU=11
            TOTAL_CPUS=12
            HOUSEKEEP_RANGE="0-10"
            IRQ_MASK="7ff"
            WQ_MASK="7FF"
            BOARD_LABEL="Hamoa (IQ-X7181)"
            ;;
        rb3lite)
            RT_CPU=1
            TOTAL_CPUS=6
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
}

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

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root (sudo)."
        exit 1
    fi
}

check_rt_kernel() {
    section "1. RT Kernel"

    local kernel
    kernel=$(uname -r)
    echo "  Kernel: ${kernel}"

    if echo "${kernel}" | grep -qiE 'rt|PREEMPT_RT'; then
        pass "Running RT kernel: ${kernel}"
    else
        fail "NOT running an RT kernel (got: ${kernel})"
        fail "Run rt_setup_pre_reboot.sh and reboot into the RT kernel first."
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
}

check_grub_config() {
    section "3. GRUB Configuration"

    local cfg="/etc/default/grub.d/98_realtime.cfg"
    if [[ -f "${cfg}" ]]; then
        pass "GRUB realtime config exists: ${cfg}"
        echo "  Contents:"
        sed 's/^/    /' "${cfg}"

        if grep -q "rcu_nocbs=${RT_CPU}" "${cfg}" && \
           grep -q "isolcpus=${RT_CPU}" "${cfg}" && \
           grep -q "irqaffinity=${HOUSEKEEP_RANGE}" "${cfg}"; then
            pass "GRUB config contains correct CPU parameters"
        else
            fail "GRUB config is missing or has incorrect CPU parameters"
        fi
    else
        fail "GRUB realtime config not found: ${cfg}"
        fail "Run rt_setup_pre_reboot.sh to create it."
    fi
}

check_cpu_count() {
    section "4. CPU Count"

    local detected
    detected=$(nproc --all)
    echo "  Detected CPUs: ${detected}"
    echo "  Expected CPUs: ${TOTAL_CPUS}"

    if [[ "${detected}" -eq "${TOTAL_CPUS}" ]]; then
        pass "CPU count matches board config (${TOTAL_CPUS})"
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
        local gov
        gov=$(cat "${policy}/scaling_governor" 2>/dev/null || echo "N/A")
        local cpu
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
        ver=$(cyclictest --version 2>&1 || true)
        pass "cyclictest is installed: ${ver}"
    else
        fail "cyclictest is not installed (run: apt install rt-tests)"
    fi
}

print_summary() {
    local total=$(( PASS + FAIL + WARN ))
    echo ""
    echo "======================================================================"
    echo " Verification Summary  |  Board: ${BOARD_LABEL}"
    echo "======================================================================"
    echo "  Total checks : ${total}"
    echo "  Passed       : ${PASS}"
    echo "  Failed       : ${FAIL}"
    echo "  Warnings     : ${WARN}"
    echo "======================================================================"

    if [[ ${FAIL} -eq 0 ]]; then
        echo ""
        echo "  ✓ System is correctly configured for RT testing."
        echo ""
        return 0
    else
        echo ""
        echo "  ✗ ${FAIL} check(s) failed. Fix the issues above before running cyclictest."
        echo ""
        return 1
    fi
}

usage() {
    cat <<EOF
Usage: sudo $0 --board <rb8|rb4|hamoa|rb3lite>

Boards:
  rb8      Snapdragon RB8      — 8  CPUs (0-7),  RT CPU=7,  housekeeping=0-6
  rb4      Snapdragon RB4      — 8  CPUs (0-7),  RT CPU=3,  housekeeping=0-2,4-7
  hamoa    Hamoa/IQ-X7181      — 12 CPUs (0-11), RT CPU=11, housekeeping=0-10
  rb3lite  RB3 Lite            — 6  CPUs (0-5),  RT CPU=1,  housekeeping=0,2-5
EOF
    exit 1
}

BOARD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --board) BOARD="${2,,}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "${BOARD}" ]] && { echo "ERROR: --board is required."; usage; }

check_root
configure_board

echo "======================================================================"
echo " RT Setup Verification  |  Board: ${BOARD_LABEL}  |  $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

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
