#!/usr/bin/env bash
# ==============================================================================
# Linux USB Audio "Sticky Mixer" Fixer
#
# Diagnoses and permanently fixes the common Linux ALSA issue where Type-C
# or USB earphones/DACs are recognized and show as connected, but produce
# NO sound (silent audio output) due to the kernel's "sticky mixer" bug.
#
# Repository: https://github.com/Adams-404/linux-usb-audio-fix
# License: MIT
# ==============================================================================

set -eo pipefail

VERSION="1.0.0"
CONFIG_FILE="/etc/modprobe.d/usb-audio-quirk.conf"
LEGACY_CONFIG="/etc/modprobe.d/huawei-audio.conf"

# Text Styling
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Symbols
CHECK="${GREEN}✔${NC}"
CROSS="${RED}✖${NC}"
INFO="${BLUE}ℹ${NC}"
WARN="${YELLOW}⚠${NC}"

# Script Modes
MODE="fix"
ASSUME_YES=false
VERBOSE=false
MANUAL_DEV=""

print_banner() {
    cat << "EOF"
  _      _                     _    _ ____  ____     _             _ _       
 | |    (_)_ __  _   ___  __  | |  | / ___|| __ )   / \  _   _  __| (_) ___  
 | |    | | '_ \| | | \ \/ /  | |  | \___ \|  _ \  / _ \| | | |/ _` | |/ _ \ 
 | |___ | | | | | |_| |>  <   | |__| |___) | |_) |/ ___ \ |_| | (_| | | (_) |
 |_____||_|_| |_|\__,_/_/\_\   \____/|____/|____//_/   \_\\__,_|\__,_|_|\___/ 
                       Linux USB Audio Auto-Fixer
EOF
    echo -e "       ${CYAN}Diagnose & fix silent USB Type-C earphones on Linux (v${VERSION})${NC}\n"
}

usage() {
    print_banner
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 [options]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -c, --check          Inspect and diagnose USB audio devices without making changes"
    echo "  -y, --yes            Automatically apply fixes without prompting for confirmation"
    echo "  -r, --revert         Remove applied audio quirks and restore system default settings"
    echo "  -d, --device VID:PID Manually specify target USB device VID:PID (e.g. 12d1:3a06)"
    echo "  -v, --verbose        Show detailed diagnostic and debugging output"
    echo "  -h, --help           Display this help message and exit"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                   # Detect issues and fix interactively"
    echo "  $0 --check           # Check if your earphones suffer from this bug"
    echo "  $0 -y                # Run in non-interactive / automated mode"
    echo "  $0 --revert          # Revert all changes cleanly"
    exit 0
}

log_info() { echo -e "${INFO} $1"; }
log_ok()   { echo -e "${CHECK} $1"; }
log_warn() { echo -e "${WARN} ${YELLOW}$1${NC}"; }
log_err()  { echo -e "${CROSS} ${RED}$1${NC}"; }

check_deps() {
    local missing=()
    for cmd in lsusb awk grep; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_err "Missing required dependencies: ${missing[*]}"
        echo "Please install them using your package manager (e.g., sudo dnf install usbutils alsa-utils)"
        exit 1
    fi
}

# Require sudo for commands modifying the system
ensure_sudo() {
    if [ "$EUID" -ne 0 ]; then
        if ! sudo -v; then
            log_err "Root privileges (sudo) are required to apply or revert system quirks."
            exit 1
        fi
    fi
}

