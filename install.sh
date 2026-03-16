#!/bin/bash
set -euo pipefail

# Pop!_OS fixes for ASUS ROG Zephyrus G16 (2025)
# Intel Core Ultra 285H + NVIDIA RTX 5070 Ti

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

confirm() {
    read -rp "    Apply this change? [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]]
}

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo ./install.sh)"
    exit 1
fi

if ! command -v kernelstub &>/dev/null; then
    error "kernelstub not found. This script is designed for Pop!_OS."
    exit 1
fi

echo ""
echo "================================================"
echo "  Pop!_OS Fixes for ASUS ROG Zephyrus G16 2025"
echo "================================================"
echo ""
echo "This script will apply boot, sleep, and NVIDIA"
echo "fixes. Each change will be shown before applying."
echo ""

CHANGES_MADE=false
NEED_INITRAMFS=false

# --- BIOS Check ---
echo ""
warn "BIOS PREREQUISITE"
echo "    Intel VMD must be DISABLED in BIOS (Advanced menu)."
echo "    VMD causes PCIe bus errors that hang reboots, restarts, and sleep."
echo ""
read -rp "    Is Intel VMD disabled in your BIOS? [y/N] " vmd_response
if [[ ! "$vmd_response" =~ ^[Yy]$ ]]; then
    error "Please disable Intel VMD in BIOS first, then re-run this script."
    exit 1
fi

# --- OEM Kernel ---
echo ""
info "OEM KERNEL (Arrow Lake hardware support)"
echo ""

CURRENT_KERNEL=$(uname -r)
KERNEL_MAJOR=$(echo "$CURRENT_KERNEL" | cut -d. -f1-2)

# Check if kernel is 6.11+ (has Arrow Lake support)
if dpkg -l | grep -q "linux-image-oem-24.04"; then
    OEM_PKG=$(dpkg -l | grep "linux-image-oem-24.04" | grep "^ii" | awk '{print $2}' | head -1)
    info "$OEM_PKG already installed (skipping)"
elif awk 'BEGIN{exit !('"$KERNEL_MAJOR"' >= 6.11)}'; then
    info "Kernel $CURRENT_KERNEL already has Arrow Lake support (skipping OEM kernel)"
else
    warn "Install OEM kernel for Arrow Lake hardware support"
    echo "    Pop!_OS ships with a kernel that predates Arrow Lake."
    echo "    The OEM kernel (6.17+) adds proper hardware support."
    echo "    Current kernel: $CURRENT_KERNEL"
    echo ""
    if confirm; then
        apt install -y linux-image-oem-24.04d
        # Find the installed OEM kernel version
        OEM_VER=$(ls /lib/modules/ | grep oem | sort -V | tail -1)
        if [[ -n "$OEM_VER" ]]; then
            kernelstub -k "/boot/vmlinuz-${OEM_VER}" -i "/boot/initrd.img-${OEM_VER}"
            info "Installed OEM kernel $OEM_VER and registered with kernelstub"
            echo ""
            warn "You should reboot into the OEM kernel before continuing."
            echo "    Run this script again after reboot to apply remaining fixes."
            read -rp "    Reboot now? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                reboot
            fi
        fi
        CHANGES_MADE=true
    fi
fi

# --- NVIDIA Driver ---
echo ""
info "NVIDIA DRIVER (open kernel modules required for RTX 50 series)"
echo ""

if dpkg -l | grep -q "nvidia-driver-.*-open"; then
    NVIDIA_PKG=$(dpkg -l | grep "nvidia-driver-.*-open" | awk '{print $2}' | head -1)
    info "$NVIDIA_PKG already installed (skipping)"
else
    warn "Install NVIDIA open kernel module driver"
    echo "    RTX 50 series (Blackwell) REQUIRES the -open variant."
    echo "    The proprietary driver will not work."
    echo ""
    # Find the best available open driver
    BEST_OPEN=$(apt-cache search nvidia-driver | grep -oP 'nvidia-driver-\d+-open' | sort -t- -k3 -n | tail -1)
    if [[ -n "$BEST_OPEN" ]]; then
        echo "    Best available package: $BEST_OPEN"
        if confirm; then
            apt install -y "$BEST_OPEN"
            info "Installed $BEST_OPEN"
            CHANGES_MADE=true
        fi
    else
        error "No nvidia-driver-*-open package found in repos."
        echo "    You may need to add the graphics-drivers PPA or update your package lists."
    fi
fi

# --- Speaker Firmware ---
echo ""
info "SPEAKER FIRMWARE (CS35L56 amplifier fix)"
echo ""

FW_DIR="/lib/firmware/cirrus"
if [[ -L "$FW_DIR/cs35l56-b0-dsp1-misc-10431034-spkid0-amp1.bin" ]]; then
    info "Speaker firmware symlinks already exist (skipping)"
elif [[ ! -d "$FW_DIR" ]]; then
    warn "Firmware directory $FW_DIR not found, skipping speaker fix"
    echo "    Install linux-firmware first, then re-run this script."
else
    warn "Create firmware symlinks for CS35L56 amplifier (subsystem 10431034)"
    echo "    Without this fix, speakers are silent or have no bass."
    echo "    Symlinks 10431034 -> 10431044 (compatible ASUS model)"
    if confirm; then
        bash "$SCRIPT_DIR/configs/fix-speakers.sh"
        CHANGES_MADE=true
    fi
fi

# --- Kernel Parameters ---
echo ""
info "KERNEL PARAMETERS"
echo ""

