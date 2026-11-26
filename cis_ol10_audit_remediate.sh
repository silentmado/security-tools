#!/usr/bin/env bash
#===============================================================================
# CIS Oracle Linux 10 Benchmark v1.0.0 (09-29-2025) - Audit & Interactive Remediation
#===============================================================================
# Executes all 328 checks from the CIS Oracle Linux 10 Benchmark v1.0.0.
# For every failed (or manual-review) check, prompts the user whether to
# remediate and asks for any required configuration details.
#
# Usage:
#   sudo ./cis_ol10_audit_remediate.sh [OPTIONS]
#
# Options:
#   -l, --level <1|2|all>       Filter by CIS Level (default: all)
#   -s, --section <1..7>        Run only a specific top-level section (e.g. 5)
#   -i, --id <check_id>         Run only a specific check ID (e.g. 5.1.20)
#   --include-workstation       Include Workstation-only checks on Server
#   --audit-only                Audit only; do not prompt for remediation
#   --auto-yes                  Auto-accept non-interactive remediations
#   --log <file>                Custom log file path
#   -h, --help                  Show this help message
#===============================================================================

set -u
shopt -s nullglob globstar
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --- Globals & Defaults -------------------------------------------------------
FILTER_LEVEL="all"
FILTER_SECTION=""
FILTER_ID=""
INCLUDE_WORKSTATION=0
AUDIT_ONLY=0
AUTO_YES=0
SKIP_ALL=0
LOG_FILE=""

CNT_TOTAL=0
CNT_PASS=0
CNT_FAIL=0
CNT_FIXED=0
CNT_FIX_FAIL=0
CNT_MANUAL=0
CNT_SKIPPED=0
CNT_NA=0

CHECK_DETAIL=""

# Colors (disabled if not a TTY)
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_RESET=''
fi

usage() {
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--level) FILTER_LEVEL="${2:-all}"; shift 2 ;;
        -s|--section) FILTER_SECTION="${2:-}"; shift 2 ;;
        -i|--id) FILTER_ID="${2:-}"; shift 2 ;;
        --include-workstation) INCLUDE_WORKSTATION=1; shift ;;
        --audit-only) AUDIT_ONLY=1; shift ;;
        --auto-yes) AUTO_YES=1; shift ;;
        --log) LOG_FILE="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$LOG_FILE" ]]; then
    if [[ -w /var/log ]]; then
        LOG_FILE="/var/log/cis_ol10_audit_$(date +%Y%m%d_%H%M%S).log"
    else
        LOG_FILE="./cis_ol10_audit_$(date +%Y%m%d_%H%M%S).log"
    fi
fi

log_msg() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Prompt user for a value with optional default
# Usage: ask_input "Prompt text" "default_value" result_var [is_secret]
ask_input() {
    local prompt="$1" default="$2" __var="$3" secret="${4:-0}"
    local val=""
    if [[ "$secret" -eq 1 ]]; then
        read -r -s -p "  -> ${prompt}: " val
        echo ""
    else
        if [[ -n "$default" ]]; then
            read -r -p "  -> ${prompt} [${default}]: " val
            [[ -z "$val" ]] && val="$default"
        else
            read -r -p "  -> ${prompt}: " val
        fi
    fi
    printf -v "$__var" '%s' "$val"
}

# Check if a check matches active CLI filters
should_run() {
    local id="$1" profiles="$2"
    if [[ -n "$FILTER_ID" && "$id" != "$FILTER_ID" ]]; then
        return 1
    fi
    if [[ -n "$FILTER_SECTION" && "${id%%.*}" != "$FILTER_SECTION" ]]; then
        return 1
    fi
    if [[ "$INCLUDE_WORKSTATION" -eq 0 && "$profiles" != *"S"* ]]; then
        return 1
    fi
    case "$FILTER_LEVEL" in
        1) [[ "$profiles" == *"L1"* ]] || return 1 ;;
        2) [[ "$profiles" == *"L2"* ]] || return 1 ;;
    esac
    return 0
}

# Core runner for each CIS recommendation
# Usage: run_check <id> <profiles> <AUTO|MANUAL> <title> <audit_fn> <rem_fn> <rem_desc> [needs_input:0|1]
run_check() {
    local id="$1" profiles="$2" ctype="$3" title="$4" audit_fn="$5" rem_fn="$6" rem_desc="$7" needs_input="${8:-0}"

    should_run "$id" "$profiles" || return 0
    ((CNT_TOTAL++))
    CHECK_DETAIL=""

    local rc=0
    eval "$audit_fn" || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        printf "${C_GREEN}[PASS]${C_RESET} %s - %s\n" "$id" "$title"
        log_msg "[PASS] $id - $title"
        ((CNT_PASS++))
        return 0
    elif [[ "$rc" -eq 2 ]]; then
        printf "${C_CYAN}[N/A]${C_RESET}  %s - %s\n" "$id" "$title"
        [[ -n "$CHECK_DETAIL" ]] && printf "       Details: %s\n" "$CHECK_DETAIL"
        log_msg "[N/A] $id - $title | $CHECK_DETAIL"
        ((CNT_NA++))
        return 0
    fi

    if [[ "$ctype" == "MANUAL" && "$rem_fn" == "manual_only" ]]; then
        printf "${C_YELLOW}[MANUAL]${C_RESET} %s - %s\n" "$id" "$title"
        [[ -n "$CHECK_DETAIL" ]] && printf "         Details: %s\n" "$CHECK_DETAIL"
        log_msg "[MANUAL] $id - $title | $CHECK_DETAIL"
        ((CNT_MANUAL++))
        if [[ "$AUDIT_ONLY" -eq 0 && "$SKIP_ALL" -eq 0 ]]; then
            printf "         Guidance: %s\n" "$rem_desc"
        fi
        return 0
    fi

    printf "${C_RED}[FAIL]${C_RESET} %s - %s\n" "$id" "$title"
    [[ -n "$CHECK_DETAIL" ]] && printf "       Details: %s\n" "$CHECK_DETAIL"
    log_msg "[FAIL] $id - $title | $CHECK_DETAIL"
    ((CNT_FAIL++))

    if [[ "$AUDIT_ONLY" -eq 1 || "$SKIP_ALL" -eq 1 || "$rem_fn" == "manual_only" ]]; then
        [[ "$SKIP_ALL" -eq 1 ]] && ((CNT_SKIPPED++))
        return 0
    fi

    local ans=""
    if [[ "$AUTO_YES" -eq 1 && "$needs_input" -eq 0 ]]; then
        ans="y"
    else
        read -r -p "Do you want to fix issue $id by $rem_desc? [Y/n/s(kip all)/q(uit)] " ans
    fi

    case "${ans,,}" in
        ""|y|yes)
            if eval "$rem_fn"; then
                CHECK_DETAIL=""
                local rrc=0
                eval "$audit_fn" || rrc=$?
                if [[ "$rrc" -eq 0 ]]; then
                    printf "${C_GREEN}[FIXED]${C_RESET} %s remediated and verified.\n" "$id"
                    log_msg "[FIXED] $id"
                    ((CNT_FIXED++))
                else
                    printf "${C_YELLOW}[WARN]${C_RESET} %s remediation ran, but re-audit still reports non-compliant: %s\n" "$id" "$CHECK_DETAIL"
                    log_msg "[FIX_INCOMPLETE] $id | $CHECK_DETAIL"
                    ((CNT_FIX_FAIL++))
                fi
            else
                printf "${C_RED}[ERROR]${C_RESET} %s remediation failed.\n" "$id"
                log_msg "[FIX_ERROR] $id"
                ((CNT_FIX_FAIL++))
            fi
            ;;
        s|skip)
            SKIP_ALL=1
            ((CNT_SKIPPED++))
            log_msg "[SKIP_ALL] $id"
            ;;
        q|quit)
            log_msg "[ABORTED] at $id"
            print_summary
            exit 0
            ;;
        *)
            printf "       Skipped %s.\n" "$id"
            log_msg "[SKIPPED] $id"
            ((CNT_SKIPPED++))
            ;;
    esac
}

manual_only() { return 1; }

# Return 2 (N/A) if any required command is missing
require_cmd() {
    local c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            CHECK_DETAIL="Required command '$c' is not available on this system."
            return 2
        fi
    done
    return 0
}

# Return 2 (N/A) if not running as root
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        CHECK_DETAIL="Requires root privileges to evaluate."
        return 2
    fi
    return 0
}

# Return 2 (N/A) if file is not readable
require_readable() {
    if [[ ! -r "$1" ]]; then
        CHECK_DETAIL="Cannot read '$1' (missing or requires root privileges)."
        return 2
    fi
    return 0
}

#===============================================================================
# Reusable Audit & Remediation Helpers
#===============================================================================