# Find all USB audio devices present in the system
find_usb_audio_devices() {
    local dev_list=()

    # Search through sysfs sound cards
    for card_dir in /sys/class/sound/card[0-9]*; do
        [ -e "$card_dir" ] || continue
        local c_num="${card_dir##*/card}"
        local dev_link
        dev_link=$(readlink -f "$card_dir/device" 2>/dev/null || true)

        if [[ "$dev_link" == *"usb"* ]]; then
            local cur="$dev_link"
            local vid="" pid="" bus_dev="" mfr="" prod=""
            
            while [ -n "$cur" ] && [ "$cur" != "/" ]; do
                if [ -f "$cur/idVendor" ] && [ -f "$cur/idProduct" ]; then
                    vid=$(cat "$cur/idVendor" 2>/dev/null || true)
                    pid=$(cat "$cur/idProduct" 2>/dev/null || true)
                    bus_dev=$(basename "$cur")
                    mfr=$(cat "$cur/manufacturer" 2>/dev/null || true)
                    prod=$(cat "$cur/product" 2>/dev/null || true)
                    break
                fi
                cur=$(dirname "$cur")
            done

            if [ -n "$vid" ] && [ -n "$pid" ]; then
                dev_list+=("$vid:$pid|$c_num|$bus_dev|$mfr|$prod")
            fi
        fi
    done

    # Fallback to lsusb if sysfs sound card not yet probed
    if [ ${#dev_list[@]} -eq 0 ]; then
        while IFS= read -r line; do
            local vid_pid desc
            vid_pid=$(echo "$line" | awk '{print $6}')
            desc=$(echo "$line" | cut -d' ' -f7-)
            local v="${vid_pid%%:*}"
            local p="${vid_pid##*:}"
            if [[ "$desc" =~ (Audio|Sound|Headset|Earphone|DAC) ]]; then
                dev_list+=("$v:$p|unknown|unknown|unknown|$desc")
            fi
        done < <(lsusb 2>/dev/null || true)
    fi

    echo "${dev_list[@]}"
}

# Check if a specific VID:PID or USB port experienced the sticky mixer bug
check_sticky_mixer_bug() {
    local vid_pid="$1"
    local bus_dev="$2"
    local c_num="$3"
    local has_quirk_configured=false
    local has_pvolume=false
    local has_log_warning=false
    local reason=""

    # Check if a quirk configuration already exists for this device
    if grep -rsq "$vid_pid.*MIXER_GET_CUR_BROKEN" /etc/modprobe.d/ 2>/dev/null; then
        has_quirk_configured=true
    fi

    # Check if kernel logs recorded sticky mixer
    if journalctl -b 0 --no-pager 2>/dev/null | grep -iE "(sticky mixer values.*disabling|check MIXER_GET_CUR_BROKEN)" | grep -q -i -E "($vid_pid|$bus_dev|audio|usb)"; then
        has_log_warning=true
    fi

    # Check ALSA mixer controls
    if [ "$c_num" != "unknown" ] && command -v amixer >/dev/null 2>&1; then
        local scontents
        scontents=$(amixer -c "$c_num" scontents 2>/dev/null || true)
        if echo "$scontents" | grep -A 5 "Simple mixer control 'PCM'" | grep -q "pvolume"; then
            has_pvolume=true
        fi
    fi

    if [ "$has_quirk_configured" = true ] && [ "$has_pvolume" = true ]; then
        echo "fixed|Quirk is configured and hardware playback volume control is active."
    elif [ "$has_pvolume" = false ] && ([ "$has_log_warning" = true ] || [ "$has_quirk_configured" = false ]); then
        echo "buggy|Hardware volume control disabled/missing (sticky mixer bug in firmware)."
    elif [ "$has_log_warning" = true ] && [ "$has_quirk_configured" = false ]; then
        echo "buggy|Kernel logs reported sticky mixer values disabling audio mixer."
    else
        echo "healthy|Device mixer is operational."
    fi
}

do_check() {
    print_banner
    log_info "Scanning for connected USB Audio devices..."
    
    local devices
    read -r -a devices <<< "$(find_usb_audio_devices)"

    if [ ${#devices[@]} -eq 0 ]; then
        log_warn "No USB Audio devices detected."
        echo "Please ensure your Type-C / USB earphones are securely plugged in."
        exit 0
    fi

    local found_bugs=0

    for dev in "${devices[@]}"; do
        IFS='|' read -r vid_pid c_num bus_dev mfr prod <<< "$dev"
        echo ""
        echo -e "${BOLD}Device ID:${NC}     ${CYAN}${vid_pid}${NC}"
        echo -e "${BOLD}Product:${NC}       ${prod:-Unknown} (${mfr:-Unknown})"
        echo -e "${BOLD}ALSA Card:${NC}     card${c_num}"
        echo -e "${BOLD}USB Bus Path:${NC}  ${bus_dev}"

        local bug_status
        bug_status=$(check_sticky_mixer_bug "$vid_pid" "$bus_dev" "$c_num")
        local status_type="${bug_status%%|*}"
        local status_msg="${bug_status##*|}"

        if [ "$status_type" = "buggy" ]; then
            log_err "AFFECTED BY STICKY MIXER BUG!"
            echo -e "   ${YELLOW}Details: ${status_msg}${NC}"
            echo -e "   ${YELLOW}Symptom: Connected and recognized, but outputs total silence.${NC}"
            found_bugs=$((found_bugs + 1))
        elif [ "$status_type" = "fixed" ]; then
            log_ok "ALREADY FIXED: ${status_msg}"
        else
            log_ok "Healthy: ${status_msg}"
        fi
    done

    echo ""
    if [ $found_bugs -gt 0 ]; then
        log_warn "Found $found_bugs USB device(s) suffering from the silent audio bug."
        echo "Run './fix.sh' to automatically fix this issue."
        exit 1
    else
        log_ok "All connected USB audio devices are operational."
        exit 0
    fi
}

do_revert() {
    print_banner
    log_info "Reverting all USB audio quirks..."
    ensure_sudo

    local removed=false

    if [ -f "$CONFIG_FILE" ]; then
        sudo rm -f "$CONFIG_FILE"
        log_ok "Removed $CONFIG_FILE"
        removed=true
    fi

    if [ -f "$LEGACY_CONFIG" ]; then
        sudo rm -f "$LEGACY_CONFIG"
        log_ok "Removed legacy config $LEGACY_CONFIG"
        removed=true
    fi

    # Clear sysfs parameter if available
    if [ -w "/sys/module/snd_usb_audio/parameters/quirk_flags" ]; then
        echo "" | sudo tee /sys/module/snd_usb_audio/parameters/quirk_flags >/dev/null 2>&1 || true
    fi

    # Reset USB audio devices
    local devices
    read -r -a devices <<< "$(find_usb_audio_devices)"
    for dev in "${devices[@]}"; do
        IFS='|' read -r vid_pid c_num bus_dev mfr prod <<< "$dev"
        if [ "$bus_dev" != "unknown" ] && [ -f "/sys/bus/usb/devices/$bus_dev/authorized" ]; then
            log_info "Re-enumerating USB device $bus_dev ($vid_pid)..."
            sudo sh -c "echo 0 > /sys/bus/usb/devices/$bus_dev/authorized && sleep 1 && echo 1 > /sys/bus/usb/devices/$bus_dev/authorized" 2>/dev/null || true
        fi
    done

    echo ""
    if [ "$removed" = true ]; then
        log_ok "System successfully restored to default configuration."
    else
        log_info "No custom quirk configuration files were found. System is already in default state."
    fi
}

do_fix() {
    print_banner
    check_deps
    log_info "Scanning for connected USB Audio devices..."

    local devices
    read -r -a devices <<< "$(find_usb_audio_devices)"

    local target_vid_pid=""
    local target_bus_dev=""
    local target_prod=""
    local target_c_num=""

    if [ -n "$MANUAL_DEV" ]; then
        target_vid_pid="$MANUAL_DEV"
        target_prod="Manual specified device"
        log_info "Using manually specified device ID: $target_vid_pid"
    else
        if [ ${#devices[@]} -eq 0 ]; then
            log_err "No USB Audio devices detected."
            echo "Please plug in your Type-C / USB earphones and run this script again."
            exit 1
        fi

        # Find buggy devices
        local buggy_devices=()
        local fixed_devices=()
        for dev in "${devices[@]}"; do
            IFS='|' read -r vid_pid c_num bus_dev mfr prod <<< "$dev"
            local bug_status
            bug_status=$(check_sticky_mixer_bug "$vid_pid" "$bus_dev" "$c_num")
            local status_type="${bug_status%%|*}"
            if [ "$status_type" = "buggy" ]; then
                buggy_devices+=("$dev")
            elif [ "$status_type" = "fixed" ]; then
                fixed_devices+=("$dev")
            fi
        done

        if [ ${#buggy_devices[@]} -ge 1 ]; then
            IFS='|' read -r target_vid_pid target_c_num target_bus_dev mfr prod <<< "${buggy_devices[0]}"
            target_prod="${prod:-Unknown} (${mfr:-Unknown})"
        elif [ ${#fixed_devices[@]} -ge 1 ]; then
            IFS='|' read -r target_vid_pid target_c_num target_bus_dev mfr prod <<< "${fixed_devices[0]}"
            target_prod="${prod:-Unknown} (${mfr:-Unknown})"
            log_ok "Device ${BOLD}${target_prod}${NC} (${CYAN}${target_vid_pid}${NC}) is already fixed and active!"
            if [ "$ASSUME_YES" = false ]; then
                read -r -p "Re-apply quirk configuration and re-enumerate anyway? [y/N] " ans
                case "$ans" in
                    [yY][eE][sS]|[yY]) ;;
                    *)
                        log_info "No action needed. Exiting."
                        exit 0
                        ;;
                esac
            fi
        else
            # Check if any USB device is present
            log_warn "Kernel logs did not explicitly flag an error, but a USB audio device was found:"
            IFS='|' read -r target_vid_pid target_c_num target_bus_dev mfr prod <<< "${devices[0]}"
            target_prod="${prod:-Unknown} (${mfr:-Unknown})"
            echo -e "   Target: ${BOLD}${target_prod}${NC} (${CYAN}${target_vid_pid}${NC})"
        fi
    fi

    echo ""
    echo -e "${BOLD}Target Device:${NC}  ${CYAN}${target_vid_pid}${NC} (${target_prod})"
    if [ -n "$target_bus_dev" ] && [ "$target_bus_dev" != "unknown" ]; then
        echo -e "${BOLD}USB Bus Path:${NC}   ${target_bus_dev}"
    fi

    if [ "$ASSUME_YES" = false ]; then
        echo ""
        read -r -p "Apply persistent kernel quirk for this device? [Y/n] " answer
        case "$answer" in
            [nN][oO]|[nN])
                log_info "Operation cancelled by user."
                exit 0
                ;;
        esac
    fi

    echo ""
    ensure_sudo

    # 1. Write persistent modprobe file
    log_info "Saving permanent configuration to $CONFIG_FILE..."
    sudo sh -c "cat << 'EOF' > $CONFIG_FILE
# Generated by linux-usb-audio-fix
# Fixes ALSA 'sticky mixer values' bug causing silent playback on Type-C / USB audio devices
options snd-usb-audio quirk_flags=${target_vid_pid}:MIXER_GET_CUR_BROKEN
EOF"
    log_ok "Configuration file written."

    # 2. Apply dynamically via sysfs parameter if available
    if [ -w "/sys/module/snd_usb_audio/parameters/quirk_flags" ]; then
        log_info "Applying quirk to active kernel driver module..."
        echo "${target_vid_pid}:MIXER_GET_CUR_BROKEN" | sudo tee /sys/module/snd_usb_audio/parameters/quirk_flags >/dev/null 2>&1 || true
    fi

    # 3. Re-enumerate the device immediately so changes take effect without rebooting
    if [ -n "$target_bus_dev" ] && [ "$target_bus_dev" != "unknown" ] && [ -f "/sys/bus/usb/devices/$target_bus_dev/authorized" ]; then
        log_info "Re-enumerating USB device $target_bus_dev to initialize hardware mixer..."
        sudo sh -c "echo 0 > /sys/bus/usb/devices/$target_bus_dev/authorized && sleep 1 && echo 1 > /sys/bus/usb/devices/$target_bus_dev/authorized"
        sleep 1
    fi

    # 4. Set volume to audible level and test
    log_info "Setting default output volume and unmuting..."
    if command -v wpctl >/dev/null 2>&1; then
        wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || true
        wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.70 2>/dev/null || true
    elif command -v pactl >/dev/null 2>&1; then
        pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true
        pactl set-sink-volume @DEFAULT_SINK@ 70% 2>/dev/null || true
    fi

    echo ""
    log_ok "${GREEN}${BOLD}FIX APPLIED SUCCESSFULLY!${NC}"
    echo -e "   • Configuration saved to: ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "   • This fix is ${BOLD}permanent${NC} and will persist across reboots & kernel updates."
    echo -e "   • Volume has been set to 70%."

    # Play test sound if available
    local sound_file="/usr/share/sounds/freedesktop/stereo/bell.oga"
    [ -f "$sound_file" ] || sound_file="/usr/share/sounds/alsa/Front_Center.wav"

    if [ -f "$sound_file" ]; then
        echo ""
        log_info "Playing test chime through earphones..."
        if command -v pw-play >/dev/null 2>&1; then
            pw-play "$sound_file" 2>/dev/null || true
        elif command -v paplay >/dev/null 2>&1; then
            paplay "$sound_file" 2>/dev/null || true
        elif command -v aplay >/dev/null 2>&1; then
            aplay -q "$sound_file" 2>/dev/null || true
        fi
    fi

    echo ""
    log_info "If you ever wish to revert this fix, simply run:"
    echo "   $0 --revert"
}

# Parse Command Line Options
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--check)
            MODE="check"
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -r|--revert)
            MODE="revert"
            shift
            ;;
        -d|--device)
            if [ -z "$2" ]; then
                log_err "--device requires a VID:PID argument (e.g., 12d1:3a06)"
                exit 1
            fi
            MANUAL_DEV="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_err "Unknown option: $1"
            echo "Use '$0 --help' for usage."
            exit 1
            ;;
    esac
done

case "$MODE" in
    check)  do_check ;;
    revert) do_revert ;;
    fix)    do_fix ;;
esac