KERNEL_PARAMS=(
    "pci=noaer|Suppress PCIe Advanced Error Reporting"
    "pcie_aspm=off|Disable PCIe Active State Power Management (fixes sleep/resume)"
    "nvme_core.default_ps_max_latency_us=0|Disable NVMe power state transitions (fixes hangs)"
    "nvme_core.io_timeout=4|Reduce NVMe I/O timeout from 30s to 4s"
    "reboot=efi|Clean EFI reboot behavior"
    "i915.enable_dpcd_backlight=3|Intel display backlight control via DPCD"
    "loglevel=4|Kernel log verbosity"
    "systemd.show_status=true|Show service status during boot"
)

CURRENT_PARAMS=$(kernelstub -p 2>/dev/null || cat /etc/kernelstub/configuration)

for entry in "${KERNEL_PARAMS[@]}"; do
    param="${entry%%|*}"
    desc="${entry##*|}"

    if echo "$CURRENT_PARAMS" | grep -q "$param"; then
        info "$param  (already set, skipping)"
    else
        warn "$param"
        echo "    $desc"
        if confirm; then
            kernelstub -a "$param"
            info "Added $param"
            CHANGES_MADE=true
        fi
    fi
done

# --- Initramfs Modules ---
echo ""
info "INITRAMFS MODULES (MEI for i915 GSC proxy fix)"
echo ""

MEI_MODULES=("mei" "mei_me" "mei_gsc_proxy")
MODULES_FILE="/etc/initramfs-tools/modules"
NEED_MEI=false

for mod in "${MEI_MODULES[@]}"; do
    if ! grep -q "^${mod}$" "$MODULES_FILE" 2>/dev/null; then
        NEED_MEI=true
        break
    fi
done

if $NEED_MEI; then
    warn "Add mei, mei_me, mei_gsc_proxy to initramfs"
    echo "    Prevents 17 second i915 GSC proxy timeout during boot"
    if confirm; then
        echo "" >> "$MODULES_FILE"
        cat "$SCRIPT_DIR/configs/initramfs-modules.txt" >> "$MODULES_FILE"
        info "MEI modules added to $MODULES_FILE"
        CHANGES_MADE=true
    fi
else
    info "MEI modules already in initramfs (skipping)"
fi

# --- Systemd Drop-ins ---
echo ""
info "SYSTEMD DROP-INS"
echo ""

# cosmic-greeter nvidia wait
GREETER_DIR="/etc/systemd/system/cosmic-greeter.service.d"
GREETER_CONF="$GREETER_DIR/nvidia-wait.conf"

if [[ -f "$GREETER_CONF" ]]; then
    info "cosmic-greeter nvidia-wait drop-in already exists (skipping)"
else
    warn "cosmic-greeter: wait for NVIDIA before starting login screen"
    echo "    Prevents greeter hang when GPU is not ready"
    echo ""
    echo "    NOTE: The config sets COSMIC_RENDER_DEVICE=/dev/dri/card1."
    echo "    Check your system with: ls -la /dev/dri/by-path/"
    echo "    You may need to change card1 to card0 depending on your setup."
    echo ""
    if confirm; then
        mkdir -p "$GREETER_DIR"
        cp "$SCRIPT_DIR/configs/cosmic-greeter-nvidia-wait.conf" "$GREETER_CONF"
        info "Installed $GREETER_CONF"
        CHANGES_MADE=true
    fi
fi

# nvidia-persistenced override
PERSIST_DIR="/etc/systemd/system/nvidia-persistenced.service.d"
PERSIST_CONF="$PERSIST_DIR/override.conf"

if [[ -f "$PERSIST_CONF" ]]; then
    info "nvidia-persistenced override already exists (skipping)"
else
    warn "nvidia-persistenced: add retry logic and wait for /dev/nvidia0"
    echo "    Ensures GPU persistence daemon recovers from failures"
    if confirm; then
        mkdir -p "$PERSIST_DIR"
        cp "$SCRIPT_DIR/configs/nvidia-persistenced-override.conf" "$PERSIST_CONF"
        info "Installed $PERSIST_CONF"
        CHANGES_MADE=true
    fi
fi

# --- Disable Unused Services ---
echo ""
info "DISABLE UNUSED SERVICES"
echo ""

SERVICES=(
    "grub-common.service|Pop!_OS uses systemd-boot, not GRUB"
    "grub-initrd-fallback.service|Pop!_OS uses systemd-boot, not GRUB"
    "libvirt-guests.service|Only needed if running VMs with libvirt"
    "acct.service|Process accounting, not needed for desktop use"
)

for entry in "${SERVICES[@]}"; do
    svc="${entry%%|*}"
    desc="${entry##*|}"

    if ! systemctl is-enabled "$svc" &>/dev/null; then
        info "$svc  (already disabled or not present, skipping)"
    elif [[ "$(systemctl is-enabled "$svc" 2>/dev/null)" == "disabled" ]]; then
        info "$svc  (already disabled, skipping)"
    else
        warn "Disable $svc"
        echo "    $desc"
        if confirm; then
            systemctl disable "$svc"
            info "Disabled $svc"
            CHANGES_MADE=true
        fi
    fi
done

# --- Finalize ---
echo ""

if $CHANGES_MADE; then
    info "FINALIZING"
    echo ""

    # Rebuild initramfs if MEI modules were added
    if $NEED_MEI && grep -q "^mei$" "$MODULES_FILE"; then
        info "Rebuilding initramfs..."
        update-initramfs -u
        info "Initramfs rebuilt"
    fi

    # Reload systemd
    systemctl daemon-reload
    info "Systemd daemon reloaded"

    echo ""
    info "All changes applied. Reboot to take effect."
    echo ""
    read -rp "    Reboot now? [y/N] " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        reboot
    fi
else
    info "No changes were made."
fi