# --- Kernel Modules (1.1.1.1-1.1.1.10, 3.2.1-3.2.6) ---------------------------
audit_kmod() {
    local mod="$1" mtype="${2:-fs}"
    require_cmd lsmod modprobe || return $?
    local found_mod=0 path
    while IFS= read -r path; do
        if [[ -d "$path/${mod//-/\/}" ]] && [[ -n "$(ls -A "$path/${mod//-/\/}" 2>/dev/null)" ]]; then
            found_mod=1
            break
        fi
    done < <(readlink -e /usr/lib/modules/**/kernel/$mtype /lib/modules/**/kernel/$mtype 2>/dev/null | sort -u)

    [[ "$found_mod" -eq 0 ]] && return 0

    if lsmod | grep -qE "^${mod//-/_}\b|\b${mod}\b"; then
        CHECK_DETAIL="Kernel module '$mod' is currently loaded."
        return 1
    fi
    local cfg
    cfg="$(modprobe --showconfig 2>/dev/null)"
    if ! grep -Pq "\bblacklist\h+${mod}\b" <<< "$cfg" || ! grep -Pq "\binstall\h+${mod}\h+/bin/(false|true)\b" <<< "$cfg"; then
        CHECK_DETAIL="Kernel module '$mod' is available and not disabled in modprobe.d."
        return 1
    fi
    return 0
}

fix_kmod() {
    local mod="$1"
    modprobe -r "$mod" 2>/dev/null || rmmod "$mod" 2>/dev/null || true
    printf '%s\n' "install $mod /bin/false" "blacklist $mod" > "/etc/modprobe.d/60-${mod}.conf"
}

# --- Mount Points & Options (1.1.2.*) -----------------------------------------
audit_mount_exists() {
    local mnt="$1"
    require_cmd findmnt || return $?
    if ! findmnt -kn "$mnt" >/dev/null 2>&1; then
        CHECK_DETAIL="$mnt is not mounted as a separate partition or tmpfs."
        return 1
    fi
    return 0
}

audit_mount_opt() {
    local mnt="$1" opt="$2"
    require_cmd findmnt || return $?
    if ! findmnt -kn "$mnt" >/dev/null 2>&1; then
        # If partition doesn't exist, CIS notes option applies if partition exists
        return 0
    fi
    if ! findmnt -kn "$mnt" | grep -qE "\b${opt}\b"; then
        CHECK_DETAIL="Mount option '$opt' is not set on $mnt."
        return 1
    fi
    return 0
}

fix_mount_opt() {
    local mnt="$1" opt="$2"
    if [[ "$mnt" == "/tmp" ]] && systemctl is-enabled tmp.mount >/dev/null 2>&1; then
        mkdir -p /etc/systemd/system/tmp.mount.d
        local cur_opts
        cur_opts="$(findmnt -n -o OPTIONS /tmp 2>/dev/null | tr ' ' ',')"
        [[ -z "$cur_opts" ]] && cur_opts="mode=1777,strictatime,nosuid,nodev,noexec"
        [[ ",$cur_opts," != *",$opt,"* ]] && cur_opts="${cur_opts},${opt}"
        printf '[Mount]\nOptions=%s\n' "$cur_opts" > /etc/systemd/system/tmp.mount.d/cis-options.conf
        systemctl daemon-reload
        mount -o remount,"$opt" "$mnt" 2>/dev/null || true
        return 0
    fi
    if grep -qE "^[^#].*\s+${mnt}\s+" /etc/fstab; then
        awk -v m="$mnt" -v o="$opt" '
            $0 !~ /^#/ && $2 == m {
                if ($4 !~ "(^|,)" o "(,|$)") $4 = $4 "," o
            }
            { print }
        ' /etc/fstab > /etc/fstab.cis.tmp && mv /etc/fstab.cis.tmp /etc/fstab
        mount -o remount "$mnt" 2>/dev/null || mount -o remount,"$opt" "$mnt" 2>/dev/null || true
    elif [[ "$mnt" == "/dev/shm" ]]; then
        printf 'tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0\n' >> /etc/fstab
        mount -o remount,"$opt" /dev/shm 2>/dev/null || true
    else
        echo "  [INFO] $mnt is not in /etc/fstab; attempting live remount with $opt."
        mount -o remount,"$opt" "$mnt" 2>/dev/null || true
    fi
}

# --- Packages -----------------------------------------------------------------
audit_pkg_installed() {
    local pkg="$1"
    require_cmd rpm || return $?
    if ! rpm -q "$pkg" >/dev/null 2>&1; then
        CHECK_DETAIL="Package '$pkg' is not installed."
        return 1
    fi
    return 0
}
fix_pkg_installed() { dnf -y install "$1"; }

audit_pkg_removed() {
    local pkg="$1"
    require_cmd rpm || return $?
    if rpm -q "$pkg" >/dev/null 2>&1; then
        CHECK_DETAIL="Package '$pkg' is installed."
        return 1
    fi
    return 0
}
fix_pkg_removed() { dnf -y remove "$1"; }

# --- Server Services (2.1.*) --------------------------------------------------
audit_svc_disabled() {
    local pkg="$1"; shift
    local units=("$@")
    require_cmd rpm systemctl || return $?
    if rpm -q "$pkg" >/dev/null 2>&1; then
        local u
        for u in "${units[@]}"; do
            if systemctl is-enabled "$u" 2>/dev/null | grep -qE '^(enabled|indirect)' || systemctl is-active "$u" 2>/dev/null | grep -q '^active'; then
                CHECK_DETAIL="Package '$pkg' is installed and unit '$u' is enabled or active."
                return 1
            fi
        done
    fi
    return 0
}

fix_svc_disabled() {
    local pkg="$1"; shift
    local units=("$@")
    local u
    for u in "${units[@]}"; do
        systemctl stop "$u" 2>/dev/null || true
    done
    if rpm -q "$pkg" >/dev/null 2>&1; then
        if ! dnf -y remove "$pkg" 2>/dev/null; then
            for u in "${units[@]}"; do
                systemctl mask "$u" 2>/dev/null || true
            done
        fi
    fi
}

# --- Sysctl (1.5.*, 3.3.*) ----------------------------------------------------
audit_sysctl() {
    local key="$1" expected="$2"
    require_cmd sysctl || return $?
    local cur
    cur="$(sysctl -n "$key" 2>/dev/null || true)"
    if [[ "$cur" != "$expected" ]]; then
        CHECK_DETAIL="sysctl $key is '$cur' (expected '$expected')."
        return 1
    fi
    if ! grep -Prqs "^\h*${key//./\\.}\h*=\h*${expected}\b" /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null; then
        CHECK_DETAIL="sysctl $key=$expected is not persisted in sysctl configuration."
        return 1
    fi
    return 0
}

fix_sysctl() {
    local key="$1" val="$2"
    local conf="/etc/sysctl.d/60-cis.conf"
    touch "$conf"
    sed -ri "/^\s*${key//./\\.}\s*=/d" "$conf"
    printf '%s = %s\n' "$key" "$val" >> "$conf"
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
    # Flush route cache for IPv4/IPv6 network parameters
    [[ "$key" == net.ipv4.* ]] && sysctl -w net.ipv4.route.flush=1 >/dev/null 2>&1 || true
    [[ "$key" == net.ipv6.* ]] && sysctl -w net.ipv6.route.flush=1 >/dev/null 2>&1 || true
}

# --- File Access (permissions & ownership) ------------------------------------
# audit_file_access <path> <allowed_mode_regex> <owner> <group_regex> [allow_missing:0|1]
audit_file_access() {
    local path="$1" mode_re="$2" owner="$3" group_re="$4" allow_missing="${5:-0}"
    if [[ ! -e "$path" ]]; then
        [[ "$allow_missing" -eq 1 ]] && return 0
        CHECK_DETAIL="File $path does not exist."
        return 1
    fi
    local real_p mode u g
    real_p="$(readlink -e "$path" 2>/dev/null || echo "$path")"
    read -r mode u g <<< "$(stat -Lc '%#a %U %G' "$real_p" 2>/dev/null)"
    if [[ ! "$mode" =~ ^${mode_re}$ ]] || [[ "$u" != "$owner" ]] || [[ ! "$g" =~ ^${group_re}$ ]]; then
        CHECK_DETAIL="$path has mode=$mode owner=$u group=$g."
        return 1
    fi
    return 0
}

fix_file_access() {
    local path="$1" mode="$2" owner="$3" group="$4"
    local real_p
    [[ ! -e "$path" ]] && touch "$path"
    real_p="$(readlink -e "$path" 2>/dev/null || echo "$path")"
    chown "${owner}:${group}" "$real_p"
    chmod "$mode" "$real_p"
}

# --- SSHD Parameter Helpers (5.1.*) -------------------------------------------
audit_sshd_param() {
    local param="$1" regex="$2" invert="${3:-0}"
    require_cmd sshd || return $?
    require_root || return $?
    local out
    out="$(sshd -T 2>/dev/null | grep -Pi "^\h*${param}\b" || true)"
    if [[ "$invert" -eq 1 ]]; then
        if grep -Pqi "$regex" <<< "$out"; then
            CHECK_DETAIL="sshd -T returned disallowed value: $out"
            return 1
        fi
    else
        if ! grep -Pqi "$regex" <<< "$out"; then
            CHECK_DETAIL="sshd -T '$param' did not match expected ($out)."
            return 1
        fi
    fi
    return 0
}

fix_sshd_param() {
    local param="$1" value="$2"
    local conf="/etc/ssh/sshd_config.d/60-cis.conf"
    mkdir -p /etc/ssh/sshd_config.d
    touch "$conf"
    sed -ri "/^\s*${param}\s+/Id" "$conf" /etc/ssh/sshd_config 2>/dev/null || true
    printf '%s %s\n' "$param" "$value" >> "$conf"
    chmod 600 "$conf"
    systemctl reload-or-restart sshd 2>/dev/null || true
}

# --- Auditd Config & Rules Helpers (6.3.*) ------------------------------------
audit_auditd_conf() {
    local key="$1" val_re="$2"
    [[ -f /etc/audit/auditd.conf ]] || { CHECK_DETAIL="/etc/audit/auditd.conf missing."; return 1; }
    if ! grep -Pqi "^\h*${key}\h*=\h*${val_re}\b" /etc/audit/auditd.conf; then
        CHECK_DETAIL="auditd.conf '$key' does not match '$val_re'."
        return 1
    fi
    return 0
}

fix_auditd_conf() {
    local key="$1" val="$2"
    sed -ri "/^\s*${key}\s*=/Id" /etc/audit/auditd.conf
    printf '%s = %s\n' "$key" "$val" >> /etc/audit/auditd.conf
    systemctl restart auditd 2>/dev/null || service auditd restart 2>/dev/null || true
}

audit_auditd_rule() {
    local pat="$1"
    require_readable /etc/audit/rules.d || return $?
    if ! grep -Prqs "$pat" /etc/audit/rules.d/*.rules 2>/dev/null; then
        CHECK_DETAIL="Audit rule matching '$pat' not found in /etc/audit/rules.d/."
        return 1
    fi
    if [[ "$EUID" -eq 0 ]] && command -v auditctl >/dev/null 2>&1; then
        if ! auditctl -l 2>/dev/null | grep -Pqs "$pat"; then
            CHECK_DETAIL="Audit rule matching '$pat' not loaded in active auditctl -l."
            return 1
        fi
    fi
    return 0
}

fix_auditd_rule() {
    local rfile="$1"; shift
    mkdir -p /etc/audit/rules.d
    local line
    for line in "$@"; do
        grep -Fxq "$line" "$rfile" 2>/dev/null || printf '%s\n' "$line" >> "$rfile"
    done
    augenrules --load >/dev/null 2>&1 || true
}

# --- pwquality / faillock / login.defs Helpers --------------------------------
audit_kv_file() {
    local file="$1" dir="$2" key="$3" op="$4" target="$5"
    local val=""
    val="$(grep -Phi "^\h*${key}\h*=" "$file" "$dir"/*.conf 2>/dev/null | tail -n1 | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}')"
    if [[ -z "$val" ]]; then
        CHECK_DETAIL="$key is not set in $file or $dir/."
        return 1
    fi
    case "$op" in
        ge) [[ "$val" -ge "$target" ]] 2>/dev/null || { CHECK_DETAIL="$key=$val (expected >= $target)"; return 1; } ;;
        le) [[ "$val" -gt 0 && "$val" -le "$target" ]] 2>/dev/null || { CHECK_DETAIL="$key=$val (expected 1..$target)"; return 1; } ;;
        eq) [[ "$val" == "$target" ]] || { CHECK_DETAIL="$key=$val (expected $target)"; return 1; } ;;
    esac
    return 0
}

fix_kv_confd() {
    local dir="$1" file="$2" key="$3" val="$4"
    mkdir -p "$dir"
    sed -ri "/^\s*${key}\s*=/Id" "${dir}"/*.conf 2>/dev/null || true
    printf '%s = %s\n' "$key" "$val" >> "${dir}/${file}"
}

print_summary() {
    echo ""
    echo "==============================================================================="
    echo " CIS Oracle Linux 10 Benchmark v1.0.0 - Summary"
    echo "==============================================================================="
    printf " Total Checks Evaluated : %d\n" "$CNT_TOTAL"
    printf " Passed                 : %d\n" "$CNT_PASS"
    printf " Failed                 : %d\n" "$CNT_FAIL"
    printf " Remediated & Verified  : %d\n" "$CNT_FIXED"
    printf " Remediation Incomplete : %d\n" "$CNT_FIX_FAIL"
    printf " Manual Review Needed   : %d\n" "$CNT_MANUAL"
    printf " Not Applicable / Unavail: %d\n" "$CNT_NA"
    printf " Skipped                : %d\n" "$CNT_SKIPPED"
    printf " Log File               : %s\n" "$LOG_FILE"
    echo "==============================================================================="
}

#===============================================================================
# SECTION 1: Initial Setup
#===============================================================================
run_section_1() {
    echo -e "\n${C_BOLD}=== Section 1: Initial Setup ===${C_RESET}"

    # 1.1.1 Filesystem Kernel Modules
    run_check "1.1.1.1"  "L1S,L1W" "AUTO" "Ensure cramfs kernel module is not available"        "audit_kmod cramfs fs"        "fix_kmod cramfs"        "blacklisting and disabling cramfs module"
    run_check "1.1.1.2"  "L1S,L1W" "AUTO" "Ensure freevxfs kernel module is not available"      "audit_kmod freevxfs fs"      "fix_kmod freevxfs"      "blacklisting and disabling freevxfs module"
    run_check "1.1.1.3"  "L1S,L1W" "AUTO" "Ensure hfs kernel module is not available"           "audit_kmod hfs fs"           "fix_kmod hfs"           "blacklisting and disabling hfs module"
    run_check "1.1.1.4"  "L1S,L1W" "AUTO" "Ensure hfsplus kernel module is not available"       "audit_kmod hfsplus fs"       "fix_kmod hfsplus"       "blacklisting and disabling hfsplus module"
    run_check "1.1.1.5"  "L1S,L1W" "AUTO" "Ensure jffs2 kernel module is not available"         "audit_kmod jffs2 fs"         "fix_kmod jffs2"         "blacklisting and disabling jffs2 module"
    run_check "1.1.1.6"  "L2S,L2W" "AUTO" "Ensure overlay kernel module is not available"       "audit_kmod overlay fs"       "fix_kmod overlay"       "blacklisting and disabling overlay module"
    run_check "1.1.1.7"  "L2S,L2W" "AUTO" "Ensure squashfs kernel module is not available"      "audit_kmod squashfs fs"      "fix_kmod squashfs"      "blacklisting and disabling squashfs module"
    run_check "1.1.1.8"  "L2S,L2W" "AUTO" "Ensure udf kernel module is not available"           "audit_kmod udf fs"           "fix_kmod udf"           "blacklisting and disabling udf module"
    run_check "1.1.1.9"  "L1S,L2W" "AUTO" "Ensure firewire-core kernel module is not available" "audit_kmod firewire-core drivers/firewire" "fix_kmod firewire-core" "blacklisting and disabling firewire-core module"
    run_check "1.1.1.10" "L1S,L2W" "AUTO" "Ensure usb-storage kernel module is not available"   "audit_kmod usb-storage drivers/usb/storage" "fix_kmod usb-storage" "blacklisting and disabling usb-storage module"
    run_check "1.1.1.11" "L1S,L1W" "MANUAL" "Ensure unused filesystems kernel modules are not available" "manual_only" "manual_only" "Review loaded/available filesystem modules (lsmod / /usr/lib/modules/*/kernel/fs) and disable unused ones in /etc/modprobe.d/"

    # 1.1.2 Filesystem Partitions
    run_check "1.1.2.1.1" "L1S,L1W" "AUTO" "Ensure /tmp is tmpfs or a separate partition" "audit_mount_exists /tmp" "fix_1_1_2_1_1" "enabling systemd tmp.mount for /tmp"
    run_check "1.1.2.1.2" "L1S,L1W" "AUTO" "Ensure nodev option set on /tmp partition" "audit_mount_opt /tmp nodev" "fix_mount_opt /tmp nodev" "adding nodev to /tmp mount options"
    run_check "1.1.2.1.3" "L1S,L1W" "AUTO" "Ensure nosuid option set on /tmp partition" "audit_mount_opt /tmp nosuid" "fix_mount_opt /tmp nosuid" "adding nosuid to /tmp mount options"
    run_check "1.1.2.1.4" "L1S,L1W" "AUTO" "Ensure noexec option set on /tmp partition" "audit_mount_opt /tmp noexec" "fix_mount_opt /tmp noexec" "adding noexec to /tmp mount options"

    run_check "1.1.2.2.1" "L1S,L1W" "AUTO" "Ensure /dev/shm is tmpfs or a separate partition" "audit_mount_exists /dev/shm" "fix_mount_opt /dev/shm nodev" "configuring /dev/shm in /etc/fstab"
    run_check "1.1.2.2.2" "L1S,L1W" "AUTO" "Ensure nodev option set on /dev/shm partition" "audit_mount_opt /dev/shm nodev" "fix_mount_opt /dev/shm nodev" "adding nodev to /dev/shm mount options"
    run_check "1.1.2.2.3" "L1S,L1W" "AUTO" "Ensure nosuid option set on /dev/shm partition" "audit_mount_opt /dev/shm nosuid" "fix_mount_opt /dev/shm nosuid" "adding nosuid to /dev/shm mount options"
    run_check "1.1.2.2.4" "L1S,L1W" "AUTO" "Ensure noexec option set on /dev/shm partition" "audit_mount_opt /dev/shm noexec" "fix_mount_opt /dev/shm noexec" "adding noexec to /dev/shm mount options"

    run_check "1.1.2.3.1" "L2S,L2W" "AUTO" "Ensure separate partition exists for /home" "audit_mount_exists /home" "manual_only" "Partitioning /home requires disk/LVM changes; create a separate partition for /home"
    run_check "1.1.2.3.2" "L1S,L1W" "AUTO" "Ensure nodev option set on /home partition" "audit_mount_opt /home nodev" "fix_mount_opt /home nodev" "adding nodev to /home mount options"
    run_check "1.1.2.3.3" "L1S,L1W" "AUTO" "Ensure nosuid option set on /home partition" "audit_mount_opt /home nosuid" "fix_mount_opt /home nosuid" "adding nosuid to /home mount options"

    run_check "1.1.2.4.1" "L2S,L2W" "AUTO" "Ensure separate partition exists for /var" "audit_mount_exists /var" "manual_only" "Partitioning /var requires disk/LVM changes"
    run_check "1.1.2.4.2" "L1S,L1W" "AUTO" "Ensure nodev option set on /var partition" "audit_mount_opt /var nodev" "fix_mount_opt /var nodev" "adding nodev to /var mount options"
    run_check "1.1.2.4.3" "L1S,L1W" "AUTO" "Ensure nosuid option set on /var partition" "audit_mount_opt /var nosuid" "fix_mount_opt /var nosuid" "adding nosuid to /var mount options"

    run_check "1.1.2.5.1" "L2S,L2W" "AUTO" "Ensure separate partition exists for /var/tmp" "audit_mount_exists /var/tmp" "manual_only" "Partitioning /var/tmp requires disk/LVM changes"
    run_check "1.1.2.5.2" "L1S,L1W" "AUTO" "Ensure nodev option set on /var/tmp partition" "audit_mount_opt /var/tmp nodev" "fix_mount_opt /var/tmp nodev" "adding nodev to /var/tmp mount options"
    run_check "1.1.2.5.3" "L1S,L1W" "AUTO" "Ensure nosuid option set on /var/tmp partition" "audit_mount_opt /var/tmp nosuid" "fix_mount_opt /var/tmp nosuid" "adding nosuid to /var/tmp mount options"
    run_check "1.1.2.5.4" "L1S,L1W" "AUTO" "Ensure noexec option set on /var/tmp partition" "audit_mount_opt /var/tmp noexec" "fix_mount_opt /var/tmp noexec" "adding noexec to /var/tmp mount options"

    run_check "1.1.2.6.1" "L2S,L2W" "AUTO" "Ensure separate partition exists for /var/log" "audit_mount_exists /var/log" "manual_only" "Partitioning /var/log requires disk/LVM changes"
    run_check "1.1.2.6.2" "L1S,L1W" "AUTO" "Ensure nodev option set on /var/log partition" "audit_mount_opt /var/log nodev" "fix_mount_opt /var/log nodev" "adding nodev to /var/log mount options"
    run_check "1.1.2.6.3" "L1S,L1W" "AUTO" "Ensure nosuid option set on /var/log partition" "audit_mount_opt /var/log nosuid" "fix_mount_opt /var/log nosuid" "adding nosuid to /var/log mount options"
    run_check "1.1.2.6.4" "L1S,L1W" "AUTO" "Ensure noexec option set on /var/log partition" "audit_mount_opt /var/log noexec" "fix_mount_opt /var/log noexec" "adding noexec to /var/log mount options"

    run_check "1.1.2.7.1" "L2S,L2W" "AUTO" "Ensure separate partition exists for /var/log/audit" "audit_mount_exists /var/log/audit" "manual_only" "Partitioning /var/log/audit requires disk/LVM changes"
    run_check "1.1.2.7.2" "L1S,L1W" "AUTO" "Ensure nodev option set on /var/log/audit partition" "audit_mount_opt /var/log/audit nodev" "fix_mount_opt /var/log/audit nodev" "adding nodev to /var/log/audit mount options"
    run_check "1.1.2.7.3" "L1S,L1W" "AUTO" "Ensure nosuid option set on /var/log/audit partition" "audit_mount_opt /var/log/audit nosuid" "fix_mount_opt /var/log/audit nosuid" "adding nosuid to /var/log/audit mount options"
    run_check "1.1.2.7.4" "L1S,L1W" "AUTO" "Ensure noexec option set on /var/log/audit partition" "audit_mount_opt /var/log/audit noexec" "fix_mount_opt /var/log/audit noexec" "adding noexec to /var/log/audit mount options"

    # 1.2 Package Management
    run_check "1.2.1.1" "L1S,L1W" "MANUAL" "Ensure GPG keys are configured" "manual_only" "manual_only" "Verify GPG keys via 'rpm -q gpg-pubkey' and /etc/yum.repos.d/*.repo"
    run_check "1.2.1.2" "L1S,L1W" "AUTO"   "Ensure gpgcheck is configured" "audit_1_2_1_2" "fix_1_2_1_2" "setting gpgcheck=1 in /etc/dnf/dnf.conf and /etc/yum.repos.d/*.repo"
    run_check "1.2.1.3" "L2S,L2W" "MANUAL" "Ensure repo_gpgcheck is globally activated" "audit_1_2_1_3" "fix_1_2_1_3" "setting repo_gpgcheck=1 in /etc/dnf/dnf.conf"
    run_check "1.2.1.4" "L1S,L1W" "MANUAL" "Ensure package manager repositories are configured" "manual_only" "manual_only" "Verify 'dnf repolist' matches site policy"
    run_check "1.2.1.5" "L2S,L2W" "AUTO"   "Ensure weak dependencies are configured" "audit_1_2_1_5" "fix_1_2_1_5" "setting install_weak_deps=0 in /etc/dnf/dnf.conf"
    run_check "1.2.2.1" "L1S,L1W" "MANUAL" "Ensure updates, patches, and additional security software are installed" "audit_1_2_2_1" "fix_1_2_2_1" "running dnf update"

    # 1.3 SELinux
    run_check "1.3.1.1" "L1S,L1W" "AUTO"   "Ensure SELinux is installed" "audit_pkg_installed libselinux" "fix_pkg_installed libselinux" "installing libselinux"
    run_check "1.3.1.2" "L1S,L1W" "AUTO"   "Ensure SELinux is not disabled in bootloader configuration" "audit_1_3_1_2" "fix_1_3_1_2" "removing selinux=0 and enforcing=0 from GRUB kernel args"
    run_check "1.3.1.3" "L1S,L1W" "AUTO"   "Ensure SELinux policy is configured" "audit_1_3_1_3" "fix_1_3_1_3" "setting SELINUXTYPE=targeted in /etc/selinux/config"
    run_check "1.3.1.4" "L1S,L1W" "AUTO"   "Ensure the SELinux mode is not disabled" "audit_1_3_1_4" "fix_1_3_1_4" "setting SELINUX=enforcing in /etc/selinux/config"
    run_check "1.3.1.5" "L2S,L2W" "AUTO"   "Ensure the SELinux mode is enforcing" "audit_1_3_1_5" "fix_1_3_1_5" "setting SELINUX=enforcing and running setenforce 1"
    run_check "1.3.1.6" "L2S,L2W" "MANUAL" "Ensure no unconfined services exist" "audit_1_3_1_6" "manual_only" "Investigate processes in 'ps -eZ | grep unconfined_service_t'"
    run_check "1.3.1.7" "L1S,L1W" "AUTO"   "Ensure the MCS Translation Service (mcstrans) is not installed" "audit_pkg_removed mcstrans" "fix_pkg_removed mcstrans" "removing mcstrans"
    run_check "1.3.1.8" "L1S"     "AUTO"   "Ensure SETroubleshoot is not installed" "audit_pkg_removed setroubleshoot" "fix_pkg_removed setroubleshoot" "removing setroubleshoot"

    # 1.4 Bootloader
    run_check "1.4.1" "L1S,L1W" "AUTO" "Ensure bootloader password is set" "audit_1_4_1" "fix_1_4_1" "running grub2-setpassword" 1
    run_check "1.4.2" "L1S,L1W" "AUTO" "Ensure access to bootloader config is configured" "audit_1_4_2" "fix_1_4_2" "setting root:root and 0600 permissions on /boot/grub2 files"

    # 1.5 Additional Process Hardening
    run_check "1.5.1"  "L1S,L1W" "AUTO" "Ensure core file size is configured" "audit_1_5_1" "fix_1_5_1" "setting '* hard core 0' in /etc/security/limits.d/60-cis.conf"
    run_check "1.5.2"  "L1S,L1W" "AUTO" "Ensure fs.protected_hardlinks is configured" "audit_sysctl fs.protected_hardlinks 1" "fix_sysctl fs.protected_hardlinks 1" "setting fs.protected_hardlinks = 1"
    run_check "1.5.3"  "L2S,L2W" "AUTO" "Ensure fs.protected_symlinks is configured" "audit_sysctl fs.protected_symlinks 1" "fix_sysctl fs.protected_symlinks 1" "setting fs.protected_symlinks = 1"
    run_check "1.5.4"  "L1S,L1W" "AUTO" "Ensure fs.suid_dumpable is configured" "audit_sysctl fs.suid_dumpable 0" "fix_sysctl fs.suid_dumpable 0" "setting fs.suid_dumpable = 0"
    run_check "1.5.5"  "L1S,L1W" "AUTO" "Ensure kernel.dmesg_restrict is configured" "audit_sysctl kernel.dmesg_restrict 1" "fix_sysctl kernel.dmesg_restrict 1" "setting kernel.dmesg_restrict = 1"
    run_check "1.5.6"  "L1S,L1W" "AUTO" "Ensure kernel.kptr_restrict is configured" "audit_sysctl kernel.kptr_restrict 1" "fix_sysctl kernel.kptr_restrict 1" "setting kernel.kptr_restrict = 1"
    run_check "1.5.7"  "L1S,L1W" "AUTO" "Ensure kernel.yama.ptrace_scope is configured" "audit_sysctl kernel.yama.ptrace_scope 1" "fix_sysctl kernel.yama.ptrace_scope 1" "setting kernel.yama.ptrace_scope = 1"
    run_check "1.5.8"  "L1S,L1W" "AUTO" "Ensure kernel.randomize_va_space is configured" "audit_sysctl kernel.randomize_va_space 2" "fix_sysctl kernel.randomize_va_space 2" "setting kernel.randomize_va_space = 2"
    run_check "1.5.9"  "L1S,L1W" "AUTO" "Ensure systemd-coredump ProcessSizeMax is configured" "audit_1_5_9" "fix_1_5_9" "setting ProcessSizeMax=0 in /etc/systemd/coredump.conf.d/60-coredump.conf"
    run_check "1.5.10" "L1S,L1W" "AUTO" "Ensure systemd-coredump Storage is configured" "audit_1_5_10" "fix_1_5_10" "setting Storage=none in /etc/systemd/coredump.conf.d/60-coredump.conf"

    # 1.6 Crypto Policies
    run_check "1.6.1" "L1S,L1W" "AUTO" "Ensure system wide crypto policy is not set to legacy" "audit_1_6_1" "fix_1_6_1" "setting system crypto policy to DEFAULT"
    run_check "1.6.2" "L1S,L1W" "AUTO" "Ensure system wide crypto policy disables sha1 hash and signature support" "audit_1_6_2" "fix_1_6_2" "enabling NO-SHA1 crypto subpolicy"
    run_check "1.6.3" "L1S,L1W" "AUTO" "Ensure system wide crypto policy macs are configured" "audit_1_6_3" "fix_1_6_3" "enabling NO-WEAKMAC crypto subpolicy"
    run_check "1.6.4" "L1S,L1W" "AUTO" "Ensure system wide crypto policy disables cbc for ssh" "audit_1_6_4" "fix_1_6_4" "enabling NO-SSHCBC crypto subpolicy"

    # 1.7 Warning Banners
    run_check "1.7.1" "L1S,L1W" "AUTO" "Ensure /etc/motd is configured" "audit_banner /etc/motd" "fix_banner /etc/motd" "updating /etc/motd without OS info escapes" 1
    run_check "1.7.2" "L1S,L1W" "AUTO" "Ensure /etc/issue is configured" "audit_banner /etc/issue" "fix_banner /etc/issue" "updating /etc/issue without OS info escapes" 1
    run_check "1.7.3" "L1S,L1W" "AUTO" "Ensure /etc/issue.net is configured" "audit_banner /etc/issue.net" "fix_banner /etc/issue.net" "updating /etc/issue.net without OS info escapes" 1
    run_check "1.7.4" "L1S,L1W" "AUTO" "Ensure access to /etc/motd is configured" "audit_file_access /etc/motd 0644 root root 1" "fix_file_access /etc/motd 0644 root root" "setting 0644 root:root on /etc/motd"
    run_check "1.7.5" "L1S,L1W" "AUTO" "Ensure access to /etc/issue is configured" "audit_file_access /etc/issue 0644 root root" "fix_file_access /etc/issue 0644 root root" "setting 0644 root:root on /etc/issue"
    run_check "1.7.6" "L1S,L1W" "AUTO" "Ensure access to /etc/issue.net is configured" "audit_file_access /etc/issue.net 0644 root root" "fix_file_access /etc/issue.net 0644 root root" "setting 0644 root:root on /etc/issue.net"

    # 1.8 GDM
    run_check "1.8.1" "L1S,L1W" "AUTO" "Ensure GDM login banner is configured" "audit_gdm_setting banner-message-enable true" "fix_gdm_banner" "configuring GDM login banner via dconf" 1
    run_check "1.8.2" "L1S,L1W" "AUTO" "Ensure GDM disable-user-list is configured" "audit_gdm_setting disable-user-list true" "fix_gdm_disable_user_list" "disabling GDM user list via dconf"
    run_check "1.8.3" "L1S,L1W" "AUTO" "Ensure GDM screen lock is configured" "audit_gdm_idle" "fix_gdm_idle" "configuring GDM screen lock idle-delay and lock-delay"
    run_check "1.8.4" "L1S,L1W" "AUTO" "Ensure GDM automount is configured" "audit_gdm_media automount false" "fix_gdm_automount" "disabling GDM automount via dconf"
    run_check "1.8.5" "L1S,L1W" "AUTO" "Ensure GDM autorun-never is configured" "audit_gdm_media autorun-never true" "fix_gdm_autorun" "enabling GDM autorun-never via dconf"
    run_check "1.8.6" "L1S,L1W" "AUTO" "Ensure Xwayland is configured" "audit_1_8_6" "fix_1_8_6" "setting WaylandEnable=false in /etc/gdm/custom.conf"
}

# --- Section 1 Implementations ------------------------------------------------
fix_1_1_2_1_1() {
    systemctl unmask tmp.mount 2>/dev/null || true
    systemctl enable --now tmp.mount 2>/dev/null || true
}
audit_1_2_1_2() {
    grep -Pqi '^\h*gpgcheck\h*=\h*(1|true|yes)\b' /etc/dnf/dnf.conf 2>/dev/null || { CHECK_DETAIL="gpgcheck=1 not set in /etc/dnf/dnf.conf"; return 1; }
    local f
    for f in /etc/yum.repos.d/*.repo; do
        if grep -Pqi '^\h*gpgcheck\h*=\h*(0|false|no)\b' "$f"; then
            CHECK_DETAIL="gpgcheck disabled in $f"; return 1
        fi
    done
    return 0
}
fix_1_2_1_2() {
    if grep -Pqi '^\h*gpgcheck\h*=' /etc/dnf/dnf.conf; then
        sed -ri 's/^\s*gpgcheck\s*=.*/gpgcheck=1/I' /etc/dnf/dnf.conf
    else
        printf '\ngpgcheck=1\n' >> /etc/dnf/dnf.conf
    fi
    find /etc/yum.repos.d/ -name '*.repo' -exec sed -ri 's/^\s*gpgcheck\s*=.*/gpgcheck=1/I' {} +
}
audit_1_2_1_3() {
    grep -Pqi '^\h*repo_gpgcheck\h*=\h*(1|true|yes)\b' /etc/dnf/dnf.conf 2>/dev/null || { CHECK_DETAIL="repo_gpgcheck=1 not set in /etc/dnf/dnf.conf"; return 1; }
}
fix_1_2_1_3() {
    if grep -Pqi '^\h*repo_gpgcheck\h*=' /etc/dnf/dnf.conf; then
        sed -ri 's/^\s*repo_gpgcheck\s*=.*/repo_gpgcheck=1/I' /etc/dnf/dnf.conf
    else
        printf '\nrepo_gpgcheck=1\n' >> /etc/dnf/dnf.conf
    fi
}
audit_1_2_1_5() {
    grep -Pqi '^\h*install_weak_deps\h*=\h*(0|false|no)\b' /etc/dnf/dnf.conf 2>/dev/null || { CHECK_DETAIL="install_weak_deps=0 not set in /etc/dnf/dnf.conf"; return 1; }
}
fix_1_2_1_5() {
    if grep -Pqi '^\h*install_weak_deps\h*=' /etc/dnf/dnf.conf; then
        sed -ri 's/^\s*install_weak_deps\s*=.*/install_weak_deps=0/I' /etc/dnf/dnf.conf
    else
        printf '\ninstall_weak_deps=0\n' >> /etc/dnf/dnf.conf
    fi
}
audit_1_2_2_1() {
    dnf check-update -q >/dev/null 2>&1
    local rc=$?
    [[ "$rc" -eq 100 ]] && { CHECK_DETAIL="Pending package updates available (dnf check-update)."; return 1; }
    return 0
}
fix_1_2_2_1() { dnf -y update; }

audit_1_3_1_2() {
    require_cmd grubby || return $?
    if grubby --info=ALL 2>/dev/null | grep -Pq '(selinux|enforcing)=0\b' || \
       grep -Prsq '^\h*([^#\n\r]+\h+)?kernelopts=([^#\n\r]+\h+)?(selinux|enforcing)=0\b' /boot/grub2 /boot/efi 2>/dev/null; then
        CHECK_DETAIL="SELinux disabled in bootloader kernel arguments."
        return 1
    fi
    return 0
}
fix_1_3_1_2() { grubby --update-kernel ALL --remove-args "selinux=0 enforcing=0" 2>/dev/null || true; }
audit_1_3_1_3() {
    grep -Psiq '^\h*SELINUXTYPE\h*=\h*(targeted|mls)\b' /etc/selinux/config 2>/dev/null || { CHECK_DETAIL="SELINUXTYPE not targeted/mls in /etc/selinux/config"; return 1; }
}
fix_1_3_1_3() {
    if grep -Pqi '^\h*SELINUXTYPE\h*=' /etc/selinux/config; then
        sed -ri 's/^\s*SELINUXTYPE\s*=.*/SELINUXTYPE=targeted/' /etc/selinux/config
    else
        printf '\nSELINUXTYPE=targeted\n' >> /etc/selinux/config
    fi
}
audit_1_3_1_4() {
    grep -Piq '^\h*SELINUX=(enforcing|permissive)\b' /etc/selinux/config 2>/dev/null || { CHECK_DETAIL="SELINUX is disabled in /etc/selinux/config"; return 1; }
}
fix_1_3_1_4() {
    sed -ri 's/^\s*SELINUX\s*=.*/SELINUX=enforcing/' /etc/selinux/config
    touch /.autorelabel
}
audit_1_3_1_5() {
    grep -Piq '^\h*SELINUX=enforcing\b' /etc/selinux/config 2>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || { CHECK_DETAIL="SELinux is not in Enforcing mode."; return 1; }
}
fix_1_3_1_5() {
    sed -ri 's/^\s*SELINUX\s*=.*/SELINUX=enforcing/' /etc/selinux/config
    setenforce 1 2>/dev/null || touch /.autorelabel
}
audit_1_3_1_6() {
    local u
    u="$(ps -eZ 2>/dev/null | grep unconfined_service_t || true)"
    [[ -n "$u" ]] && { CHECK_DETAIL="Found unconfined services: $(echo "$u" | wc -l) process(es)"; return 1; }
    return 0
}

audit_1_4_1() {
    require_root || return $?
    local f
    f="$(find /boot -type f -name 'user.cfg' ! -empty 2>/dev/null | head -n1)"
    if [[ -z "$f" ]] || ! grep -Pq '^\h*GRUB2_PASSWORD=\S+' "$f"; then
        CHECK_DETAIL="GRUB2 bootloader password is not set."
        return 1
    fi
    return 0
}
fix_1_4_1() {
    echo "  Running grub2-setpassword (you will be prompted for the GRUB password):"
    grub2-setpassword
}
audit_1_4_2() {
    require_root || return $?
    local bad
    bad="$(find -L /boot/grub2/ -mindepth 1 -maxdepth 1 -type f \( ! -user root -o ! -group root -o -perm /0177 \) 2>/dev/null)"
    [[ -n "$bad" ]] && { CHECK_DETAIL="Insecure permissions/ownership in /boot/grub2/"; return 1; }
    return 0
}
fix_1_4_2() {
    find -L /boot/grub2/ -mindepth 1 -maxdepth 1 -type f -exec chown root:root {} + -exec chmod u-x,go-rwx {} +
}

audit_1_5_1() {
    grep -Prqs '^\h*\*\h+hard\h+core\h+0\b' /etc/security/limits.conf /etc/security/limits.d/*.conf 2>/dev/null || { CHECK_DETAIL="hard core limit 0 not configured"; return 1; }
}
fix_1_5_1() {
    mkdir -p /etc/security/limits.d
    printf '* hard core 0\n' > /etc/security/limits.d/60-cis-core.conf
}
audit_1_5_9() {
    require_cmd systemd-analyze || return $?
    systemd-analyze cat-config systemd/coredump.conf 2>/dev/null | grep -Pqi '^\h*ProcessSizeMax\h*=\h*0\b' || { CHECK_DETAIL="ProcessSizeMax=0 not set in coredump.conf"; return 1; }
}
fix_1_5_9() {
    mkdir -p /etc/systemd/coredump.conf.d
    grep -qs '^\[Coredump\]' /etc/systemd/coredump.conf.d/60-coredump.conf || printf '[Coredump]\n' > /etc/systemd/coredump.conf.d/60-coredump.conf
    sed -ri '/^\s*ProcessSizeMax\s*=/Id' /etc/systemd/coredump.conf.d/60-coredump.conf
    printf 'ProcessSizeMax=0\n' >> /etc/systemd/coredump.conf.d/60-coredump.conf
}
audit_1_5_10() {
    require_cmd systemd-analyze || return $?
    systemd-analyze cat-config systemd/coredump.conf 2>/dev/null | grep -Pqi '^\h*Storage\h*=\h*none\b' || { CHECK_DETAIL="Storage=none not set in coredump.conf"; return 1; }
}
fix_1_5_10() {
    mkdir -p /etc/systemd/coredump.conf.d
    grep -qs '^\[Coredump\]' /etc/systemd/coredump.conf.d/60-coredump.conf || printf '[Coredump]\n' > /etc/systemd/coredump.conf.d/60-coredump.conf
    sed -ri '/^\s*Storage\s*=/Id' /etc/systemd/coredump.conf.d/60-coredump.conf
    printf 'Storage=none\n' >> /etc/systemd/coredump.conf.d/60-coredump.conf
}

audit_1_6_1() {
    require_readable /etc/crypto-policies/config || return $?
    grep -Pqi '^\h*LEGACY\b' /etc/crypto-policies/config 2>/dev/null && { CHECK_DETAIL="Crypto policy is set to LEGACY."; return 1; }
    return 0
}
fix_1_6_1() { update-crypto-policies --set DEFAULT; }

apply_crypto_subpolicy() {
    local sub="$1"
    local cur
    cur="$(cat /etc/crypto-policies/config 2>/dev/null || echo DEFAULT)"
    if [[ "$cur" != *":$sub"* ]]; then
        update-crypto-policies --set "${cur}:${sub}"
    else
        update-crypto-policies
    fi
}
audit_1_6_2() {
    require_readable /etc/crypto-policies/state/CURRENT.pol || return $?
    if awk -F= '($1~/^\s*(hash|sign)\s*$/ && $2~/SHA1/ && $2!~/^\s*-\s*([^#\n\r]+)?SHA1/){exit 1}' /etc/crypto-policies/state/CURRENT.pol 2>/dev/null && \
       grep -Psiq '^\h*sha1_in_certs\h*=\h*0\b' /etc/crypto-policies/state/CURRENT.pol 2>/dev/null; then
        return 0
    fi
    CHECK_DETAIL="SHA1 not disabled in current crypto policy."; return 1
}
fix_1_6_2() {
    mkdir -p /etc/crypto-policies/policies/modules
    printf '# Disable SHA1\nhash = -SHA1\nsign = -*-SHA1\nsha1_in_certs = 0\n' > /etc/crypto-policies/policies/modules/NO-SHA1.pmod
    apply_crypto_subpolicy "NO-SHA1"
}
audit_1_6_3() {
    require_readable /etc/crypto-policies/state/CURRENT.pol || return $?
    grep -Pqi '^\h*mac\h*=\h*([^#\n\r]+)?-128\b' /etc/crypto-policies/state/CURRENT.pol 2>/dev/null && { CHECK_DETAIL="Weak 128-bit MACs enabled in crypto policy."; return 1; }
    return 0
}
fix_1_6_3() {
    mkdir -p /etc/crypto-policies/policies/modules
    printf '# Disable weak MACs\nmac = -*-128\n' > /etc/crypto-policies/policies/modules/NO-WEAKMAC.pmod
    apply_crypto_subpolicy "NO-WEAKMAC"
}
audit_1_6_4() {
    require_readable /etc/crypto-policies/state/CURRENT.pol || return $?
    grep -Pqi '^\h*cipher(@(lib|open)ssh(-server|-client)?)?\h*=\h*([^#\n\r]+)?-CBC\b' /etc/crypto-policies/state/CURRENT.pol 2>/dev/null && { CHECK_DETAIL="CBC ciphers enabled for SSH in crypto policy."; return 1; }
    return 0
}
fix_1_6_4() {
    mkdir -p /etc/crypto-policies/policies/modules
    printf '# Disable CBC for SSH\ncipher@SSH = -*-CBC\n' > /etc/crypto-policies/policies/modules/NO-SSHCBC.pmod
    apply_crypto_subpolicy "NO-SSHCBC"
}

audit_banner() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local os_id
    os_id="$(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null | tr -d '"')"
    if grep -Pqi "(\\\v|\\\r|\\\m|\\\s|\b${os_id}\b)" "$f" 2>/dev/null; then
        CHECK_DETAIL="$f contains OS/system information escape sequences."
        return 1
    fi
    return 0
}
fix_banner() {
    local f="$1" msg=""
    ask_input "Enter authorized warning banner for $f" "Authorized users only. All activity may be monitored and reported." msg
    printf '%s\n' "$msg" > "$f"
}

audit_gdm_setting() {
    local key="$1" expected="$2"
    rpm -q gdm >/dev/null 2>&1 || return 0
    local w
    w="$(gsettings writable org.gnome.login-screen "$key" 2>/dev/null || echo "false")"
    local v
    v="$(gsettings get org.gnome.login-screen "$key" 2>/dev/null || echo "$expected")"
    [[ "$w" == "false" && "$v" == *"$expected"* ]] || { CHECK_DETAIL="GDM $key=$v writable=$w"; return 1; }
}
fix_gdm_banner() {
    local msg=""
    ask_input "Enter GDM login banner text" "Authorized users only. All activity may be monitored and reported." msg
    mkdir -p /etc/dconf/profile /etc/dconf/db/gdm.d/locks
    printf 'user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults\n' > /etc/dconf/profile/gdm
    printf "[org/gnome/login-screen]\nbanner-message-enable=true\nbanner-message-text='%s'\n" "$msg" > /etc/dconf/db/gdm.d/01-banner-message
    printf '/org/gnome/login-screen/banner-message-enable\n/org/gnome/login-screen/banner-message-text\n' > /etc/dconf/db/gdm.d/locks/01-banner-message
    dconf update
}
fix_gdm_disable_user_list() {
    mkdir -p /etc/dconf/profile /etc/dconf/db/gdm.d/locks
    printf 'user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults\n' > /etc/dconf/profile/gdm
    printf '[org/gnome/login-screen]\ndisable-user-list=true\n' > /etc/dconf/db/gdm.d/00-login-screen
    printf '/org/gnome/login-screen/disable-user-list\n' > /etc/dconf/db/gdm.d/locks/00-login-screen
    dconf update
}
audit_gdm_idle() {
    rpm -q gdm >/dev/null 2>&1 || return 0
    local w
    w="$(gsettings writable org.gnome.desktop.session idle-delay 2>/dev/null || echo "false")"
    [[ "$w" == "false" ]] || { CHECK_DETAIL="GDM idle-delay is writable by users."; return 1; }
}
fix_gdm_idle() {
    mkdir -p /etc/dconf/profile /etc/dconf/db/local.d/locks
    printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    printf '[org/gnome/desktop/session]\nidle-delay=uint32 900\n[org/gnome/desktop/screensaver]\nlock-delay=uint32 5\n' > /etc/dconf/db/local.d/00-screensaver
    printf '/org/gnome/desktop/session/idle-delay\n/org/gnome/desktop/screensaver/lock-delay\n' > /etc/dconf/db/local.d/locks/00-screensaver
    dconf update
}
audit_gdm_media() {
    local key="$1" expected="$2"
    rpm -q gdm >/dev/null 2>&1 || return 0
    local w
    w="$(gsettings writable org.gnome.desktop.media-handling "$key" 2>/dev/null || echo "false")"
    [[ "$w" == "false" ]] || { CHECK_DETAIL="GDM media-handling $key is writable."; return 1; }
}
fix_gdm_automount() {
    mkdir -p /etc/dconf/profile /etc/dconf/db/local.d/locks
    printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    printf '[org/gnome/desktop/media-handling]\nautomount=false\nautomount-open=false\n' > /etc/dconf/db/local.d/00-media-automount
    printf '/org/gnome/desktop/media-handling/automount\n/org/gnome/desktop/media-handling/automount-open\n' > /etc/dconf/db/local.d/locks/00-media-automount
    dconf update
}
fix_gdm_autorun() {
    mkdir -p /etc/dconf/profile /etc/dconf/db/local.d/locks
    printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    printf '[org/gnome/desktop/media-handling]\nautorun-never=true\n' > /etc/dconf/db/local.d/00-media-autorun
    printf '/org/gnome/desktop/media-handling/autorun-never\n' > /etc/dconf/db/local.d/locks/00-media-autorun
    dconf update
}
audit_1_8_6() {
    rpm -q gdm >/dev/null 2>&1 || return 0
    [[ -f /etc/gdm/custom.conf ]] || return 0
    sed -n '/\[daemon\]/,/\[/p' /etc/gdm/custom.conf | grep -Psiq '^\h*WaylandEnable\h*=\h*false\b' || { CHECK_DETAIL="WaylandEnable=false not set in /etc/gdm/custom.conf"; return 1; }
}
fix_1_8_6() {
    [[ -f /etc/gdm/custom.conf ]] || printf '[daemon]\n' > /etc/gdm/custom.conf
    sed -ri '/^\s*WaylandEnable\s*=/Id' /etc/gdm/custom.conf
    sed -i '/^\[daemon\]/a WaylandEnable=false' /etc/gdm/custom.conf
}

#===============================================================================
# SECTION 2: Services
#===============================================================================
run_section_2() {
    echo -e "\n${C_BOLD}=== Section 2: Services ===${C_RESET}"

    # 2.1 Server Services
    run_check "2.1.1"  "L1S,L1W" "AUTO" "Ensure autofs services are not in use" "audit_svc_disabled autofs autofs.service" "fix_svc_disabled autofs autofs.service" "stopping and disabling/removing autofs"
    run_check "2.1.2"  "L1S,L1W" "AUTO" "Ensure avahi daemon services are not in use" "audit_svc_disabled avahi avahi-daemon.socket avahi-daemon.service" "fix_svc_disabled avahi avahi-daemon.socket avahi-daemon.service" "stopping and disabling/removing avahi"
    run_check "2.1.3"  "L1S,L1W" "AUTO" "Ensure cockpit web services are not in use" "audit_svc_disabled cockpit-ws cockpit.socket cockpit.service" "fix_svc_disabled cockpit-ws cockpit.socket cockpit.service" "stopping and disabling/removing cockpit-ws"
    run_check "2.1.4"  "L1S,L1W" "AUTO" "Ensure dhcp server services are not in use" "audit_svc_disabled kea kea-dhcp-ddns.service kea-dhcp4.service kea-dhcp6.service" "fix_svc_disabled kea kea-dhcp-ddns.service kea-dhcp4.service kea-dhcp6.service" "stopping and disabling/removing kea"
    run_check "2.1.5"  "L1S,L1W" "AUTO" "Ensure dns server services are not in use" "audit_svc_disabled bind named.service" "fix_svc_disabled bind named.service" "stopping and disabling/removing bind"
    run_check "2.1.6"  "L1S,L1W" "AUTO" "Ensure dnsmasq services are not in use" "audit_svc_disabled dnsmasq dnsmasq.service" "fix_svc_disabled dnsmasq dnsmasq.service" "stopping and disabling/removing dnsmasq"
    run_check "2.1.7"  "L1S,L1W" "AUTO" "Ensure ftp server services are not in use" "audit_svc_disabled vsftpd vsftpd.service" "fix_svc_disabled vsftpd vsftpd.service" "stopping and disabling/removing vsftpd"
    run_check "2.1.8"  "L1S,L1W" "AUTO" "Ensure message access server services are not in use" "audit_2_1_8" "fix_2_1_8" "stopping and disabling/removing dovecot and cyrus-imapd"
    run_check "2.1.9"  "L1S,L1W" "AUTO" "Ensure network file system services are not in use" "audit_svc_disabled nfs-utils nfs-server.service" "fix_svc_disabled nfs-utils nfs-server.service" "stopping and disabling/removing nfs-utils"
    run_check "2.1.10" "L1S"     "AUTO" "Ensure print server services are not in use" "audit_svc_disabled cups cups.socket cups.service" "fix_svc_disabled cups cups.socket cups.service" "stopping and disabling/removing cups"
    run_check "2.1.11" "L1S,L1W" "AUTO" "Ensure rpcbind services are not in use" "audit_svc_disabled rpcbind rpcbind.socket rpcbind.service" "fix_svc_disabled rpcbind rpcbind.socket rpcbind.service" "stopping and disabling/removing rpcbind"
    run_check "2.1.12" "L1S,L1W" "AUTO" "Ensure rsync services are not in use" "audit_svc_disabled rsync-daemon rsyncd.socket rsyncd.service" "fix_svc_disabled rsync-daemon rsyncd.socket rsyncd.service" "stopping and disabling/removing rsync-daemon"
    run_check "2.1.13" "L1S,L1W" "AUTO" "Ensure samba file server services are not in use" "audit_svc_disabled samba smb.service" "fix_svc_disabled samba smb.service" "stopping and disabling/removing samba"
    run_check "2.1.14" "L1S,L1W" "AUTO" "Ensure snmp services are not in use" "audit_svc_disabled net-snmp snmpd.service" "fix_svc_disabled net-snmp snmpd.service" "stopping and disabling/removing net-snmp"
    run_check "2.1.15" "L1S,L1W" "AUTO" "Ensure telnet server services are not in use" "audit_svc_disabled telnet-server telnet.socket" "fix_svc_disabled telnet-server telnet.socket" "stopping and disabling/removing telnet-server"
    run_check "2.1.16" "L1S,L1W" "AUTO" "Ensure tftp server services are not in use" "audit_svc_disabled tftp-server tftp.socket tftp.service" "fix_svc_disabled tftp-server tftp.socket tftp.service" "stopping and disabling/removing tftp-server"
    run_check "2.1.17" "L1S,L1W" "AUTO" "Ensure web proxy server services are not in use" "audit_svc_disabled squid squid.service" "fix_svc_disabled squid squid.service" "stopping and disabling/removing squid"
    run_check "2.1.18" "L1S,L1W" "AUTO" "Ensure web server services are not in use" "audit_2_1_18" "fix_2_1_18" "stopping and disabling/removing httpd and nginx"
    run_check "2.1.19" "L2S"     "AUTO" "Ensure GNOME Display Manager is removed" "audit_pkg_removed gdm" "fix_pkg_removed gdm" "removing gdm package"
    run_check "2.1.20" "L1S"     "AUTO" "Ensure X window server services are not in use" "audit_pkg_removed xorg-x11-server-Xwayland" "fix_pkg_removed xorg-x11-server-Xwayland" "removing xorg-x11-server-Xwayland"
    run_check "2.1.21" "L1S,L1W" "AUTO" "Ensure mail transfer agents are configured for local-only mode" "audit_2_1_21" "fix_2_1_21" "configuring postfix/MTA for loopback-only listening"
    run_check "2.1.22" "L1S,L1W" "MANUAL" "Ensure only approved services are listening on a network interface" "audit_2_1_22" "manual_only" "Review listening sockets via 'ss -plntu' and stop/disable any unapproved services"

    # 2.2 Client Services
    run_check "2.2.1" "L1S,L1W" "AUTO" "Ensure ftp client is not installed" "audit_pkg_removed ftp" "fix_pkg_removed ftp" "removing ftp client"
    run_check "2.2.2" "L1S,L1W" "AUTO" "Ensure ldap client is not installed" "audit_pkg_removed openldap-clients" "fix_pkg_removed openldap-clients" "removing openldap-clients"
    run_check "2.2.3" "L1S,L1W" "AUTO" "Ensure telnet client is not installed" "audit_pkg_removed telnet" "fix_pkg_removed telnet" "removing telnet client"
    run_check "2.2.4" "L1S,L1W" "AUTO" "Ensure tftp client is not installed" "audit_pkg_removed tftp" "fix_pkg_removed tftp" "removing tftp client"

    # 2.3 Time Synchronization
    run_check "2.3.1" "L1S,L1W" "AUTO" "Ensure time synchronization is in use" "audit_pkg_installed chrony" "fix_pkg_installed chrony" "installing chrony"
    run_check "2.3.2" "L1S,L1W" "AUTO" "Ensure chrony is configured" "audit_2_3_2" "fix_2_3_2" "configuring NTP server/pool in /etc/chrony.conf" 1
    run_check "2.3.3" "L1S,L1W" "AUTO" "Ensure chrony is not run as the root user" "audit_2_3_3" "fix_2_3_3" "removing '-u root' from /etc/sysconfig/chronyd"

    # 2.4 Job Schedulers
    run_check "2.4.1.1" "L1S,L1W" "AUTO" "Ensure cron daemon is enabled and active" "audit_2_4_1_1" "fix_2_4_1_1" "enabling and starting crond.service"
    run_check "2.4.1.2" "L1S,L1W" "AUTO" "Ensure access to /etc/crontab is configured" "audit_file_access /etc/crontab '0?[0246]00' root root" "fix_file_access /etc/crontab 0600 root root" "setting 0600 root:root on /etc/crontab"
    run_check "2.4.1.3" "L1S,L1W" "AUTO" "Ensure access to /etc/cron.hourly is configured" "audit_file_access /etc/cron.hourly '0?[02467]00' root root" "fix_file_access /etc/cron.hourly 0700 root root" "setting 0700 root:root on /etc/cron.hourly"
    run_check "2.4.1.4" "L1S,L1W" "AUTO" "Ensure access to /etc/cron.daily is configured" "audit_file_access /etc/cron.daily '0?[02467]00' root root" "fix_file_access /etc/cron.daily 0700 root root" "setting 0700 root:root on /etc/cron.daily"
    run_check "2.4.1.5" "L1S,L1W" "AUTO" "Ensure access to /etc/cron.weekly is configured" "audit_file_access /etc/cron.weekly '0?[02467]00' root root" "fix_file_access /etc/cron.weekly 0700 root root" "setting 0700 root:root on /etc/cron.weekly"
    run_check "2.4.1.6" "L1S,L1W" "AUTO" "Ensure access to /etc/cron.monthly is configured" "audit_file_access /etc/cron.monthly '0?[02467]00' root root" "fix_file_access /etc/cron.monthly 0700 root root" "setting 0700 root:root on /etc/cron.monthly"
    run_check "2.4.1.7" "L1S,L1W" "AUTO" "Ensure access to /etc/cron.yearly is configured" "audit_file_access /etc/cron.yearly '0?[02467]00' root root 1" "fix_file_access /etc/cron.yearly 0700 root root" "setting 0700 root:root on /etc/cron.yearly"
    run_check "2.4.1.8" "L1S,L1W" "AUTO" "Ensure access to /etc/cron.d is configured" "audit_file_access /etc/cron.d '0?[02467]00' root root" "fix_file_access /etc/cron.d 0700 root root" "setting 0700 root:root on /etc/cron.d"
    run_check "2.4.1.9" "L1S,L1W" "AUTO" "Ensure access to crontab is configured" "audit_2_4_1_9" "fix_2_4_1_9" "configuring /etc/cron.allow and removing /etc/cron.deny"
    run_check "2.4.2.1" "L1S,L1W" "AUTO" "Ensure access to at is configured" "audit_2_4_2_1" "fix_2_4_2_1" "configuring /etc/at.allow and removing /etc/at.deny"
}

audit_2_1_8() {
    audit_svc_disabled dovecot dovecot.socket dovecot.service && \
    audit_svc_disabled cyrus-imapd cyrus-imapd.service
}
fix_2_1_8() {
    fix_svc_disabled dovecot dovecot.socket dovecot.service
    fix_svc_disabled cyrus-imapd cyrus-imapd.service
}
audit_2_1_18() {
    audit_svc_disabled httpd httpd.socket httpd.service && \
    audit_svc_disabled nginx nginx.service
}
fix_2_1_18() {
    fix_svc_disabled httpd httpd.socket httpd.service
    fix_svc_disabled nginx nginx.service
}
audit_2_1_21() {
    if ss -plntu 2>/dev/null | grep -P ':(25|465|587)\b' | grep -Pvq '(127\.0\.0\.1|\[?::1\]?)'; then
        CHECK_DETAIL="MTA is listening on a non-loopback interface."
        return 1
    fi
    return 0
}
fix_2_1_21() {
    if [[ -f /etc/postfix/main.cf ]]; then
        sed -ri '/^\s*inet_interfaces\s*=/d' /etc/postfix/main.cf
        printf 'inet_interfaces = loopback-only\n' >> /etc/postfix/main.cf
        systemctl restart postfix 2>/dev/null || true
    fi
}
audit_2_1_22() {
    CHECK_DETAIL="Listening sockets: $(ss -plntu 2>/dev/null | awk 'NR>1{print $5}' | paste -sd, -)"
    return 1
}
audit_2_3_2() {
    grep -Prqs '^\h*(server|pool)\h+\S+' /etc/chrony.conf /etc/chrony.d/*.conf 2>/dev/null || { CHECK_DETAIL="No NTP server or pool configured in chrony."; return 1; }
}
fix_2_3_2() {
    local srv=""
    ask_input "Enter NTP server or pool (e.g. pool.ntp.org)" "2.pool.ntp.org" srv
    printf 'pool %s iburst\n' "$srv" >> /etc/chrony.conf
    systemctl restart chronyd 2>/dev/null || true
}
audit_2_3_3() {
    if grep -Psiq '^\h*OPTIONS="?\h*([^#\n\r]+\h+)?-u\h+root\b' /etc/sysconfig/chronyd 2>/dev/null; then
        CHECK_DETAIL="chronyd configured to run as root in /etc/sysconfig/chronyd"
        return 1
    fi
    return 0
}
fix_2_3_3() {
    [[ -f /etc/sysconfig/chronyd ]] && sed -ri 's/-u\s+root//g' /etc/sysconfig/chronyd
    systemctl restart chronyd 2>/dev/null || true
}
audit_2_4_1_1() {
    systemctl is-enabled crond.service 2>/dev/null | grep -q '^enabled' && systemctl is-active crond.service 2>/dev/null | grep -q '^active' || { CHECK_DETAIL="crond.service is not enabled and active."; return 1; }
}
fix_2_4_1_1() {
    systemctl unmask crond.service 2>/dev/null || true
    systemctl --now enable crond.service
}
audit_2_4_1_9() {
    [[ ! -e /etc/cron.deny ]] || { CHECK_DETAIL="/etc/cron.deny exists."; return 1; }
    audit_file_access /etc/cron.allow "0?[0246][04]0" root "(root|crontab)"
}
fix_2_4_1_9() {
    rm -f /etc/cron.deny
    local grp="root"
    grep -Pq '^\h*crontab:' /etc/group && grp="crontab"
    fix_file_access /etc/cron.allow 0640 root "$grp"
}
audit_2_4_2_1() {
    [[ ! -e /etc/at.deny ]] || { CHECK_DETAIL="/etc/at.deny exists."; return 1; }
    audit_file_access /etc/at.allow "0?[0246][04]0" root "(root|daemon)"
}
fix_2_4_2_1() {
    rm -f /etc/at.deny
    local grp="root"
    grep -Pq '^daemon\b' /etc/group && grp="daemon"
    fix_file_access /etc/at.allow 0640 root "$grp"
}

#===============================================================================
# SECTION 3: Network
#===============================================================================
run_section_3() {
    echo -e "\n${C_BOLD}=== Section 3: Network ===${C_RESET}"

    run_check "3.1.1" "L1S,L1W" "MANUAL" "Ensure IPv6 status is identified" "manual_only" "manual_only" "Verify IPv6 status matches site policy (/sys/module/ipv6/parameters/disable)"
    run_check "3.1.2" "L1S"     "AUTO"   "Ensure wireless interfaces are not available" "audit_3_1_2" "fix_3_1_2" "disabling wireless kernel modules"
    run_check "3.1.3" "L1S,L2W" "AUTO"   "Ensure bluetooth services are not in use" "audit_pkg_removed bluez" "fix_3_1_3" "stopping bluetooth.service and removing bluez"

    # 3.2 Network Kernel Modules
    run_check "3.2.1" "L1S,L1W" "AUTO" "Ensure atm kernel module is not available"  "audit_kmod atm net"  "fix_kmod atm"  "blacklisting and disabling atm module"
    run_check "3.2.2" "L1S,L1W" "AUTO" "Ensure can kernel module is not available"  "audit_kmod can net"  "fix_kmod can"  "blacklisting and disabling can module"
    run_check "3.2.3" "L1S,L1W" "AUTO" "Ensure dccp kernel module is not available" "audit_kmod dccp net" "fix_kmod dccp" "blacklisting and disabling dccp module"
    run_check "3.2.4" "L1S,L1W" "AUTO" "Ensure tipc kernel module is not available" "audit_kmod tipc net" "fix_kmod tipc" "blacklisting and disabling tipc module"
    run_check "3.2.5" "L1S,L1W" "AUTO" "Ensure rds kernel module is not available"  "audit_kmod rds net"  "fix_kmod rds"  "blacklisting and disabling rds module"
    run_check "3.2.6" "L1S,L1W" "AUTO" "Ensure sctp kernel module is not available" "audit_kmod sctp net" "fix_kmod sctp" "blacklisting and disabling sctp module"

    # 3.3 Network Kernel Parameters
    run_check "3.3.1.1"  "L1W,L2S" "AUTO" "Ensure net.ipv4.ip_forward is configured"                   "audit_sysctl net.ipv4.ip_forward 0"                   "fix_sysctl net.ipv4.ip_forward 0"                   "setting net.ipv4.ip_forward = 0"
    run_check "3.3.1.2"  "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.all.forwarding is configured"          "audit_sysctl net.ipv4.conf.all.forwarding 0"          "fix_sysctl net.ipv4.conf.all.forwarding 0"          "setting net.ipv4.conf.all.forwarding = 0"
    run_check "3.3.1.3"  "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.default.forwarding is configured"      "audit_sysctl net.ipv4.conf.default.forwarding 0"      "fix_sysctl net.ipv4.conf.default.forwarding 0"      "setting net.ipv4.conf.default.forwarding = 0"
    run_check "3.3.1.4"  "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.all.send_redirects is configured"      "audit_sysctl net.ipv4.conf.all.send_redirects 0"      "fix_sysctl net.ipv4.conf.all.send_redirects 0"      "setting net.ipv4.conf.all.send_redirects = 0"
    run_check "3.3.1.5"  "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.default.send_redirects is configured"  "audit_sysctl net.ipv4.conf.default.send_redirects 0"  "fix_sysctl net.ipv4.conf.default.send_redirects 0"  "setting net.ipv4.conf.default.send_redirects = 0"
    run_check "3.3.1.6"  "L1S,L1W" "AUTO" "Ensure net.ipv4.icmp_ignore_bogus_error_responses is configured" "audit_sysctl net.ipv4.icmp_ignore_bogus_error_responses 1" "fix_sysctl net.ipv4.icmp_ignore_bogus_error_responses 1" "setting net.ipv4.icmp_ignore_bogus_error_responses = 1"
    run_check "3.3.1.7"  "L1S,L1W" "AUTO" "Ensure net.ipv4.icmp_echo_ignore_broadcasts is configured"  "audit_sysctl net.ipv4.icmp_echo_ignore_broadcasts 1"  "fix_sysctl net.ipv4.icmp_echo_ignore_broadcasts 1"  "setting net.ipv4.icmp_echo_ignore_broadcasts = 1"
    run_check "3.3.1.8"  "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.all.accept_redirects is configured"    "audit_sysctl net.ipv4.conf.all.accept_redirects 0"    "fix_sysctl net.ipv4.conf.all.accept_redirects 0"    "setting net.ipv4.conf.all.accept_redirects = 0"
    run_check "3.3.1.9"  "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.default.accept_redirects is configured" "audit_sysctl net.ipv4.conf.default.accept_redirects 0" "fix_sysctl net.ipv4.conf.default.accept_redirects 0" "setting net.ipv4.conf.default.accept_redirects = 0"
    run_check "3.3.1.10" "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.all.secure_redirects is configured"    "audit_sysctl net.ipv4.conf.all.secure_redirects 0"    "fix_sysctl net.ipv4.conf.all.secure_redirects 0"    "setting net.ipv4.conf.all.secure_redirects = 0"
    run_check "3.3.1.11" "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.default.secure_redirects is configured" "audit_sysctl net.ipv4.conf.default.secure_redirects 0" "fix_sysctl net.ipv4.conf.default.secure_redirects 0" "setting net.ipv4.conf.default.secure_redirects = 0"
    run_check "3.3.1.12" "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.all.rp_filter is configured"           "audit_sysctl net.ipv4.conf.all.rp_filter 1"           "fix_sysctl net.ipv4.conf.all.rp_filter 1"           "setting net.ipv4.conf.all.rp_filter = 1"
    run_check "3.3.1.13" "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.default.rp_filter is configured"       "audit_sysctl net.ipv4.conf.default.rp_filter 1"       "fix_sysctl net.ipv4.conf.default.rp_filter 1"       "setting net.ipv4.conf.default.rp_filter = 1"
    run_check "3.3.1.14" "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.all.accept_source_route is configured" "audit_sysctl net.ipv4.conf.all.accept_source_route 0" "fix_sysctl net.ipv4.conf.all.accept_source_route 0" "setting net.ipv4.conf.all.accept_source_route = 0"
    run_check "3.3.1.15" "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.default.accept_source_route is configured" "audit_sysctl net.ipv4.conf.default.accept_source_route 0" "fix_sysctl net.ipv4.conf.default.accept_source_route 0" "setting net.ipv4.conf.default.accept_source_route = 0"
    run_check "3.3.1.16" "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.all.log_martians is configured"        "audit_sysctl net.ipv4.conf.all.log_martians 1"        "fix_sysctl net.ipv4.conf.all.log_martians 1"        "setting net.ipv4.conf.all.log_martians = 1"
    run_check "3.3.1.17" "L1S,L1W" "AUTO" "Ensure net.ipv4.conf.default.log_martians is configured"    "audit_sysctl net.ipv4.conf.default.log_martians 1"    "fix_sysctl net.ipv4.conf.default.log_martians 1"    "setting net.ipv4.conf.default.log_martians = 1"
    run_check "3.3.1.18" "L1S,L1W" "AUTO" "Ensure net.ipv4.tcp_syncookies is configured"               "audit_sysctl net.ipv4.tcp_syncookies 1"               "fix_sysctl net.ipv4.tcp_syncookies 1"               "setting net.ipv4.tcp_syncookies = 1"

    run_check "3.3.2.1" "L1S,L1W" "AUTO" "Ensure net.ipv6.conf.all.forwarding is configured"           "audit_sysctl net.ipv6.conf.all.forwarding 0"          "fix_sysctl net.ipv6.conf.all.forwarding 0"          "setting net.ipv6.conf.all.forwarding = 0"
    run_check "3.3.2.2" "L1S,L1W" "AUTO" "Ensure net.ipv6.conf.default.forwarding is configured"       "audit_sysctl net.ipv6.conf.default.forwarding 0"      "fix_sysctl net.ipv6.conf.default.forwarding 0"      "setting net.ipv6.conf.default.forwarding = 0"
    run_check "3.3.2.3" "L1S,L1W" "AUTO" "Ensure net.ipv6.conf.all.accept_redirects is configured"     "audit_sysctl net.ipv6.conf.all.accept_redirects 0"    "fix_sysctl net.ipv6.conf.all.accept_redirects 0"    "setting net.ipv6.conf.all.accept_redirects = 0"
    run_check "3.3.2.4" "L1S,L1W" "AUTO" "Ensure net.ipv6.conf.default.accept_redirects is configured" "audit_sysctl net.ipv6.conf.default.accept_redirects 0" "fix_sysctl net.ipv6.conf.default.accept_redirects 0" "setting net.ipv6.conf.default.accept_redirects = 0"
    run_check "3.3.2.5" "L1S,L1W" "AUTO" "Ensure net.ipv6.conf.all.accept_source_route is configured"  "audit_sysctl net.ipv6.conf.all.accept_source_route 0" "fix_sysctl net.ipv6.conf.all.accept_source_route 0" "setting net.ipv6.conf.all.accept_source_route = 0"
    run_check "3.3.2.6" "L1S,L1W" "AUTO" "Ensure net.ipv6.conf.default.accept_source_route is configured" "audit_sysctl net.ipv6.conf.default.accept_source_route 0" "fix_sysctl net.ipv6.conf.default.accept_source_route 0" "setting net.ipv6.conf.default.accept_source_route = 0"
    run_check "3.3.2.7" "L1S,L1W" "AUTO" "Ensure net.ipv6.conf.all.accept_ra is configured"            "audit_sysctl net.ipv6.conf.all.accept_ra 0"           "fix_sysctl net.ipv6.conf.all.accept_ra 0"           "setting net.ipv6.conf.all.accept_ra = 0"
    run_check "3.3.2.8" "L1S,L1W" "AUTO" "Ensure net.ipv6.conf.default.accept_ra is configured"        "audit_sysctl net.ipv6.conf.default.accept_ra 0"       "fix_sysctl net.ipv6.conf.default.accept_ra 0"       "setting net.ipv6.conf.default.accept_ra = 0"
}

audit_3_1_2() {
    if find /sys/class/net/*/ -type d -name wireless 2>/dev/null | grep -q .; then
        CHECK_DETAIL="Wireless interface(s) detected in /sys/class/net/*/wireless."
        return 1
    fi
    return 0
}
fix_3_1_2() {
    local d mod
    for d in /sys/class/net/*/wireless; do
        mod="$(basename "$(readlink -f "${d}/../device/driver/module" 2>/dev/null)" 2>/dev/null || true)"
        [[ -n "$mod" ]] && fix_kmod "$mod"
    done
    nmcli radio wifi off 2>/dev/null || true
}
fix_3_1_3() {
    systemctl stop bluetooth.service 2>/dev/null || true
    dnf -y remove bluez
}

#===============================================================================
# SECTION 4: Host Based Firewall
#===============================================================================
run_section_4() {
    echo -e "\n${C_BOLD}=== Section 4: Host Based Firewall ===${C_RESET}"

    run_check "4.1.1" "L1S,L1W" "AUTO"   "Ensure firewalld is installed" "audit_pkg_installed firewalld" "fix_pkg_installed firewalld" "installing firewalld"
    run_check "4.1.2" "L1S,L1W" "AUTO"   "Ensure firewalld backend is configured" "audit_4_1_2" "fix_4_1_2" "setting FirewallBackend=nftables in /etc/firewalld/firewalld.conf"
    run_check "4.1.3" "L1S,L1W" "AUTO"   "Ensure firewalld.service is configured" "audit_4_1_3" "fix_4_1_3" "enabling and starting firewalld.service"
    run_check "4.1.4" "L1S,L1W" "AUTO"   "Ensure firewalld active zone target is configured" "audit_4_1_4" "fix_4_1_4" "setting firewalld active zone target (DROP/REJECT/default)" 1
    run_check "4.1.5" "L1S,L1W" "MANUAL" "Ensure firewalld loopback traffic is configured" "audit_4_1_5" "fix_4_1_5" "assigning lo interface to trusted zone in firewalld"
    run_check "4.1.6" "L1S,L1W" "MANUAL" "Ensure firewalld loopback source address traffic is configured" "audit_4_1_6" "fix_4_1_6" "adding loopback drop rich rules to firewalld" 1
    run_check "4.1.7" "L1S,L1W" "MANUAL" "Ensure firewalld services and ports are configured" "manual_only" "manual_only" "Review 'firewall-cmd --list-all' and remove unapproved services/ports"
}

audit_4_1_2() {
    grep -Psiq '^\h*FirewallBackend\h*=\h*nftables\b' /etc/firewalld/firewalld.conf 2>/dev/null || { CHECK_DETAIL="FirewallBackend=nftables not set in /etc/firewalld/firewalld.conf"; return 1; }
}
fix_4_1_2() {
    sed -ri 's/^\s*FirewallBackend\s*=.*/FirewallBackend=nftables/I' /etc/firewalld/firewalld.conf
    systemctl restart firewalld 2>/dev/null || true
}
audit_4_1_3() {
    systemctl is-enabled firewalld.service 2>/dev/null | grep -q '^enabled' && systemctl is-active firewalld.service 2>/dev/null | grep -q '^active' || { CHECK_DETAIL="firewalld.service is not enabled and active."; return 1; }
}
fix_4_1_3() {
    systemctl unmask firewalld.service 2>/dev/null || true
    systemctl --now enable firewalld.service
}
audit_4_1_4() {
    require_cmd firewall-cmd || return $?
    require_root || return $?
    systemctl is-active firewalld.service >/dev/null 2>&1 || { CHECK_DETAIL="firewalld is not active."; return 2; }
    local z tgt
    while IFS= read -r z; do
        [[ -z "$z" ]] && continue
        tgt="$(firewall-cmd --zone="$z" --get-target 2>/dev/null || true)"
        if [[ ! "$tgt" =~ ^(DROP|REJECT|default)$ ]]; then
            CHECK_DETAIL="Active zone '$z' has target '$tgt' (expected DROP, REJECT, or default)."
            return 1
        fi
    done < <(firewall-cmd --get-active-zones 2>/dev/null | grep -v '^\s')
    return 0
}
fix_4_1_4() {
    local z tgt=""
    while IFS= read -r z; do
        [[ -z "$z" ]] && continue
        ask_input "Enter target for firewalld zone '$z' (DROP, REJECT, or default)" "DROP" tgt
        firewall-cmd --permanent --zone="$z" --set-target="$tgt"
    done < <(firewall-cmd --get-active-zones 2>/dev/null | grep -v '^\s')
    firewall-cmd --reload
}
audit_4_1_5() {
    require_cmd firewall-cmd || return $?
    require_root || return $?
    systemctl is-active firewalld.service >/dev/null 2>&1 || { CHECK_DETAIL="firewalld is not active."; return 2; }
    [[ "$(firewall-cmd --get-zone-of-interface=lo 2>/dev/null || true)" == "trusted" ]] || { CHECK_DETAIL="Interface lo is not in trusted zone."; return 1; }
}
fix_4_1_5() {
    firewall-cmd --permanent --zone=trusted --add-interface=lo
    firewall-cmd --reload
}
audit_4_1_6() {
    require_cmd firewall-cmd || return $?
    require_root || return $?
    systemctl is-active firewalld.service >/dev/null 2>&1 || { CHECK_DETAIL="firewalld is not active."; return 2; }
    firewall-cmd --list-rich-rules 2>/dev/null | grep -Pq '(127\.0\.0\.1|::1)' || { CHECK_DETAIL="No loopback source drop rich rules found."; return 1; }
}
fix_4_1_6() {
    local z=""
    ask_input "Enter firewalld zone for loopback source drop rules" "public" z
    firewall-cmd --permanent --zone="$z" --add-rich-rule='rule family=ipv4 source address="127.0.0.1" destination not address="127.0.0.1" drop'
    firewall-cmd --permanent --zone="$z" --add-rich-rule='rule family=ipv6 source address="::1" destination not address="::1" drop'
    firewall-cmd --reload
}

#===============================================================================
# SECTION 5: Access Control
#===============================================================================
run_section_5() {
    echo -e "\n${C_BOLD}=== Section 5: Access Control ===${C_RESET}"

    # 5.1 Configure SSH Server
    run_check "5.1.1"  "L1S,L1W" "AUTO" "Ensure access to /etc/ssh/sshd_config is configured" "audit_5_1_1" "fix_5_1_1" "setting 0600 root:root on /etc/ssh/sshd_config and sshd_config.d/*"
    run_check "5.1.2"  "L1S,L1W" "AUTO" "Ensure access to SSH private host key files is configured" "audit_5_1_2" "fix_5_1_2" "securing SSH private host key permissions and ownership"
    run_check "5.1.3"  "L1S,L1W" "AUTO" "Ensure access to SSH public host key files is configured" "audit_5_1_3" "fix_5_1_3" "setting 0644 root:root on SSH public host key files"
    run_check "5.1.4"  "L1S,L1W" "AUTO" "Ensure sshd access is configured" "audit_sshd_param '(allow|deny)(users|groups)' '^\h*(allow|deny)(users|groups)\h+\H+'" "fix_5_1_4" "configuring AllowUsers/AllowGroups in sshd_config" 1
    run_check "5.1.5"  "L1S,L1W" "AUTO" "Ensure sshd Banner is configured" "audit_sshd_param banner '^banner\h+\/\H+'" "fix_5_1_5" "setting sshd Banner" 1
    run_check "5.1.6"  "L1S,L1W" "AUTO" "Ensure sshd Ciphers are configured" "audit_sshd_param ciphers '^ciphers\h+([^#\n\r]+,)?((3des|aes(128|192|256))-cbc)\b' 1" "fix_1_6_4" "disabling CBC ciphers in crypto policy for SSH"
    run_check "5.1.7"  "L1S,L1W" "AUTO" "Ensure sshd ClientAliveInterval and ClientAliveCountMax are configured" "audit_5_1_7" "fix_5_1_7" "setting ClientAliveInterval 15 and ClientAliveCountMax 3"
    run_check "5.1.8"  "L1W,L2S" "AUTO" "Ensure sshd DisableForwarding is enabled" "audit_sshd_param disableforwarding '^disableforwarding\h+yes\b'" "fix_sshd_param DisableForwarding yes" "setting DisableForwarding yes"
    run_check "5.1.9"  "L1W,L2S" "AUTO" "Ensure sshd GSSAPIAuthentication is disabled" "audit_sshd_param gssapiauthentication '^gssapiauthentication\h+no\b'" "fix_sshd_param GSSAPIAuthentication no" "setting GSSAPIAuthentication no"
    run_check "5.1.10" "L1S,L1W" "AUTO" "Ensure sshd HostbasedAuthentication is disabled" "audit_sshd_param hostbasedauthentication '^hostbasedauthentication\h+no\b'" "fix_sshd_param HostbasedAuthentication no" "setting HostbasedAuthentication no"
    run_check "5.1.11" "L1S,L1W" "AUTO" "Ensure sshd IgnoreRhosts is enabled" "audit_sshd_param ignorerhosts '^ignorerhosts\h+yes\b'" "fix_sshd_param IgnoreRhosts yes" "setting IgnoreRhosts yes"
    run_check "5.1.12" "L1S,L1W" "AUTO" "Ensure sshd KexAlgorithms is configured" "audit_sshd_param kexalgorithms '^kexalgorithms\h+([^#\n\r]+,)?(diffie-hellman-group1-sha1|diffie-hellman-group14-sha1|diffie-hellman-group-exchange-sha1)\b' 1" "fix_1_6_2" "disabling weak SHA1 KexAlgorithms via crypto policy"
    run_check "5.1.13" "L1S,L1W" "AUTO" "Ensure sshd LoginGraceTime is configured" "audit_5_1_13" "fix_sshd_param LoginGraceTime 60" "setting LoginGraceTime 60"
    run_check "5.1.14" "L1S,L1W" "AUTO" "Ensure sshd LogLevel is configured" "audit_sshd_param loglevel '^loglevel\h+(VERBOSE|INFO)\b'" "fix_sshd_param LogLevel VERBOSE" "setting LogLevel VERBOSE"
    run_check "5.1.15" "L1S,L1W" "AUTO" "Ensure sshd MACs are configured" "audit_sshd_param macs '^macs\h+([^#\n\r]+,)?(hmac-md5|hmac-md5-96|hmac-sha1-96|umac-64@openssh\.com|hmac-md5-etm@openssh\.com|hmac-md5-96-etm@openssh\.com|hmac-sha1-etm@openssh\.com|hmac-sha1-96-etm@openssh\.com|umac-64-etm@openssh\.com)\b' 1" "fix_1_6_3" "disabling weak SSH MACs via crypto policy"
    run_check "5.1.16" "L1S,L1W" "AUTO" "Ensure sshd MaxAuthTries is configured" "audit_5_1_16" "fix_sshd_param MaxAuthTries 4" "setting MaxAuthTries 4"
    run_check "5.1.17" "L1S,L1W" "AUTO" "Ensure sshd MaxStartups is configured" "audit_5_1_17" "fix_sshd_param MaxStartups 10:30:60" "setting MaxStartups 10:30:60"
    run_check "5.1.18" "L1S,L1W" "AUTO" "Ensure sshd MaxSessions is configured" "audit_5_1_18" "fix_sshd_param MaxSessions 10" "setting MaxSessions 10"
    run_check "5.1.19" "L1S,L1W" "AUTO" "Ensure sshd PermitEmptyPasswords is disabled" "audit_sshd_param permitemptypasswords '^permitemptypasswords\h+no\b'" "fix_sshd_param PermitEmptyPasswords no" "setting PermitEmptyPasswords no"
    run_check "5.1.20" "L1S,L1W" "AUTO" "Ensure sshd PermitRootLogin is disabled" "audit_sshd_param permitrootlogin '^permitrootlogin\h+no\b'" "fix_sshd_param PermitRootLogin no" "setting PermitRootLogin no"
    run_check "5.1.21" "L1S,L1W" "AUTO" "Ensure sshd PermitUserEnvironment is disabled" "audit_sshd_param permituserenvironment '^permituserenvironment\h+no\b'" "fix_sshd_param PermitUserEnvironment no" "setting PermitUserEnvironment no"
    run_check "5.1.22" "L1S,L1W" "AUTO" "Ensure sshd UsePAM is enabled" "audit_sshd_param usepam '^usepam\h+yes\b'" "fix_sshd_param UsePAM yes" "setting UsePAM yes"

    # 5.2 Configure Privilege Escalation
    run_check "5.2.1" "L1S,L1W" "AUTO" "Ensure sudo is installed" "audit_pkg_installed sudo" "fix_pkg_installed sudo" "installing sudo"
    run_check "5.2.2" "L1S,L1W" "AUTO" "Ensure sudo commands use pty" "audit_5_2_2" "fix_5_2_2" "adding 'Defaults use_pty' to /etc/sudoers.d/60-cis"
    run_check "5.2.3" "L1S,L1W" "AUTO" "Ensure sudo log file exists" "audit_5_2_3" "fix_5_2_3" "configuring 'Defaults logfile' in /etc/sudoers.d/60-cis" 1
    run_check "5.2.4" "L2S,L2W" "AUTO" "Ensure users must provide password for escalation" "audit_5_2_4" "fix_5_2_4" "commenting out NOPASSWD entries in /etc/sudoers*"
    run_check "5.2.5" "L1S,L1W" "AUTO" "Ensure re-authentication for privilege escalation is not disabled globally" "audit_5_2_5" "fix_5_2_5" "commenting out !authenticate entries in /etc/sudoers*"
    run_check "5.2.6" "L1S,L1W" "AUTO" "Ensure sudo timestamp_timeout is configured" "audit_5_2_6" "fix_5_2_6" "setting Defaults timestamp_timeout in /etc/sudoers.d/60-cis" 1
    run_check "5.2.7" "L1S,L1W" "AUTO" "Ensure access to the su command is restricted" "audit_5_2_7" "fix_5_2_7" "restricting su via pam_wheel.so use_uid in /etc/pam.d/su"

    # 5.3 Pluggable Authentication Modules (PAM)
    run_check "5.3.1.1"   "L1S,L1W" "AUTO"   "Ensure active authselect profile includes pam modules" "audit_5_3_1_1" "fix_5_3_1_1" "creating/selecting custom authselect profile"
    run_check "5.3.1.2"   "L1S,L1W" "AUTO"   "Ensure pam_faillock module is enabled" "audit_5_3_1_mod pam_faillock" "fix_5_3_1_feat with-faillock" "enabling with-faillock in authselect"
    run_check "5.3.1.3"   "L1S,L1W" "AUTO"   "Ensure pam_pwquality module is enabled" "audit_5_3_1_mod pam_pwquality" "fix_5_3_1_1" "enabling pam_pwquality in authselect profile"
    run_check "5.3.1.4"   "L1S,L1W" "AUTO"   "Ensure pam_pwhistory module is enabled" "audit_5_3_1_mod pam_pwhistory" "fix_5_3_1_feat with-pwhistory" "enabling with-pwhistory in authselect"
    run_check "5.3.1.5"   "L1S,L1W" "AUTO"   "Ensure pam_unix module is enabled" "audit_5_3_1_mod pam_unix" "fix_5_3_1_1" "enabling pam_unix in authselect profile"

    run_check "5.3.2.1.1" "L1S,L1W" "AUTO"   "Ensure password failed attempts lockout is configured" "audit_kv_file /etc/security/faillock.conf /etc/security/faillock.conf.d deny le 5" "fix_kv_confd /etc/security/faillock.conf.d 60-cis.conf deny 5" "setting deny = 5 in faillock.conf.d"
    run_check "5.3.2.1.2" "L1S,L1W" "AUTO"   "Ensure password unlock time is configured" "audit_5_3_2_1_2" "fix_kv_confd /etc/security/faillock.conf.d 60-cis.conf unlock_time 900" "setting unlock_time = 900 in faillock.conf.d"
    run_check "5.3.2.1.3" "L2S,L2W" "AUTO"   "Ensure password failed attempts lockout includes root account" "audit_flag_file /etc/security/faillock.conf /etc/security/faillock.conf.d even_deny_root" "fix_flag_confd /etc/security/faillock.conf.d 60-cis.conf even_deny_root" "adding even_deny_root to faillock.conf.d"

    run_check "5.3.2.2.1" "L1S,L1W" "AUTO"   "Ensure password number of changed characters is configured" "audit_kv_file /etc/security/pwquality.conf /etc/security/pwquality.conf.d difok ge 2" "fix_kv_confd /etc/security/pwquality.conf.d 60-cis.conf difok 2" "setting difok = 2 in pwquality.conf.d"
    run_check "5.3.2.2.2" "L1S,L1W" "AUTO"   "Ensure password length is configured" "audit_kv_file /etc/security/pwquality.conf /etc/security/pwquality.conf.d minlen ge 14" "fix_kv_confd /etc/security/pwquality.conf.d 60-cis.conf minlen 14" "setting minlen = 14 in pwquality.conf.d"
    run_check "5.3.2.2.3" "L1S,L1W" "MANUAL" "Ensure password complexity is configured" "audit_kv_file /etc/security/pwquality.conf /etc/security/pwquality.conf.d minclass ge 4" "fix_5_3_2_2_3" "setting minclass in pwquality.conf.d" 1
    run_check "5.3.2.2.4" "L1S,L1W" "AUTO"   "Ensure password same consecutive characters is configured" "audit_kv_file /etc/security/pwquality.conf /etc/security/pwquality.conf.d maxrepeat le 3" "fix_kv_confd /etc/security/pwquality.conf.d 60-cis.conf maxrepeat 3" "setting maxrepeat = 3 in pwquality.conf.d"
    run_check "5.3.2.2.5" "L1S,L1W" "AUTO"   "Ensure password maximum sequential characters is configured" "audit_kv_file /etc/security/pwquality.conf /etc/security/pwquality.conf.d maxsequence le 3" "fix_kv_confd /etc/security/pwquality.conf.d 60-cis.conf maxsequence 3" "setting maxsequence = 3 in pwquality.conf.d"
    run_check "5.3.2.2.6" "L1S,L1W" "AUTO"   "Ensure password dictionary check is enabled" "audit_kv_file /etc/security/pwquality.conf /etc/security/pwquality.conf.d dictcheck eq 1" "fix_kv_confd /etc/security/pwquality.conf.d 60-cis.conf dictcheck 1" "setting dictcheck = 1 in pwquality.conf.d"
    run_check "5.3.2.2.7" "L1S,L1W" "AUTO"   "Ensure password quality is enforced for the root user" "audit_flag_file /etc/security/pwquality.conf /etc/security/pwquality.conf.d enforce_for_root" "fix_flag_confd /etc/security/pwquality.conf.d 60-cis.conf enforce_for_root" "adding enforce_for_root to pwquality.conf.d"

    run_check "5.3.2.3.1" "L1S,L1W" "AUTO"   "Ensure password history remember is configured" "audit_kv_file /etc/security/pwhistory.conf /etc/security/pwhistory.conf.d remember ge 24" "fix_kv_confd /etc/security/pwhistory.conf.d 60-cis.conf remember 24" "setting remember = 24 in pwhistory.conf.d"
    run_check "5.3.2.3.2" "L1S,L1W" "AUTO"   "Ensure password history is enforced for the root user" "audit_flag_file /etc/security/pwhistory.conf /etc/security/pwhistory.conf.d enforce_for_root" "fix_flag_confd /etc/security/pwhistory.conf.d 60-cis.conf enforce_for_root" "adding enforce_for_root to pwhistory.conf.d"
    run_check "5.3.2.3.3" "L1S,L1W" "AUTO"   "Ensure pam_pwhistory includes use_authtok" "audit_pam_opt pam_pwhistory use_authtok 1" "fix_pam_opt pam_pwhistory use_authtok add" "adding use_authtok to pam_pwhistory in authselect"

    run_check "5.3.2.4.1" "L1S,L1W" "AUTO"   "Ensure pam_unix does not include nullok" "audit_pam_opt pam_unix nullok 0" "fix_pam_opt pam_unix nullok remove" "removing nullok from pam_unix"
    run_check "5.3.2.4.2" "L1S,L1W" "AUTO"   "Ensure pam_unix does not include remember" "audit_pam_opt pam_unix 'remember=\d+' 0" "fix_pam_opt pam_unix 'remember=[0-9]+' remove" "removing remember from pam_unix"
    run_check "5.3.2.4.3" "L1S,L1W" "AUTO"   "Ensure pam_unix includes a strong password hashing algorithm" "audit_pam_opt pam_unix '(sha512|yescrypt)' 1" "fix_pam_opt pam_unix yescrypt add" "adding yescrypt to pam_unix"
    run_check "5.3.2.4.4" "L1S,L1W" "AUTO"   "Ensure pam_unix includes use_authtok" "audit_pam_opt pam_unix use_authtok 1" "fix_pam_opt pam_unix use_authtok add" "adding use_authtok to pam_unix"

    # 5.4 User Accounts and Environment
    run_check "5.4.1.1" "L1S,L1W" "AUTO"   "Ensure password expiration is configured" "audit_5_4_1_1" "fix_5_4_1_1" "setting PASS_MAX_DAYS 365 in /etc/login.defs"
    run_check "5.4.1.2" "L2S,L2W" "MANUAL" "Ensure minimum password days is configured" "audit_5_4_1_2" "fix_5_4_1_2" "setting PASS_MIN_DAYS in /etc/login.defs" 1
    run_check "5.4.1.3" "L1S,L1W" "AUTO"   "Ensure password expiration warning days is configured" "audit_5_4_1_3" "fix_5_4_1_3" "setting PASS_WARN_AGE 7 in /etc/login.defs"
    run_check "5.4.1.4" "L1S,L1W" "AUTO"   "Ensure strong password hashing algorithm is configured" "audit_5_4_1_4" "fix_5_4_1_4" "setting ENCRYPT_METHOD in /etc/login.defs" 1
    run_check "5.4.1.5" "L1S,L1W" "AUTO"   "Ensure inactive password lock is configured" "audit_5_4_1_5" "fix_5_4_1_5" "setting default INACTIVE days via useradd -D -f" 1
    run_check "5.4.1.6" "L1S,L1W" "AUTO"   "Ensure all users last password change date is in the past" "audit_5_4_1_6" "manual_only" "Investigate and reset passwords for users with future last-change dates"

    run_check "5.4.2.1" "L1S,L1W" "AUTO" "Ensure root is the only UID 0 account" "audit_5_4_2_1" "manual_only" "Reassign or remove non-root UID 0 accounts in /etc/passwd"
    run_check "5.4.2.2" "L1S,L1W" "AUTO" "Ensure root is the only GID 0 account" "audit_5_4_2_2" "manual_only" "Reassign GID 0 on non-root accounts in /etc/passwd"
    run_check "5.4.2.3" "L1S,L1W" "AUTO" "Ensure group root is the only GID 0 group" "audit_5_4_2_3" "manual_only" "Reassign GID 0 on non-root groups in /etc/group"
    run_check "5.4.2.4" "L1S,L1W" "AUTO" "Ensure root account access is controlled" "audit_5_4_2_4" "fix_5_4_2_4" "setting or locking root password" 1
    run_check "5.4.2.5" "L1S,L1W" "AUTO" "Ensure root path integrity" "audit_5_4_2_5" "manual_only" "Fix root PATH entries (remove empty/., non-root-owned, or group/world-writable dirs)"
    run_check "5.4.2.6" "L1S,L1W" "AUTO" "Ensure root user umask is configured" "audit_5_4_2_6" "fix_5_4_2_6" "setting umask 027 in /root/.bash_profile and /root/.bashrc"
    run_check "5.4.2.7" "L1S,L1W" "AUTO" "Ensure system accounts do not have a valid login shell" "audit_5_4_2_7" "fix_5_4_2_7" "setting nologin shell on system accounts"
    run_check "5.4.2.8" "L1S,L1W" "AUTO" "Ensure accounts without a valid login shell are locked" "audit_5_4_2_8" "fix_5_4_2_8" "locking accounts without valid login shells"

    run_check "5.4.3.1" "L1S,L1W" "AUTO" "Ensure nologin is not listed in /etc/shells" "audit_5_4_3_1" "fix_5_4_3_1" "removing nologin from /etc/shells"
    run_check "5.4.3.2" "L1S,L1W" "AUTO" "Ensure default user shell timeout is configured" "audit_5_4_3_2" "fix_5_4_3_2" "setting readonly TMOUT=900 in /etc/profile.d/50-tmout.sh"
    run_check "5.4.3.3" "L1S,L1W" "AUTO" "Ensure default user umask is configured" "audit_5_4_3_3" "fix_5_4_3_3" "setting umask 027 in /etc/profile.d/50-cis-umask.sh and /etc/bashrc"
}

# --- Section 5 Implementations ------------------------------------------------
audit_5_1_1() {
    audit_file_access /etc/ssh/sshd_config "0?[0246]00" root root || return 1
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        audit_file_access "$f" "0?[0246]00" root root || return 1
    done
    return 0
}
fix_5_1_1() {
    chmod u-x,og-rwx /etc/ssh/sshd_config && chown root:root /etc/ssh/sshd_config
    find /etc/ssh/sshd_config.d -type f -name '*.conf' -exec chown root:root {} + -exec chmod u-x,og-rwx {} + 2>/dev/null || true
}
audit_5_1_2() {
    local f
    for f in /etc/ssh/ssh_host_*_key; do
        [[ -f "$f" ]] || continue
        audit_file_access "$f" "0?[0246][04]0" root "(root|ssh_keys)" || return 1
    done
    return 0
}
fix_5_1_2() {
    local f grp="root"
    grep -Pq '^ssh_keys:' /etc/group && grp="ssh_keys"
    for f in /etc/ssh/ssh_host_*_key; do
        [[ -f "$f" ]] || continue
        chown "root:${grp}" "$f"
        [[ "$grp" == "ssh_keys" ]] && chmod 0640 "$f" || chmod 0600 "$f"
    done
}
audit_5_1_3() {
    local f
    for f in /etc/ssh/ssh_host_*_key.pub; do
        [[ -f "$f" ]] || continue
        audit_file_access "$f" "0?[0246][04][04]" root root || return 1
    done
    return 0
}
fix_5_1_3() {
    find /etc/ssh -name 'ssh_host_*_key.pub' -type f -exec chown root:root {} + -exec chmod 0644 {} + 2>/dev/null || true
}
fix_5_1_4() {
    local mode="" list=""
    ask_input "Restrict SSH using AllowUsers or AllowGroups?" "AllowGroups" mode
    ask_input "Enter space-separated list for $mode (e.g. wheel or admin)" "wheel" list
    fix_sshd_param "$mode" "$list"
}
fix_5_1_5() {
    local bpath=""
    ask_input "Enter sshd Banner file path" "/etc/issue.net" bpath
    fix_sshd_param "Banner" "$bpath"
}
audit_5_1_7() {
    local iv cm
    iv="$(sshd -T 2>/dev/null | awk '$1=="clientaliveinterval"{print $2}')"
    cm="$(sshd -T 2>/dev/null | awk '$1=="clientalivecountmax"{print $2}')"
    [[ -n "$iv" && "$iv" -gt 0 && "$iv" -le 300 && -n "$cm" && "$cm" -gt 0 && "$cm" -le 3 ]] || { CHECK_DETAIL="ClientAliveInterval=$iv, ClientAliveCountMax=$cm"; return 1; }
}
fix_5_1_7() {
    fix_sshd_param "ClientAliveInterval" "15"
    fix_sshd_param "ClientAliveCountMax" "3"
}
audit_5_1_13() {
    local v
    v="$(sshd -T 2>/dev/null | awk '$1=="logingracetime"{print $2}')"
    [[ -n "$v" && "$v" -ge 1 && "$v" -le 60 ]] || { CHECK_DETAIL="LoginGraceTime=$v (expected 1..60)"; return 1; }
}
audit_5_1_16() {
    local v
    v="$(sshd -T 2>/dev/null | awk '$1=="maxauthtries"{print $2}')"
    [[ -n "$v" && "$v" -ge 1 && "$v" -le 4 ]] || { CHECK_DETAIL="MaxAuthTries=$v (expected 1..4)"; return 1; }
}
audit_5_1_17() {
    local ms a b c
    ms="$(sshd -T 2>/dev/null | awk '$1=="maxstartups"{print $2}')"
    IFS=':' read -r a b c <<< "$ms"
    [[ -n "$a" && "$a" -le 10 && "$b" -le 30 && "$c" -le 60 ]] || { CHECK_DETAIL="MaxStartups=$ms (expected <= 10:30:60)"; return 1; }
}
audit_5_1_18() {
    local v
    v="$(sshd -T 2>/dev/null | awk '$1=="maxsessions"{print $2}')"
    [[ -n "$v" && "$v" -ge 1 && "$v" -le 10 ]] || { CHECK_DETAIL="MaxSessions=$v (expected 1..10)"; return 1; }
}

audit_5_2_2() {
    require_readable /etc/sudoers || return $?
    grep -rPiq '^\h*Defaults\h+([^#\n\r]+,\h*)?use_pty\b' /etc/sudoers /etc/sudoers.d/ 2>/dev/null || { CHECK_DETAIL="Defaults use_pty not set in sudoers"; return 1; }
}
fix_5_2_2() {
    printf 'Defaults use_pty\n' >> /etc/sudoers.d/60-cis
    chmod 0440 /etc/sudoers.d/60-cis
}
audit_5_2_3() {
    require_readable /etc/sudoers || return $?
    grep -rPsiq '^\h*Defaults\h+([^#\n\r]+,\h*)?logfile\h*=\h*"?\S+"?' /etc/sudoers /etc/sudoers.d/ 2>/dev/null || { CHECK_DETAIL="Defaults logfile not set in sudoers"; return 1; }
}
fix_5_2_3() {
    local lf=""
    ask_input "Enter sudo log file path" "/var/log/sudo.log" lf
    printf 'Defaults logfile="%s"\n' "$lf" >> /etc/sudoers.d/60-cis
    chmod 0440 /etc/sudoers.d/60-cis
}
audit_5_2_4() {
    require_readable /etc/sudoers || return $?
    if grep -rPq '^[^#].*\bNOPASSWD\b' /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
        CHECK_DETAIL="NOPASSWD found in sudoers files."; return 1
    fi
    return 0
}
fix_5_2_4() {
    grep -rl '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | xargs -r sed -ri 's/^([^#].*NOPASSWD.*)$/# \1/'
}
audit_5_2_5() {
    require_readable /etc/sudoers || return $?
    if grep -rPq '^[^#].*!authenticate\b' /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
        CHECK_DETAIL="!authenticate found in sudoers files."; return 1
    fi
    return 0
}
fix_5_2_5() {
    grep -rl '^[^#].*!authenticate' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | xargs -r sed -ri 's/^([^#].*!authenticate.*)$/# \1/'
}
audit_5_2_6() {
    require_readable /etc/sudoers || return $?
    local v
    v="$(grep -rPho '^\h*Defaults\h+([^#\n\r]+,\h*)?timestamp_timeout\h*=\h*\K-?\d+' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | tail -n1 || true)"
    [[ -n "$v" && "$v" -ge 0 && "$v" -le 15 ]] || { CHECK_DETAIL="sudo timestamp_timeout=$v (expected 0..15)"; return 1; }
}
fix_5_2_6() {
    local t=""
    ask_input "Enter sudo timestamp_timeout in minutes (0-15)" "15" t
    printf 'Defaults timestamp_timeout=%s\n' "$t" >> /etc/sudoers.d/60-cis
    chmod 0440 /etc/sudoers.d/60-cis
}
audit_5_2_7() {
    grep -Pq '^\h*auth\h+(required|requisite)\h+pam_wheel\.so\h+([^#\n\r]+\h+)?use_uid\b' /etc/pam.d/su 2>/dev/null || { CHECK_DETAIL="pam_wheel.so use_uid not enforced in /etc/pam.d/su"; return 1; }
}
fix_5_2_7() {
    if grep -Pq 'pam_wheel\.so' /etc/pam.d/su; then
        sed -ri 's/^#?\s*(auth\s+required\s+pam_wheel\.so.*use_uid.*)$/\1/' /etc/pam.d/su
    else
        printf 'auth required pam_wheel.so use_uid\n' >> /etc/pam.d/su
    fi
}

audit_5_3_1_1() {
    local prof
    prof="$(head -n1 /etc/authselect/authselect.conf 2>/dev/null || true)"
    [[ "$prof" == custom/* ]] || { CHECK_DETAIL="Active authselect profile is '$prof' (expected custom/*)"; return 1; }
}
fix_5_3_1_1() {
    local base
    base="$(head -n1 /etc/authselect/authselect.conf 2>/dev/null || echo sssd)"
    [[ "$base" == custom/* ]] || {
        authselect create-profile cis-custom -b "${base%% *}" --symlink-meta 2>/dev/null || true
        authselect select custom/cis-custom --force
    }
}
audit_5_3_1_mod() {
    local mod="$1"
    grep -Pq "\b${mod}\.so\b" /etc/pam.d/password-auth /etc/pam.d/system-auth 2>/dev/null || { CHECK_DETAIL="$mod.so not active in PAM"; return 1; }
}
fix_5_3_1_feat() {
    fix_5_3_1_1
    authselect enable-feature "$1"
    authselect apply-changes
}
audit_5_3_2_1_2() {
    local val
    val="$(grep -Phi '^\h*unlock_time\h*=' /etc/security/faillock.conf /etc/security/faillock.conf.d/*.conf 2>/dev/null | tail -n1 | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}')"
    [[ -n "$val" && ( "$val" -eq 0 || "$val" -ge 900 ) ]] 2>/dev/null || { CHECK_DETAIL="unlock_time=$val (expected 0 or >= 900)"; return 1; }
}
audit_flag_file() {
    local f="$1" dir="$2" flag="$3"
    grep -Pqi "^\h*${flag}\b" "$f" "$dir"/*.conf 2>/dev/null || { CHECK_DETAIL="'$flag' not set in $f or $dir/"; return 1; }
}
fix_flag_confd() {
    local dir="$1" file="$2" flag="$3"
    mkdir -p "$dir"
    grep -Pqi "^\h*${flag}\b" "${dir}/${file}" 2>/dev/null || printf '%s\n' "$flag" >> "${dir}/${file}"
}
fix_5_3_2_2_3() {
    local mc=""
    ask_input "Enter minimum password character classes (minclass, 1-4)" "4" mc
    fix_kv_confd /etc/security/pwquality.conf.d 60-cis.conf minclass "$mc"
}
audit_pam_opt() {
    local mod="$1" opt="$2" want="$3"
    if [[ "$want" -eq 1 ]]; then
        grep -Pq "^\h*(auth|account|password|session)\h+\S+\h+${mod}\.so\b" /etc/pam.d/system-auth /etc/pam.d/password-auth 2>/dev/null || return 0
        if grep -P "^\h*(auth|account|password|session)\h+\S+\h+${mod}\.so\b" /etc/pam.d/system-auth /etc/pam.d/password-auth 2>/dev/null | grep -Pvq "\b${opt}\b"; then
            CHECK_DETAIL="$mod.so missing '$opt' in PAM"; return 1
        fi
    else
        if grep -P "^\h*(auth|account|password|session)\h+\S+\h+${mod}\.so\b" /etc/pam.d/system-auth /etc/pam.d/password-auth 2>/dev/null | grep -Pq "\b${opt}\b"; then
            CHECK_DETAIL="$mod.so has disallowed '$opt' in PAM"; return 1
        fi
    fi
    return 0
}
fix_pam_opt() {
    local mod="$1" opt="$2" action="$3"
    fix_5_3_1_1
    local prof_dir="/etc/authselect/$(head -n1 /etc/authselect/authselect.conf)"
    local f
    for f in "${prof_dir}/system-auth" "${prof_dir}/password-auth"; do
        [[ -f "$f" ]] || continue
        if [[ "$action" == "remove" ]]; then
            sed -ri "/${mod}\.so/ s/\s*\b${opt}\b//g" "$f"
        else
            sed -ri "/${mod}\.so/ { /\b${opt}\b/! s/$/ ${opt}/ }" "$f"
        fi
    done
    authselect apply-changes
}

audit_5_4_1_1() {
    local v
    v="$(grep -Pi '^\h*PASS_MAX_DAYS\h+\d+\b' /etc/login.defs 2>/dev/null | awk '{print $2}')"
    [[ -n "$v" && "$v" -gt 0 && "$v" -le 365 ]] || { CHECK_DETAIL="PASS_MAX_DAYS=$v (expected 1..365)"; return 1; }
}
fix_5_4_1_1() {
    sed -ri 's/^\s*PASS_MAX_DAYS\s+.*/PASS_MAX_DAYS 365/' /etc/login.defs
    awk -F: '($3>=1000 && $1!="nobody"){print $1}' /etc/passwd | xargs -r -I{} chage --maxdays 365 {}
}
audit_5_4_1_2() {
    local v
    v="$(grep -Pi '^\h*PASS_MIN_DAYS\h+\d+\b' /etc/login.defs 2>/dev/null | awk '{print $2}')"
    [[ -n "$v" && "$v" -ge 1 ]] || { CHECK_DETAIL="PASS_MIN_DAYS=$v (expected >= 1)"; return 1; }
}
fix_5_4_1_2() {
    local d=""
    ask_input "Enter PASS_MIN_DAYS" "1" d
    sed -ri "s/^\s*PASS_MIN_DAYS\s+.*/PASS_MIN_DAYS $d/" /etc/login.defs
}
audit_5_4_1_3() {
    local v
    v="$(grep -Pi '^\h*PASS_WARN_AGE\h+\d+\b' /etc/login.defs 2>/dev/null | awk '{print $2}')"
    [[ -n "$v" && "$v" -ge 7 ]] || { CHECK_DETAIL="PASS_WARN_AGE=$v (expected >= 7)"; return 1; }
}
fix_5_4_1_3() {
    sed -ri 's/^\s*PASS_WARN_AGE\s+.*/PASS_WARN_AGE 7/' /etc/login.defs
}
audit_5_4_1_4() {
    grep -Piq '^\h*ENCRYPT_METHOD\h+(SHA512|YESCRYPT)\b' /etc/login.defs 2>/dev/null || { CHECK_DETAIL="ENCRYPT_METHOD not SHA512/YESCRYPT in /etc/login.defs"; return 1; }
}
fix_5_4_1_4() {
    local alg=""
    ask_input "Enter ENCRYPT_METHOD (YESCRYPT or SHA512)" "YESCRYPT" alg
    sed -ri "s/^\s*ENCRYPT_METHOD\s+.*/ENCRYPT_METHOD $alg/" /etc/login.defs
}
audit_5_4_1_5() {
    local v
    v="$(useradd -D 2>/dev/null | awk -F= '/^INACTIVE=/{print $2}')"
    [[ -n "$v" && "$v" -ge 0 && "$v" -le 45 ]] || { CHECK_DETAIL="Default INACTIVE=$v (expected 0..45)"; return 1; }
}
fix_5_4_1_5() {
    local d=""
    ask_input "Enter inactive password lock days (0-45)" "45" d
    useradd -D -f "$d"
}
audit_5_4_1_6() {
    require_readable /etc/shadow || return $?
    local u d now
    now="$(date +%s)"
    while IFS= read -r u; do
        d="$(chage --list "$u" 2>/dev/null | awk -F: '/^Last password change/{print $2}')"
        if [[ -n "$d" && "$d" != *"never"* ]]; then
            local ts
            ts="$(date -d "$d" +%s 2>/dev/null || echo 0)"
            if [[ "$ts" -gt "$now" ]]; then
                CHECK_DETAIL="User '$u' has future password change date: $d"; return 1
            fi
        fi
    done < <(awk -F: '($2~/^\$.+\$/){print $1}' /etc/shadow 2>/dev/null)
    return 0
}
audit_5_4_2_1() {
    local bad
    bad="$(awk -F: '($3 == 0 && $1 != "root"){print $1}' /etc/passwd)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="Non-root UID 0 accounts: $bad"; return 1; }
}
audit_5_4_2_2() {
    local bad
    bad="$(awk -F: '($1 !~ /^(root|sync|shutdown|halt|operator)$/ && $4 == 0){print $1}' /etc/passwd)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="Non-root GID 0 accounts: $bad"; return 1; }
}
audit_5_4_2_3() {
    local bad
    bad="$(awk -F: '($3 == 0 && $1 != "root"){print $1}' /etc/group)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="Non-root GID 0 groups: $bad"; return 1; }
}
audit_5_4_2_4() {
    require_readable /etc/shadow || return $?
    passwd -S root 2>/dev/null | awk '$2 ~ /^(P|L)/ {exit 0} {exit 1}' || { CHECK_DETAIL="root account has no password or is unlocked without password"; return 1; }
}
fix_5_4_2_4() {
    local act=""
    ask_input "Lock root account (L) or set root password (P)?" "P" act
    if [[ "${act^^}" == "L" ]]; then
        usermod -L root
    else
        passwd root
    fi
}
audit_5_4_2_5() {
    local p
    for p in $(echo "$PATH" | tr ':' ' '); do
        if [[ -z "$p" || "$p" == "." || ! -d "$p" ]]; then
            CHECK_DETAIL="Invalid/empty/dot entry in root PATH: '$p'"; return 1
        fi
    done
    return 0
}
audit_5_4_2_6() {
    require_readable /root/.bashrc || return $?
    grep -Psiq '^\h*umask\h+0?[027][27]7\b' /root/.bash_profile /root/.bashrc 2>/dev/null || { CHECK_DETAIL="Root umask 027/077 not set in /root/.bash_profile or /root/.bashrc"; return 1; }
}
fix_5_4_2_6() { printf '\numask 027\n' >> /root/.bashrc; }

audit_5_4_2_7() {
    local uid_min bad
    uid_min="$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs)"
    bad="$(awk -F: -v umin="$uid_min" '($1 !~ /^(root|sync|shutdown|halt|nfsnobody)$/ && $3 < umin && $7 !~ /(nologin|false)$/){print $1}' /etc/passwd)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="System accounts with valid shell: $bad"; return 1; }
}
fix_5_4_2_7() {
    local uid_min u nolog
    uid_min="$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs)"
    nolog="$(command -v nologin || echo /sbin/nologin)"
    for u in $(awk -F: -v umin="$uid_min" '($1 !~ /^(root|sync|shutdown|halt|nfsnobody)$/ && $3 < umin && $7 !~ /(nologin|false)$/){print $1}' /etc/passwd); do
        usermod -s "$nolog" "$u"
    done
}
audit_5_4_2_8() {
    require_readable /etc/shadow || return $?
    local bad u
    while IFS= read -r u; do
        if passwd -S "$u" 2>/dev/null | awk '$2 !~ /^L/' | grep -q .; then
            bad+="$u "
        fi
    done < <(awk -F: '($1!="root" && $7 ~ /(nologin|false)$/){print $1}' /etc/passwd)
    [[ -z "$bad" ]] || { CHECK_DETAIL="Unlocked non-login accounts: $bad"; return 1; }
}
fix_5_4_2_8() {
    local u
    while IFS= read -r u; do
        usermod -L "$u" 2>/dev/null || true
    done < <(awk -F: '($1!="root" && $7 ~ /(nologin|false)$/){print $1}' /etc/passwd)
}
audit_5_4_3_1() {
    if grep -Pqs '^\h*([^#\n\r]+)?/nologin\b' /etc/shells 2>/dev/null; then
        CHECK_DETAIL="nologin is listed in /etc/shells"; return 1
    fi
    return 0
}
fix_5_4_3_1() { sed -ri '/\/nologin\b/d' /etc/shells; }
audit_5_4_3_2() {
    grep -Prqs '^\h*(typeset\s+-xr\s+|readonly\s+|export\s+)?TMOUT=(900|[1-8][0-9]{1,2}|[1-9][0-9]?)\b' /etc/profile /etc/profile.d/*.sh /etc/bashrc 2>/dev/null || { CHECK_DETAIL="TMOUT <= 900 not configured in profile/bashrc"; return 1; }
}
fix_5_4_3_2() {
    printf '# CIS TMOUT\ntypeset -xr TMOUT=900\n' > /etc/profile.d/50-tmout.sh
    chmod 0644 /etc/profile.d/50-tmout.sh
}
audit_5_4_3_3() {
    grep -Prqs '^\h*umask\h+0?[027][27]7\b' /etc/profile /etc/profile.d/*.sh /etc/bashrc 2>/dev/null || { CHECK_DETAIL="Default umask 027/077 not configured"; return 1; }
}
fix_5_4_3_3() {
    printf '# CIS umask\numask 027\n' > /etc/profile.d/50-cis-umask.sh
    chmod 0644 /etc/profile.d/50-cis-umask.sh
}

#===============================================================================
# SECTION 6: Logging and Auditing
#===============================================================================
run_section_6() {
    echo -e "\n${C_BOLD}=== Section 6: Logging and Auditing ===${C_RESET}"

    # 6.1 System File Integrity
    run_check "6.1.1" "L1S,L1W" "AUTO" "Ensure AIDE is installed" "audit_pkg_installed aide" "fix_6_1_1" "installing aide and initializing AIDE database"
    run_check "6.1.2" "L1S,L1W" "AUTO" "Ensure filesystem integrity is regularly checked" "audit_6_1_2" "fix_6_1_2" "creating daily aidecheck.timer / cron job"
    run_check "6.1.3" "L2S,L2W" "AUTO" "Ensure cryptographic mechanisms are used to protect the integrity of audit tools" "audit_6_1_3" "fix_6_1_3" "adding audit tools to /etc/aide.conf"

    # 6.2 System Logging
    run_check "6.2.1.1"   "L1S,L1W" "AUTO"   "Ensure journald service is active" "audit_svc_active systemd-journald.service" "fix_svc_enable systemd-journald.service" "enabling and starting systemd-journald.service"
    run_check "6.2.1.2"   "L1S,L1W" "MANUAL" "Ensure journald log file access is configured" "manual_only" "manual_only" "Review journald tmpfiles.d permissions (/usr/lib/tmpfiles.d/systemd.conf)"
    run_check "6.2.1.3"   "L1S,L1W" "MANUAL" "Ensure journald log file rotation is configured" "audit_6_2_1_3" "fix_6_2_1_3" "configuring SystemMaxUse and MaxFileSec in /etc/systemd/journald.conf.d/60-cis.conf" 1
    run_check "6.2.1.4"   "L1S,L1W" "AUTO"   "Ensure only one logging system is in use" "audit_6_2_1_4" "fix_6_2_1_4" "choosing between journald-only or rsyslog" 1
    run_check "6.2.2.1.1" "L1S,L1W" "AUTO"   "Ensure systemd-journal-remote is installed" "audit_pkg_installed systemd-journal-remote" "fix_pkg_installed systemd-journal-remote" "installing systemd-journal-remote"
    run_check "6.2.2.1.2" "L1S,L1W" "MANUAL" "Ensure systemd-journal-upload authentication is configured" "audit_6_2_2_1_2" "fix_6_2_2_1_2" "configuring URL and certificates in /etc/systemd/journal-upload.conf" 1
    run_check "6.2.2.1.3" "L1S,L1W" "AUTO"   "Ensure systemd-journal-upload is enabled and active" "audit_svc_enabled_active systemd-journal-upload.service" "fix_svc_enable systemd-journal-upload.service" "enabling systemd-journal-upload.service"
    run_check "6.2.2.1.4" "L1S,L1W" "AUTO"   "Ensure systemd-journal-remote service is not in use" "audit_svc_disabled systemd-journal-remote systemd-journal-remote.socket systemd-journal-remote.service" "fix_6_2_2_1_4" "stopping and masking systemd-journal-remote"
    run_check "6.2.2.2"   "L1S,L1W" "AUTO"   "Ensure journald ForwardToSyslog is disabled" "audit_journald ForwardToSyslog no" "fix_journald ForwardToSyslog no" "setting ForwardToSyslog=no in journald.conf.d"
    run_check "6.2.2.3"   "L1S,L1W" "AUTO"   "Ensure journald Compress is configured" "audit_journald Compress yes" "fix_journald Compress yes" "setting Compress=yes in journald.conf.d"
    run_check "6.2.2.4"   "L1S,L1W" "AUTO"   "Ensure journald Storage is configured" "audit_journald Storage persistent" "fix_journald Storage persistent" "setting Storage=persistent in journald.conf.d"
    run_check "6.2.3.1"   "L1S,L1W" "AUTO"   "Ensure rsyslog is installed" "audit_pkg_installed rsyslog" "fix_pkg_installed rsyslog" "installing rsyslog"
    run_check "6.2.3.2"   "L1S,L1W" "AUTO"   "Ensure rsyslog service is enabled and active" "audit_svc_enabled_active rsyslog.service" "fix_svc_enable rsyslog.service" "enabling rsyslog.service"
    run_check "6.2.3.3"   "L1S,L1W" "AUTO"   "Ensure journald is configured to send logs to rsyslog" "audit_journald ForwardToSyslog yes" "fix_journald ForwardToSyslog yes" "setting ForwardToSyslog=yes in journald.conf.d"
    run_check "6.2.3.4"   "L1S,L1W" "AUTO"   "Ensure rsyslog log file creation mode is configured" "audit_6_2_3_4" "fix_6_2_3_4" "setting \$FileCreateMode 0640 in /etc/rsyslog.d/60-cis.conf"
    run_check "6.2.3.5"   "L1S,L1W" "MANUAL" "Ensure rsyslog logging is configured" "manual_only" "manual_only" "Review /etc/rsyslog.conf and /etc/rsyslog.d/*.conf against site logging policy"
    run_check "6.2.3.6"   "L1S,L1W" "MANUAL" "Ensure rsyslog is configured to send logs to a remote log host" "audit_6_2_3_6" "fix_6_2_3_6" "configuring remote rsyslog forwarding target" 1
    run_check "6.2.3.7"   "L1S,L1W" "AUTO"   "Ensure rsyslog is not configured to receive logs from a remote client" "audit_6_2_3_7" "fix_6_2_3_7" "disabling imtcp remote log reception in rsyslog"
    run_check "6.2.3.8"   "L1S,L1W" "MANUAL" "Ensure rsyslog logrotate is configured" "manual_only" "manual_only" "Review /etc/logrotate.d/rsyslog against site retention policy"
    run_check "6.2.4.1"   "L1S,L1W" "AUTO"   "Ensure access to all logfiles has been configured" "audit_6_2_4_1" "fix_6_2_4_1" "removing other/group-write permissions on /var/log files"

    # 6.3 System Auditing (auditd)
    run_check "6.3.1.1" "L2S,L2W" "AUTO" "Ensure auditd packages are installed" "audit_6_3_1_1" "fix_6_3_1_1" "installing audit and audit-libs"
    run_check "6.3.1.2" "L2S,L2W" "AUTO" "Ensure auditing for processes that start prior to auditd is enabled" "audit_6_3_1_2" "fix_6_3_1_2" "adding audit=1 to GRUB kernel parameters"
    run_check "6.3.1.3" "L2S,L2W" "AUTO" "Ensure audit_backlog_limit is configured" "audit_6_3_1_3" "fix_6_3_1_3" "adding audit_backlog_limit to GRUB kernel parameters" 1
    run_check "6.3.1.4" "L2S,L2W" "AUTO" "Ensure auditd service is enabled and active" "audit_svc_enabled_active auditd.service" "fix_svc_enable auditd.service" "enabling and starting auditd.service"

    run_check "6.3.2.1" "L2S,L2W" "AUTO" "Ensure audit log storage size is configured" "audit_auditd_conf max_log_file '[1-9][0-9]*'" "fix_6_3_2_1" "setting max_log_file in /etc/audit/auditd.conf" 1
    run_check "6.3.2.2" "L2S,L2W" "AUTO" "Ensure audit logs are not automatically deleted" "audit_auditd_conf max_log_file_action 'keep_logs'" "fix_auditd_conf max_log_file_action keep_logs" "setting max_log_file_action = keep_logs"
    run_check "6.3.2.3" "L2S,L2W" "AUTO" "Ensure system is disabled when audit logs are full" "audit_6_3_2_3" "fix_6_3_2_3" "setting disk_full_action and disk_error_action in auditd.conf" 1
    run_check "6.3.2.4" "L2S,L2W" "AUTO" "Ensure system warns when audit logs are low on space" "audit_6_3_2_4" "fix_auditd_conf space_left_action email" "setting space_left_action = email and admin_space_left_action = halt"

    # 6.3.3 Auditd Rules
    run_check "6.3.3.1"  "L2S,L2W" "AUTO" "Ensure modification of the /etc/sudoers file is collected" "audit_auditd_rule 'path=/etc/sudoers.*key=scope'" "fix_auditd_rule /etc/audit/rules.d/50-scope.rules '-a always,exit -F arch=b64 -S all -F path=/etc/sudoers -F perm=wa -F key=scope' '-a always,exit -F arch=b64 -S all -F dir=/etc/sudoers.d -F perm=wa -F key=scope'" "adding sudoers scope audit rules"
    run_check "6.3.3.2"  "L2S,L2W" "AUTO" "Ensure actions as another user are always logged" "audit_auditd_rule 'euid!=uid.*execve.*user_emulation'" "fix_auditd_rule /etc/audit/rules.d/50-user_emulation.rules '-a always,exit -F arch=b64 -C euid!=uid -F auid!=unset -S execve -k user_emulation'" "adding user_emulation audit rule"
    run_check "6.3.3.3"  "L2S,L2W" "AUTO" "Ensure events that modify the sudo log file are collected" "audit_auditd_rule 'key=sudo_log_file'" "fix_6_3_3_3" "adding sudo log file audit rule"
    run_check "6.3.3.4"  "L2S,L2W" "AUTO" "Ensure events that modify date and time information are collected" "audit_auditd_rule 'time-change'" "fix_auditd_rule /etc/audit/rules.d/50-time-change.rules '-a always,exit -F arch=b64 -S adjtimex,settimeofday -k time-change' '-a always,exit -F arch=b64 -S clock_settime -F a0=0x0 -k time-change' '-a always,exit -F arch=b64 -S all -F path=/etc/localtime -F perm=wa -F key=time-change'" "adding time-change audit rules"
    run_check "6.3.3.5"  "L2S,L2W" "AUTO" "Ensure events that modify sethostname and setdomainname are collected" "audit_auditd_rule 'sethostname,setdomainname.*system-locale'" "fix_auditd_rule /etc/audit/rules.d/50-system_locale.rules '-a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale'" "adding sethostname/setdomainname audit rule"
    run_check "6.3.3.6"  "L2S,L2W" "AUTO" "Ensure events that modify /etc/issue and /etc/issue.net are collected" "audit_auditd_rule 'path=/etc/issue.*system-locale'" "fix_auditd_rule /etc/audit/rules.d/50-etc_issue_system_locale.rules '-a always,exit -F arch=b64 -S all -F path=/etc/issue -F perm=wa -F key=system-locale' '-a always,exit -F arch=b64 -S all -F path=/etc/issue.net -F perm=wa -F key=system-locale'" "adding /etc/issue* audit rules"
    run_check "6.3.3.7"  "L2S,L2W" "AUTO" "Ensure events that modify /etc/hosts and /etc/hostname are collected" "audit_auditd_rule 'path=/etc/hosts.*system-locale'" "fix_auditd_rule /etc/audit/rules.d/50-etc_host_system_locale.rules '-a always,exit -F arch=b64 -S all -F path=/etc/hosts -F perm=wa -F key=system-locale' '-a always,exit -F arch=b64 -S all -F path=/etc/hostname -F perm=wa -F key=system-locale'" "adding /etc/host* audit rules"
    run_check "6.3.3.8"  "L2S,L2W" "AUTO" "Ensure events that modify /etc/sysconfig/network and NetworkManager system-connections are collected" "audit_auditd_rule 'path=/etc/sysconfig/network.*system-locale'" "fix_auditd_rule /etc/audit/rules.d/50-network_system_locale.rules '-a always,exit -F arch=b64 -S all -F path=/etc/sysconfig/network -F perm=wa -F key=system-locale' '-a always,exit -F arch=b64 -S all -F dir=/etc/NetworkManager/system-connections -F perm=wa -F key=system-locale'" "adding network config audit rules"
    run_check "6.3.3.9"  "L2S,L2W" "AUTO" "Ensure events that modify /etc/NetworkManager directory are collected" "audit_auditd_rule 'dir=/etc/NetworkManager/.*system-locale'" "fix_auditd_rule /etc/audit/rules.d/50-nm_system_locale.rules '-a always,exit -F arch=b64 -S all -F dir=/etc/NetworkManager/ -F perm=wa -F key=system-locale'" "adding NetworkManager dir audit rule"
    run_check "6.3.3.10" "L2S,L2W" "AUTO" "Ensure use of privileged commands are collected" "audit_auditd_rule 'key=privileged|-k privileged'" "fix_6_3_3_10" "generating privileged command rules in /etc/audit/rules.d/50-privileged.rules"
    run_check "6.3.3.11" "L2S,L2W" "AUTO" "Ensure unsuccessful file access attempts are collected" "audit_auditd_rule 'exit=-EACCES.*key=access'" "fix_auditd_rule /etc/audit/rules.d/50-access.rules '-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -F key=access' '-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=unset -F key=access'" "adding unsuccessful file access audit rules"
    run_check "6.3.3.12" "L2S,L2W" "AUTO" "Ensure events that modify /etc/group information are collected" "audit_auditd_rule 'path=/etc/group.*identity'" "fix_auditd_rule /etc/audit/rules.d/50-identity.rules '-a always,exit -F arch=b64 -S all -F path=/etc/group -F perm=wa -F key=identity'" "adding /etc/group audit rule"
    run_check "6.3.3.13" "L2S,L2W" "AUTO" "Ensure events that modify /etc/passwd information are collected" "audit_auditd_rule 'path=/etc/passwd.*identity'" "fix_auditd_rule /etc/audit/rules.d/50-identity.rules '-a always,exit -F arch=b64 -S all -F path=/etc/passwd -F perm=wa -F key=identity'" "adding /etc/passwd audit rule"
    run_check "6.3.3.14" "L2S,L2W" "AUTO" "Ensure events that modify /etc/shadow and /etc/gshadow are collected" "audit_auditd_rule 'path=/etc/shadow.*identity'" "fix_auditd_rule /etc/audit/rules.d/50-identity.rules '-a always,exit -F arch=b64 -S all -F path=/etc/gshadow -F perm=wa -F key=identity' '-a always,exit -F arch=b64 -S all -F path=/etc/shadow -F perm=wa -F key=identity'" "adding /etc/shadow and /etc/gshadow audit rules"
    run_check "6.3.3.15" "L2S,L2W" "AUTO" "Ensure events that modify /etc/security/opasswd are collected" "audit_auditd_rule 'path=/etc/security/opasswd.*identity'" "fix_auditd_rule /etc/audit/rules.d/50-identity.rules '-a always,exit -F arch=b64 -S all -F path=/etc/security/opasswd -F perm=wa -F key=identity'" "adding /etc/security/opasswd audit rule"
    run_check "6.3.3.16" "L2S,L2W" "AUTO" "Ensure events that modify /etc/nsswitch.conf file are collected" "audit_auditd_rule 'path=/etc/nsswitch\.conf.*identity'" "fix_auditd_rule /etc/audit/rules.d/50-identity.rules '-a always,exit -F arch=b64 -S all -F path=/etc/nsswitch.conf -F perm=wa -F key=identity'" "adding /etc/nsswitch.conf audit rule"
    run_check "6.3.3.17" "L2S,L2W" "AUTO" "Ensure events that modify /etc/pam.conf and /etc/pam.d/ information are collected" "audit_auditd_rule 'dir=/etc/pam\.d.*identity'" "fix_auditd_rule /etc/audit/rules.d/50-identity.rules '-a always,exit -F arch=b64 -S all -F path=/etc/pam.conf -F perm=wa -F key=identity' '-a always,exit -F arch=b64 -S all -F dir=/etc/pam.d -F perm=wa -F key=identity'" "adding PAM audit rules"
    run_check "6.3.3.18" "L2S,L2W" "AUTO" "Ensure discretionary access control permission modification events chmod* are collected" "audit_auditd_rule 'chmod,fchmod,fchmodat.*perm_mod'" "fix_auditd_rule /etc/audit/rules.d/50-perm_mod.rules '-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat,fchmodat2 -F auid>=1000 -F auid!=unset -F key=perm_mod'" "adding chmod perm_mod audit rule"
    run_check "6.3.3.19" "L2S,L2W" "AUTO" "Ensure discretionary access control permission modification events chown* are collected" "audit_auditd_rule 'chown,fchown,lchown,fchownat.*perm_mod'" "fix_auditd_rule /etc/audit/rules.d/50-perm_mod.rules '-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -F key=perm_mod'" "adding chown perm_mod audit rule"
    run_check "6.3.3.20" "L2S,L2W" "MANUAL" "Ensure discretionary access control permission modification events *xattr are collected" "audit_auditd_rule 'setxattr.*perm_mod'" "fix_auditd_rule /etc/audit/rules.d/50-perm_mod.rules '-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -F key=perm_mod'" "adding *xattr perm_mod audit rule"
    run_check "6.3.3.21" "L2S,L2W" "AUTO" "Ensure successful file system mounts are collected" "audit_auditd_rule '-S mount.*mounts'" "fix_auditd_rule /etc/audit/rules.d/50-mounts.rules '-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=unset -k mounts'" "adding mount audit rule"
    run_check "6.3.3.22" "L2S,L2W" "AUTO" "Ensure session initiation information is collected" "audit_auditd_rule 'path=/var/run/utmp.*session'" "fix_auditd_rule /etc/audit/rules.d/50-session.rules '-a always,exit -F arch=b64 -S all -F path=/var/run/utmp -F perm=wa -F key=session' '-a always,exit -F arch=b64 -S all -F path=/var/log/wtmp -F perm=wa -F key=session' '-a always,exit -F arch=b64 -S all -F path=/var/log/btmp -F perm=wa -F key=session'" "adding session utmp/wtmp/btmp audit rules"
    run_check "6.3.3.23" "L2S,L2W" "AUTO" "Ensure login and logout events are collected" "audit_auditd_rule 'path=/var/log/lastlog.*logins'" "fix_auditd_rule /etc/audit/rules.d/50-logins.rules '-a always,exit -F arch=b64 -S all -F path=/var/log/lastlog -F perm=wa -F key=logins' '-a always,exit -F arch=b64 -S all -F path=/var/run/faillock -F perm=wa -F key=logins'" "adding login/logout audit rules"
    run_check "6.3.3.24" "L2S,L2W" "AUTO" "Ensure unlink file deletion events by users are collected" "audit_auditd_rule 'unlink,unlinkat.*delete'" "fix_auditd_rule /etc/audit/rules.d/50-delete.rules '-a always,exit -F arch=b64 -S unlink,unlinkat -F auid>=1000 -F auid!=unset -F key=delete'" "adding unlink file deletion audit rule"
    run_check "6.3.3.25" "L2S,L2W" "AUTO" "Ensure rename file deletion events by users are collected" "audit_auditd_rule 'rename,renameat,renameat2.*delete'" "fix_auditd_rule /etc/audit/rules.d/50-delete.rules '-a always,exit -F arch=b64 -S rename,renameat,renameat2 -F auid>=1000 -F auid!=unset -F key=delete'" "adding rename file deletion audit rule"
    run_check "6.3.3.26" "L2S,L2W" "AUTO" "Ensure events that modify the system's Mandatory Access Controls are collected" "audit_auditd_rule 'path=/etc/selinux.*MAC-policy'" "fix_auditd_rule /etc/audit/rules.d/50-MAC-policy.rules '-a always,exit -F arch=b64 -S all -F path=/etc/selinux -F perm=wa -F key=MAC-policy' '-a always,exit -F arch=b64 -S all -F path=/usr/share/selinux -F perm=wa -F key=MAC-policy'" "adding SELinux MAC-policy audit rules"
    run_check "6.3.3.27" "L2S,L2W" "AUTO" "Ensure successful and unsuccessful attempts to use the chcon command are collected" "audit_auditd_rule 'path=/usr/bin/chcon.*perm_chng'" "fix_auditd_rule /etc/audit/rules.d/50-perm_chng.rules '-a always,exit -F arch=b64 -S all -F path=/usr/bin/chcon -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng'" "adding chcon audit rule"
    run_check "6.3.3.28" "L2S,L2W" "AUTO" "Ensure successful and unsuccessful attempts to use the setfacl command are collected" "audit_auditd_rule 'path=/usr/bin/setfacl.*perm_chng'" "fix_auditd_rule /etc/audit/rules.d/50-perm_chng.rules '-a always,exit -F arch=b64 -S all -F path=/usr/bin/setfacl -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng'" "adding setfacl audit rule"
    run_check "6.3.3.29" "L2S,L2W" "AUTO" "Ensure successful and unsuccessful attempts to use the chacl command are collected" "audit_auditd_rule 'path=/usr/bin/chacl.*perm_chng'" "fix_auditd_rule /etc/audit/rules.d/50-perm_chng.rules '-a always,exit -F arch=b64 -S all -F path=/usr/bin/chacl -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng'" "adding chacl audit rule"
    run_check "6.3.3.30" "L2S,L2W" "AUTO" "Ensure successful and unsuccessful attempts to use the usermod command are collected" "audit_auditd_rule 'path=/usr/sbin/usermod.*usermod'" "fix_auditd_rule /etc/audit/rules.d/50-usermod.rules '-a always,exit -F arch=b64 -S all -F path=/usr/sbin/usermod -F perm=x -F auid>=1000 -F auid!=unset -k usermod'" "adding usermod audit rule"
    run_check "6.3.3.31" "L2S,L2W" "AUTO" "Ensure kernel module loading unloading and modification is collected" "audit_auditd_rule 'path=/usr/bin/kmod.*kernel_modules'" "fix_auditd_rule /etc/audit/rules.d/50-kernel_modules.rules '-a always,exit -F arch=b64 -S all -F path=/usr/bin/kmod -F perm=x -F auid>=1000 -F auid!=unset -k kernel_modules'" "adding kmod audit rule"
    run_check "6.3.3.32" "L2S,L2W" "AUTO" "Ensure kernel init_module and finit_module loading unloading and modification is collected" "audit_auditd_rule 'init_module,finit_module.*kernel_modules'" "fix_auditd_rule /etc/audit/rules.d/50-kernel_modules.rules '-a always,exit -F arch=b64 -S init_module,finit_module -F auid>=1000 -F auid!=unset -k kernel_modules'" "adding init_module/finit_module audit rule"
    run_check "6.3.3.33" "L2S,L2W" "AUTO" "Ensure kernel delete_module loading unloading and modification is collected" "audit_auditd_rule 'delete_module.*kernel_modules'" "fix_auditd_rule /etc/audit/rules.d/50-kernel_modules.rules '-a always,exit -F arch=b64 -S delete_module -F auid>=1000 -F auid!=unset -k kernel_modules'" "adding delete_module audit rule"
    run_check "6.3.3.34" "L2S,L2W" "AUTO" "Ensure kernel query_module loading unloading and modification is collected" "audit_auditd_rule 'query_module.*kernel_modules'" "fix_auditd_rule /etc/audit/rules.d/50-kernel_modules.rules '-a always,exit -F arch=b64 -S query_module -F auid>=1000 -F auid!=unset -k kernel_modules'" "adding query_module audit rule"
    run_check "6.3.3.35" "L2S,L2W" "AUTO" "Ensure the audit configuration is loaded regardless of errors" "audit_auditd_rule '^\h*-c\b'" "fix_auditd_rule /etc/audit/rules.d/01-initialize.rules '-c'" "adding -c to /etc/audit/rules.d/01-initialize.rules"
    run_check "6.3.3.36" "L2S,L2W" "AUTO" "Ensure the audit configuration is immutable" "audit_auditd_rule '^\h*-e\h+2\b'" "fix_auditd_rule /etc/audit/rules.d/99-finalize.rules '-e 2'" "adding -e 2 to /etc/audit/rules.d/99-finalize.rules"
    run_check "6.3.3.37" "L2S,L2W" "MANUAL" "Ensure the running and on disk configuration is the same" "audit_6_3_3_37" "fix_6_3_3_37" "running augenrules --load"

    # 6.3.4 Auditd File Access
    run_check "6.3.4.1"  "L2S,L2W" "AUTO" "Ensure the audit log file directory mode is configured" "audit_6_3_4_dir" "fix_6_3_4_dir" "setting mode <= 0750 on audit log directory"
    run_check "6.3.4.2"  "L2S,L2W" "AUTO" "Ensure audit log files mode is configured" "audit_6_3_4_logs mode" "fix_6_3_4_logs mode" "setting mode <= 0600 on audit log files"
    run_check "6.3.4.3"  "L2S,L2W" "AUTO" "Ensure audit log files owner is configured" "audit_6_3_4_logs owner" "fix_6_3_4_logs owner" "setting owner root on audit log files"
    run_check "6.3.4.4"  "L2S,L2W" "AUTO" "Ensure audit log files group owner is configured" "audit_6_3_4_logs group" "fix_6_3_4_logs group" "setting group root on audit log files"
    run_check "6.3.4.5"  "L2S,L2W" "AUTO" "Ensure audit configuration files mode is configured" "audit_6_3_4_conf mode" "fix_6_3_4_conf mode" "setting mode <= 0640 on /etc/audit/*.conf and *.rules"
    run_check "6.3.4.6"  "L2S,L2W" "AUTO" "Ensure audit configuration files owner is configured" "audit_6_3_4_conf owner" "fix_6_3_4_conf owner" "setting owner root on /etc/audit/*.conf and *.rules"
    run_check "6.3.4.7"  "L2S,L2W" "AUTO" "Ensure audit configuration files group owner is configured" "audit_6_3_4_conf group" "fix_6_3_4_conf group" "setting group root on /etc/audit/*.conf and *.rules"
    run_check "6.3.4.8"  "L2S,L2W" "AUTO" "Ensure audit tools mode is configured" "audit_6_3_4_tools mode" "fix_6_3_4_tools mode" "setting mode 0755 on audit tools"
    run_check "6.3.4.9"  "L2S,L2W" "AUTO" "Ensure audit tools owner is configured" "audit_6_3_4_tools owner" "fix_6_3_4_tools owner" "setting owner root on audit tools"
    run_check "6.3.4.10" "L2S,L2W" "AUTO" "Ensure audit tools group owner is configured" "audit_6_3_4_tools group" "fix_6_3_4_tools group" "setting group root on audit tools"
}

# --- Section 6 Implementations ------------------------------------------------
fix_6_1_1() {
    dnf -y install aide
    echo "  Initializing AIDE database (this may take a few minutes)..."
    aide --init && mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
}
audit_6_1_2() {
    if systemctl is-enabled aidecheck.timer 2>/dev/null | grep -q '^enabled' || \
       grep -Prqs 'aide.*--(check|update)' /etc/cron* /var/spool/cron/ 2>/dev/null; then
        return 0
    fi
    CHECK_DETAIL="No scheduled AIDE check timer or cron job found."
    return 1
}
fix_6_1_2() {
    cat > /etc/systemd/system/aidecheck.service <<'EOF'
[Unit]
Description=Aide Check
[Service]
Type=simple
ExecStart=/usr/sbin/aide --check
EOF
    cat > /etc/systemd/system/aidecheck.timer <<'EOF'
[Unit]
Description=Aide check every day at 5AM
[Timer]
OnCalendar=*-*-* 05:00:00
Unit=aidecheck.service
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl --now enable aidecheck.timer
}
audit_6_1_3() {
    [[ -f /etc/aide.conf ]] || { CHECK_DETAIL="/etc/aide.conf missing"; return 1; }
    local t
    for t in auditctl auditd ausearch aureport autrace augenrules; do
        if ! grep -Pqs "/s?bin/${t}\b" /etc/aide.conf; then
            CHECK_DETAIL="Audit tool $t not monitored in /etc/aide.conf"; return 1
        fi
    done
    return 0
}
fix_6_1_3() {
    cat >> /etc/aide.conf <<'EOF'
# CIS Audit Tools Integrity
/sbin/auditctl p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/auditd p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/ausearch p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/aureport p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/autrace p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/augenrules p+i+n+u+g+s+b+acl+xattrs+sha512
EOF
}

audit_svc_active() {
    systemctl is-active "$1" 2>/dev/null | grep -q '^active' || { CHECK_DETAIL="$1 is not active"; return 1; }
}
audit_svc_enabled_active() {
    systemctl is-enabled "$1" 2>/dev/null | grep -q '^enabled' && systemctl is-active "$1" 2>/dev/null | grep -q '^active' || { CHECK_DETAIL="$1 is not enabled and active"; return 1; }
}
fix_svc_enable() {
    systemctl unmask "$1" 2>/dev/null || true
    systemctl --now enable "$1"
}

audit_6_2_1_3() {
    require_cmd systemd-analyze || return $?
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -Pqi '^\h*SystemMaxUse\h*=' || { CHECK_DETAIL="SystemMaxUse not configured in journald.conf"; return 1; }
}
fix_6_2_1_3() {
    local mu="" ms=""
    ask_input "Enter journald SystemMaxUse (e.g. 1G)" "1G" mu
    ask_input "Enter journald MaxFileSec (e.g. 1month)" "1month" ms
    fix_journald "SystemMaxUse" "$mu"
    fix_journald "MaxFileSec" "$ms"
}
audit_6_2_1_4() {
    local j_act=0 r_act=0
    systemctl is-active systemd-journald.service >/dev/null 2>&1 && j_act=1
    systemctl is-active rsyslog.service >/dev/null 2>&1 && r_act=1
    if [[ "$j_act" -eq 1 && "$r_act" -eq 1 ]]; then
        CHECK_DETAIL="Both systemd-journald and rsyslog are active (CIS recommends one primary logging system)."; return 1
    elif [[ "$j_act" -eq 0 && "$r_act" -eq 0 ]]; then
        CHECK_DETAIL="Neither systemd-journald nor rsyslog is active."; return 1
    fi
    return 0
}
fix_6_2_1_4() {
    local choice=""
    ask_input "Choose primary logging system (journald or rsyslog)" "journald" choice
    if [[ "$choice" == "journald" ]]; then
        systemctl disable --now rsyslog.service 2>/dev/null || true
        fix_svc_enable systemd-journald.service
    else
        fix_svc_enable rsyslog.service
    fi
}
audit_6_2_2_1_2() {
    grep -Pqs '^\h*URL\h*=\h*\S+' /etc/systemd/journal-upload.conf 2>/dev/null || { CHECK_DETAIL="URL not set in /etc/systemd/journal-upload.conf"; return 1; }
}
fix_6_2_2_1_2() {
    local url=""
    ask_input "Enter journal-upload remote URL (e.g. https://loghost.example.com)" "" url
    [[ -n "$url" ]] && {
        sed -ri '/^\s*URL\s*=/d' /etc/systemd/journal-upload.conf
        printf 'URL=%s\n' "$url" >> /etc/systemd/journal-upload.conf
        systemctl restart systemd-journal-upload.service 2>/dev/null || true
    }
}
fix_6_2_2_1_4() {
    systemctl stop systemd-journal-remote.socket systemd-journal-remote.service 2>/dev/null || true
    systemctl mask systemd-journal-remote.socket systemd-journal-remote.service 2>/dev/null || true
}
audit_journald() {
    local key="$1" val="$2"
    require_cmd systemd-analyze || return $?
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -Pqi "^\h*${key}\h*=\h*${val}\b" || { CHECK_DETAIL="journald $key != $val"; return 1; }
}
fix_journald() {
    local key="$1" val="$2"
    mkdir -p /etc/systemd/journald.conf.d
    grep -qs '^\[Journal\]' /etc/systemd/journald.conf.d/60-cis.conf || printf '[Journal]\n' > /etc/systemd/journald.conf.d/60-cis.conf
    sed -ri "/^\s*${key}\s*=/Id" /etc/systemd/journald.conf.d/60-cis.conf
    printf '%s=%s\n' "$key" "$val" >> /etc/systemd/journald.conf.d/60-cis.conf
    systemctl restart systemd-journald.service 2>/dev/null || true
}
audit_6_2_3_4() {
    grep -Prqs '^\h*\$FileCreateMode\h+0[0246][024]0\b' /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null || { CHECK_DETAIL="rsyslog \$FileCreateMode 0640 not set"; return 1; }
}
fix_6_2_3_4() {
    mkdir -p /etc/rsyslog.d
    printf '$FileCreateMode 0640\n' > /etc/rsyslog.d/60-cis.conf
    systemctl restart rsyslog 2>/dev/null || true
}
audit_6_2_3_6() {
    grep -Prqs '(^\*+\.\*\s+@@|type="omfwd")' /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null || { CHECK_DETAIL="No remote rsyslog host configured"; return 1; }
}
fix_6_2_3_6() {
    local host="" port=""
    ask_input "Enter remote rsyslog server hostname/IP" "loghost.example.com" host
    ask_input "Enter remote rsyslog TCP port" "514" port
    mkdir -p /etc/rsyslog.d
    printf '*.* action(type="omfwd" target="%s" port="%s" protocol="tcp" action.resumeRetryCount="100" queue.type="LinkedList" queue.size="1000")\n' "$host" "$port" > /etc/rsyslog.d/60-remote.conf
    systemctl restart rsyslog 2>/dev/null || true
}
audit_6_2_3_7() {
    if grep -Prqi '^\h*(module\(load="?imtcp"?|\$ModLoad\h+imtcp)' /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null; then
        CHECK_DETAIL="rsyslog imtcp module enabled (accepting remote logs)."; return 1
    fi
    return 0
}
fix_6_2_3_7() {
    grep -rl 'imtcp' /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null | xargs -r sed -ri '/imtcp/s/^/# /'
    systemctl restart rsyslog 2>/dev/null || true
}
audit_6_2_4_1() {
    local bad
    bad="$(find /var/log -type f -perm /0137 2>/dev/null | head -n5)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="Log files with overly permissive mode found under /var/log"; return 1; }
}
fix_6_2_4_1() {
    find /var/log -type f -perm /0137 -exec chmod u-x,g-wx,o-rwx {} + 2>/dev/null || true
}

audit_6_3_1_1() { audit_pkg_installed audit && audit_pkg_installed audit-libs; }
fix_6_3_1_1() { dnf -y install audit audit-libs; }
audit_6_3_1_2() { require_cmd grubby || return $?; grubby --info=ALL 2>/dev/null | grep -Pq '\baudit=1\b' || { CHECK_DETAIL="audit=1 not set in GRUB"; return 1; }; }
fix_6_3_1_2() { grubby --update-kernel ALL --args 'audit=1'; }
audit_6_3_1_3() { require_cmd grubby || return $?; grubby --info=ALL 2>/dev/null | grep -Pq '\baudit_backlog_limit=\d+\b' || { CHECK_DETAIL="audit_backlog_limit not set in GRUB"; return 1; }; }
fix_6_3_1_3() {
    local bl=""
    ask_input "Enter audit_backlog_limit" "8192" bl
    grubby --update-kernel ALL --args "audit_backlog_limit=${bl}"
}
fix_6_3_2_1() {
    local mb=""
    ask_input "Enter audit max_log_file size in MB" "32" mb
    fix_auditd_conf max_log_file "$mb"
}
audit_6_3_2_3() {
    audit_auditd_conf disk_full_action '(halt|single)' && audit_auditd_conf disk_error_action '(syslog|single|halt)'
}
fix_6_3_2_3() {
    local df="" de=""
    ask_input "Enter disk_full_action (halt or single)" "halt" df
    ask_input "Enter disk_error_action (syslog, single, or halt)" "halt" de
    fix_auditd_conf disk_full_action "$df"
    fix_auditd_conf disk_error_action "$de"
}
audit_6_3_2_4() {
    audit_auditd_conf space_left_action '(email|exec|single|halt)' && audit_auditd_conf admin_space_left_action '(single|halt)'
}
fix_6_3_3_3() {
    local lf
    lf="$(grep -rPho '^\h*Defaults\h+([^#\n\r]+,\h*)?logfile\h*=\h*"?\K[^"\s]+' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | head -n1 || echo /var/log/sudo.log)"
    fix_auditd_rule /etc/audit/rules.d/50-sudo.rules "-a always,exit -F arch=b64 -S all -F path=${lf} -F perm=wa -F key=sudo_log_file"
}
fix_6_3_3_10() {
    local uid_min part
    uid_min="$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs)"
    mkdir -p /etc/audit/rules.d
    : > /etc/audit/rules.d/50-privileged.rules
    for part in $(findmnt -n -l -k -it "$(awk '/nodev/{print $2}' /proc/filesystems | paste -sd,)" | grep -Pv 'noexec|nosuid' | awk '{print $1}'); do
        find "$part" -xdev -perm /6000 -type f 2>/dev/null | awk -v u="$uid_min" '{print "-a always,exit -F arch=b64 -S all -F path="$1" -F perm=x -F auid>="u" -F auid!=unset -k privileged"}' >> /etc/audit/rules.d/50-privileged.rules
    done
    sort -u -o /etc/audit/rules.d/50-privileged.rules /etc/audit/rules.d/50-privileged.rules
    augenrules --load >/dev/null 2>&1 || true
}
audit_6_3_3_37() {
    require_cmd augenrules || return $?
    require_root || return $?
    if augenrules --check 2>&1 | grep -q "No change"; then
        return 0
    fi
    CHECK_DETAIL="Running auditd rules differ from on-disk /etc/audit/rules.d/."
    return 1
}
fix_6_3_3_37() { augenrules --load; }

audit_6_3_4_dir() {
    local d
    d="$(dirname "$(awk -F= '/^\s*log_file\s*=/{print $2}' /etc/audit/auditd.conf 2>/dev/null | xargs)" 2>/dev/null || echo /var/log/audit)"
    [[ -d "$d" ]] && find "$d" -maxdepth 0 -perm /0027 | grep -q . && { CHECK_DETAIL="Audit log dir $d has mode > 0750"; return 1; }
    return 0
}
fix_6_3_4_dir() {
    local d
    d="$(dirname "$(awk -F= '/^\s*log_file\s*=/{print $2}' /etc/audit/auditd.conf 2>/dev/null | xargs)" 2>/dev/null || echo /var/log/audit)"
    chmod g-w,o-rwx "$d"
}
audit_6_3_4_logs() {
    local what="$1" d
    d="$(dirname "$(awk -F= '/^\s*log_file\s*=/{print $2}' /etc/audit/auditd.conf 2>/dev/null | xargs)" 2>/dev/null || echo /var/log/audit)"
    [[ -d "$d" ]] || return 0
    case "$what" in
        mode)  find "$d" -type f -perm /0177 | grep -q . && { CHECK_DETAIL="Audit log files with mode > 0600"; return 1; } ;;
        owner) find "$d" -type f ! -user root | grep -q . && { CHECK_DETAIL="Audit log files not owned by root"; return 1; } ;;
        group) find "$d" -type f ! -group root | grep -q . && { CHECK_DETAIL="Audit log files not group-owned by root"; return 1; } ;;
    esac
    return 0
}
fix_6_3_4_logs() {
    local what="$1" d
    d="$(dirname "$(awk -F= '/^\s*log_file\s*=/{print $2}' /etc/audit/auditd.conf 2>/dev/null | xargs)" 2>/dev/null || echo /var/log/audit)"
    case "$what" in
        mode)  find "$d" -type f -exec chmod u-x,g-wx,o-rwx {} + ;;
        owner) find "$d" -type f -exec chown root {} + ;;
        group) find "$d" -type f -exec chgrp root {} + ;;
    esac
}
audit_6_3_4_conf() {
    local what="$1"
    case "$what" in
        mode)  find /etc/audit/ -type f \( -name '*.conf' -o -name '*.rules' \) -perm /0137 2>/dev/null | grep -q . && { CHECK_DETAIL="/etc/audit config files with mode > 0640"; return 1; } ;;
        owner) find /etc/audit/ -type f \( -name '*.conf' -o -name '*.rules' \) ! -user root 2>/dev/null | grep -q . && { CHECK_DETAIL="/etc/audit config files not owned by root"; return 1; } ;;
        group) find /etc/audit/ -type f \( -name '*.conf' -o -name '*.rules' \) ! -group root 2>/dev/null | grep -q . && { CHECK_DETAIL="/etc/audit config files not group-owned by root"; return 1; } ;;
    esac
    return 0
}
fix_6_3_4_conf() {
    local what="$1"
    case "$what" in
        mode)  find /etc/audit/ -type f \( -name '*.conf' -o -name '*.rules' \) -exec chmod u-x,g-wx,o-rwx {} + ;;
        owner) find /etc/audit/ -type f \( -name '*.conf' -o -name '*.rules' \) -exec chown root {} + ;;
        group) find /etc/audit/ -type f \( -name '*.conf' -o -name '*.rules' \) -exec chgrp root {} + ;;
    esac
}
audit_6_3_4_tools() {
    local what="$1" t
    for t in /sbin/auditctl /sbin/aureport /sbin/ausearch /sbin/autrace /sbin/auditd /sbin/augenrules; do
        [[ -e "$t" ]] || continue
        case "$what" in
            mode)  [[ -n "$(find -L "$t" -perm /0022 2>/dev/null)" ]] && { CHECK_DETAIL="$t writable by group/other"; return 1; } ;;
            owner) [[ "$(stat -Lc '%U' "$t")" != "root" ]] && { CHECK_DETAIL="$t not owned by root"; return 1; } ;;
            group) [[ "$(stat -Lc '%G' "$t")" != "root" ]] && { CHECK_DETAIL="$t not group root"; return 1; } ;;
        esac
    done
    return 0
}
fix_6_3_4_tools() {
    local what="$1"
    for t in /sbin/auditctl /sbin/aureport /sbin/ausearch /sbin/autrace /sbin/auditd /sbin/augenrules; do
        [[ -e "$t" ]] || continue
        case "$what" in
            mode)  chmod go-w "$t" ;;
            owner) chown root "$t" ;;
            group) chgrp root "$t" ;;
        esac
    done
}

#===============================================================================
# SECTION 7: System Maintenance
#===============================================================================
run_section_7() {
    echo -e "\n${C_BOLD}=== Section 7: System Maintenance ===${C_RESET}"

    # 7.1 System File Permissions
    run_check "7.1.1"  "L1S,L1W" "AUTO" "Ensure access to /etc/passwd is configured"  "audit_file_access /etc/passwd '0?[0246][04][04]' root root"   "fix_file_access /etc/passwd 0644 root root"   "setting 0644 root:root on /etc/passwd"
    run_check "7.1.2"  "L1S,L1W" "AUTO" "Ensure access to /etc/passwd- is configured" "audit_file_access /etc/passwd- '0?[0246][04][04]' root root 1" "fix_file_access /etc/passwd- 0644 root root" "setting 0644 root:root on /etc/passwd-"
    run_check "7.1.3"  "L1S,L1W" "AUTO" "Ensure access to /etc/group is configured"   "audit_file_access /etc/group '0?[0246][04][04]' root root"    "fix_file_access /etc/group 0644 root root"    "setting 0644 root:root on /etc/group"
    run_check "7.1.4"  "L1S,L1W" "AUTO" "Ensure access to /etc/group- is configured"  "audit_file_access /etc/group- '0?[0246][04][04]' root root 1" "fix_file_access /etc/group- 0644 root root"  "setting 0644 root:root on /etc/group-"
    run_check "7.1.5"  "L1S,L1W" "AUTO" "Ensure access to /etc/shadow is configured"  "audit_file_access /etc/shadow '0?000' root '(root|shadow)'"    "fix_file_access /etc/shadow 0000 root root"   "setting 0000 root:root on /etc/shadow"
    run_check "7.1.6"  "L1S,L1W" "AUTO" "Ensure access to /etc/shadow- is configured" "audit_file_access /etc/shadow- '0?000' root '(root|shadow)' 1" "fix_file_access /etc/shadow- 0000 root root" "setting 0000 root:root on /etc/shadow-"
    run_check "7.1.7"  "L1S,L1W" "AUTO" "Ensure access to /etc/gshadow is configured" "audit_file_access /etc/gshadow '0?000' root '(root|shadow)'"   "fix_file_access /etc/gshadow 0000 root root"  "setting 0000 root:root on /etc/gshadow"
    run_check "7.1.8"  "L1S,L1W" "AUTO" "Ensure access to /etc/gshadow- is configured" "audit_file_access /etc/gshadow- '0?000' root '(root|shadow)' 1" "fix_file_access /etc/gshadow- 0000 root root" "setting 0000 root:root on /etc/gshadow-"
    run_check "7.1.9"  "L1S,L1W" "AUTO" "Ensure access to /etc/shells is configured"  "audit_file_access /etc/shells '0?[0246][04][04]' root root"   "fix_file_access /etc/shells 0644 root root"   "setting 0644 root:root on /etc/shells"
    run_check "7.1.10" "L1S,L1W" "AUTO" "Ensure access to /etc/security/opasswd is configured" "audit_file_access /etc/security/opasswd '0?[0246]00' root root 1" "fix_file_access /etc/security/opasswd 0600 root root" "setting 0600 root:root on /etc/security/opasswd"

    run_check "7.1.11" "L1S,L1W" "AUTO"   "Ensure world writable files and directories are secured" "audit_7_1_11" "fix_7_1_11" "removing world-write on files and setting sticky bit on world-writable dirs"
    run_check "7.1.12" "L1S,L1W" "AUTO"   "Ensure no files or directories without an owner and a group exist" "audit_7_1_12" "fix_7_1_12" "assigning owner/group to unowned files" 1
    run_check "7.1.13" "L1S,L1W" "MANUAL" "Ensure SUID and SGID files are reviewed" "manual_only" "manual_only" "Review SUID/SGID files via 'find / -xdev -type f \\( -perm -4000 -o -perm -2000 \\)'"

    # 7.2 Local User and Group Settings
    run_check "7.2.1" "L1S,L1W" "AUTO" "Ensure accounts in /etc/passwd use shadowed passwords" "audit_7_2_1" "fix_7_2_1" "running pwconv"
    run_check "7.2.2" "L1S,L1W" "AUTO" "Ensure /etc/shadow password fields are not empty" "audit_7_2_2" "fix_7_2_2" "locking accounts with empty shadow passwords"
    run_check "7.2.3" "L1S,L1W" "AUTO" "Ensure all groups in /etc/passwd exist in /etc/group" "audit_7_2_3" "manual_only" "Investigate and add missing GIDs to /etc/group or update /etc/passwd"
    run_check "7.2.4" "L1S,L1W" "AUTO" "Ensure no duplicate UIDs exist" "audit_dup /etc/passwd 3 UID" "manual_only" "Resolve duplicate UIDs in /etc/passwd"
    run_check "7.2.5" "L1S,L1W" "AUTO" "Ensure no duplicate GIDs exist" "audit_dup /etc/group 3 GID" "manual_only" "Resolve duplicate GIDs in /etc/group"
    run_check "7.2.6" "L1S,L1W" "AUTO" "Ensure no duplicate user names exist" "audit_dup /etc/passwd 1 username" "manual_only" "Resolve duplicate usernames in /etc/passwd"
    run_check "7.2.7" "L1S,L1W" "AUTO" "Ensure no duplicate group names exist" "audit_dup /etc/group 1 groupname" "manual_only" "Resolve duplicate group names in /etc/group"
    run_check "7.2.8" "L1S,L1W" "AUTO" "Ensure local interactive user home directories are configured" "audit_7_2_8" "fix_7_2_8" "creating/securing local interactive user home directories"
    run_check "7.2.9" "L1S,L1W" "AUTO" "Ensure local interactive user dot files access is configured" "audit_7_2_9" "fix_7_2_9" "removing group/other write permissions on user dot files"
}

# --- Section 7 Implementations ------------------------------------------------
audit_7_1_11() {
    local bad_f bad_d
    bad_f="$(find / -xdev -type f -perm -0002 ! -path '/proc/*' ! -path '/sys/*' 2>/dev/null | head -n5)"
    bad_d="$(find / -xdev -type d -perm -0002 ! -perm -1000 ! -path '/proc/*' ! -path '/sys/*' 2>/dev/null | head -n5)"
    [[ -z "$bad_f" && -z "$bad_d" ]] || { CHECK_DETAIL="Found world-writable files or directories without sticky bit"; return 1; }
}
fix_7_1_11() {
    find / -xdev -type f -perm -0002 ! -path '/proc/*' ! -path '/sys/*' -exec chmod o-w {} + 2>/dev/null || true
    find / -xdev -type d -perm -0002 ! -perm -1000 ! -path '/proc/*' ! -path '/sys/*' -exec chmod a+t {} + 2>/dev/null || true
}
audit_7_1_12() {
    local bad
    bad="$(find / -xdev \( -nouser -o -nogroup \) ! -path '/proc/*' ! -path '/sys/*' 2>/dev/null | head -n5)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="Unowned files/dirs exist (e.g. $bad)"; return 1; }
}
fix_7_1_12() {
    local owner=""
    ask_input "Enter owner:group to assign to unowned files" "root:root" owner
    find / -xdev \( -nouser -o -nogroup \) ! -path '/proc/*' ! -path '/sys/*' -exec chown "$owner" {} + 2>/dev/null || true
}
audit_7_2_1() {
    local bad
    bad="$(awk -F: '($2 != "x"){print $1}' /etc/passwd)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="Non-shadowed accounts: $bad"; return 1; }
}
fix_7_2_1() { pwconv; }
audit_7_2_2() {
    require_readable /etc/shadow || return $?
    local bad
    bad="$(awk -F: '($2 == ""){print $1}' /etc/shadow 2>/dev/null)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="Empty password fields in /etc/shadow for: $bad"; return 1; }
}
fix_7_2_2() {
    local u
    for u in $(awk -F: '($2 == ""){print $1}' /etc/shadow 2>/dev/null); do
        passwd -l "$u"
    done
}
audit_7_2_3() {
    local gid
    for gid in $(cut -d: -f4 /etc/passwd | sort -u); do
        if ! grep -q "^[^:]*:[^:]*:${gid}:" /etc/group; then
            CHECK_DETAIL="GID $gid in /etc/passwd does not exist in /etc/group"; return 1
        fi
    done
    return 0
}
audit_dup() {
    local file="$1" col="$2" label="$3" bad
    bad="$(cut -d: -f"$col" "$file" | sort | uniq -d)"
    [[ -z "$bad" ]] || { CHECK_DETAIL="Duplicate $label in $file: $bad"; return 1; }
}
audit_7_2_8() {
    local u h
    while IFS=: read -r u _ uid _ _ h sh; do
        [[ "$uid" -ge 1000 && "$u" != "nobody" && "$sh" != *"nologin" && "$sh" != *"false" ]] || continue
        if [[ ! -d "$h" ]]; then
            CHECK_DETAIL="Home directory '$h' for user '$u' does not exist"; return 1
        fi
        if find "$h" -maxdepth 0 \( ! -user "$u" -o -perm /0027 \) 2>/dev/null | grep -q .; then
            CHECK_DETAIL="Home directory '$h' has wrong owner or mode > 0750"; return 1
        fi
    done < /etc/passwd
    return 0
}
fix_7_2_8() {
    local u g h
    while IFS=: read -r u _ uid gid _ h sh; do
        [[ "$uid" -ge 1000 && "$u" != "nobody" && "$sh" != *"nologin" && "$sh" != *"false" ]] || continue
        [[ -d "$h" ]] || { mkdir -p "$h"; cp -rn /etc/skel/. "$h"/ 2>/dev/null || true; }
        chown "${u}:${gid}" "$h"
        chmod 0750 "$h"
    done < /etc/passwd
}
audit_7_2_9() {
    local u h
    while IFS=: read -r u _ uid _ _ h sh; do
        [[ "$uid" -ge 1000 && "$u" != "nobody" && "$sh" != *"nologin" && "$sh" != *"false" && -d "$h" ]] || continue
        if find "$h" -maxdepth 1 -name '.*' -type f -perm /0022 2>/dev/null | grep -q .; then
            CHECK_DETAIL="User '$u' has group/world-writable dot files in $h"; return 1
        fi
    done < /etc/passwd
    return 0
}
fix_7_2_9() {
    local u h
    while IFS=: read -r u _ uid _ _ h sh; do
        [[ "$uid" -ge 1000 && "$u" != "nobody" && "$sh" != *"nologin" && "$sh" != *"false" && -d "$h" ]] || continue
        find "$h" -maxdepth 1 -name '.*' -type f -perm /0022 -exec chmod go-w {} + 2>/dev/null || true
    done < /etc/passwd
}

#===============================================================================
# Main Entry Point
#===============================================================================
main() {
    echo "==============================================================================="
    echo " CIS Oracle Linux 10 Benchmark v1.0.0 - Audit & Interactive Remediation"
    echo "==============================================================================="
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${C_YELLOW}[WARN] Not running as root. Some checks and all remediations require root.${C_RESET}"
    fi
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo " Hostname : $(hostname)"
        echo " OS       : ${PRETTY_NAME:-Unknown}"
        echo " Log File : ${LOG_FILE}"
        if [[ "${ID:-}" != "ol" && "${ID:-}" != "oracle" ]]; then
            echo -e "${C_YELLOW}[WARN] Detected OS '${ID:-unknown}' (script targets Oracle Linux 10).${C_RESET}"
        fi
    fi

    log_msg "=== Starting CIS OL10 Benchmark Run (level=$FILTER_LEVEL section=$FILTER_SECTION id=$FILTER_ID) ==="

    run_section_1
    run_section_2
    run_section_3
    run_section_4
    run_section_5
    run_section_6
    run_section_7

    print_summary
}

main
