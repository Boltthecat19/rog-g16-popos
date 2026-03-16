# Pop!_OS on ASUS ROG Zephyrus G16 (2025)

Fixes for boot, sleep/suspend, and NVIDIA issues on the 2025 ASUS ROG Zephyrus G16 running Pop!_OS.

**Tested hardware:**
- ASUS ROG Zephyrus G16 (2025)
- Intel Core Ultra 285H (Meteor Lake)
- NVIDIA RTX 5070 Ti
- Micron 3500 NVMe

**What this fixes:**
- Boot time reduced from ~60 seconds to ~4 seconds
- Sleep/suspend (lid close/open) works reliably
- OEM kernel for Arrow Lake hardware support
- NVIDIA RTX 5070 Ti (SM120) driver setup with open kernel modules
- NVIDIA greeter race condition (login screen hang)
- i915 GSC proxy 17 second boot timeout
- NVMe power state transition hangs
- Speakers silent/no bass (CS35L56 amplifier firmware missing)

## Before You Start: BIOS Settings

**Disable Intel VMD** in BIOS before installing Pop!_OS:

1. Boot into BIOS (press F2 or DEL during POST)
2. Go to **Advanced** settings
3. Find **Intel VMD** (Volume Management Device) and **disable** it
4. Save and exit

This is critical. With VMD enabled, the system will experience PCIe bus errors that cause hangs during reboots, restarts, and sleep/wake cycles. VMD is designed for Intel RAID configurations and conflicts with how Linux handles NVMe directly.

## Quick Start

```bash
git clone https://github.com/Boltthecat19/rog-g16-popos.git
cd rog-g16-popos
chmod +x install.sh
sudo ./install.sh
```

The install script is interactive. It will show you each change before applying it and ask for confirmation.

## What Gets Changed

### OEM Kernel

Pop!_OS ships with a kernel that predates Arrow Lake (Intel Core Ultra 200) support. The stock kernel will have missing or broken drivers for various hardware on this laptop. You need to install the OEM kernel:

```bash
sudo apt install linux-image-oem-24.04d
```

At time of writing this installs kernel 6.17.0-1009-oem or newer. After installing, register it with kernelstub so Pop!_OS creates a boot entry for it:

```bash
sudo kernelstub -k /boot/vmlinuz-$(ls /lib/modules/ | grep oem | sort -V | tail -1) \
                -i /boot/initrd.img-$(ls /lib/modules/ | grep oem | sort -V | tail -1)
```

Pop!_OS does not automatically create boot entries for OEM kernels, so this step is required. Reboot and verify with `uname -r` that you are running the OEM kernel before proceeding with other fixes.

> **Note:** As Pop!_OS releases newer kernels with Arrow Lake support baked in, the OEM kernel may no longer be necessary. Check if the stock kernel version is 6.11+ before installing.

### NVIDIA RTX 5070 Ti Driver

The RTX 5070 Ti (Blackwell/SM120) **requires the open kernel modules**. The proprietary NVIDIA driver will not work. You also need kernel 6.11 or newer.

```bash
sudo apt install nvidia-driver-570-open
```

Pop!_OS may offer a newer version (580-open or later) which also works. The key is the `-open` variant. The driver package automatically configures:
- `nvidia_drm modeset=1` via `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf`
- `NVreg_PreserveVideoMemoryAllocations=1` for sleep/suspend video memory preservation

### Speaker Fix (CS35L56 Amplifier)

The 2025 G16 uses a Cirrus Logic CS35L56 amplifier with subsystem ID `10431034`. This ID is too new for the current `linux-firmware` package, so the firmware files are missing and the speakers either produce no sound or very quiet output with no bass.

The fix symlinks the missing `10431034` firmware to `10431044` (a similar ASUS model that is already in linux-firmware). Six symlinks in `/lib/firmware/cirrus/`:

| Symlink (10431034) | Target (10431044) |
|--------------------|--------------------|
| `cs35l56-b0-dsp1-misc-10431034-spkid0-amp1.bin` | `...10431044-spkid0-amp1.bin` |
| `cs35l56-b0-dsp1-misc-10431034-spkid0-amp2.bin` | `...10431044-spkid0-amp2.bin` |
| `cs35l56-b0-dsp1-misc-10431034-spkid0.wmfw` | `...10431044-spkid0.wmfw` |
| `cs35l56-b0-dsp1-misc-10431034-spkid1-amp1.bin` | `...10431044-spkid1-amp1.bin` |
| `cs35l56-b0-dsp1-misc-10431034-spkid1-amp2.bin` | `...10431044-spkid1-amp2.bin` |
| `cs35l56-b0-dsp1-misc-10431034-spkid1.wmfw` | `...10431044-spkid1.wmfw` |

You can check if you have this issue by running `dmesg | grep cs35l56` and looking for "bin file required but not found".

### Kernel Parameters (via kernelstub)

| Parameter | Purpose |
|-----------|---------|
| `pci=noaer` | Suppress PCIe Advanced Error Reporting (noisy on this hardware) |
| `pcie_aspm=off` | Disable PCIe Active State Power Management (fixes sleep/resume) |
| `nvme_core.default_ps_max_latency_us=0` | Disable NVMe power state transitions (fixes hangs) |
| `nvme_core.io_timeout=4` | Reduce NVMe I/O timeout from 30s to 4s |
| `reboot=efi` | Clean EFI reboot behavior |
| `i915.enable_dpcd_backlight=3` | Intel display backlight control via DPCD |
| `loglevel=4` | Reasonable kernel log verbosity |
| `systemd.show_status=true` | Show service status during boot |

### Initramfs Modules

Adds `mei`, `mei_me`, and `mei_gsc_proxy` to `/etc/initramfs-tools/modules` so they load early during boot. Without this, the i915 driver waits 17 seconds for GSC proxy initialization.

### Systemd Drop-ins

**cosmic-greeter** (`/etc/systemd/system/cosmic-greeter.service.d/nvidia-wait.conf`):
Ensures the login screen waits for NVIDIA persistence daemon before starting. Prevents the greeter from failing to acquire DRM master when the GPU is not ready.

**nvidia-persistenced** (`/etc/systemd/system/nvidia-persistenced.service.d/override.conf`):
Adds retry logic, waits for `/dev/nvidia0` before starting, and enables verbose logging.

### Power Profile Conflicts

Pop!_OS uses `system76-power` to manage GPU switching and power profiles. If TLP or `power-profiles-daemon` are also installed (some desktop environments or packages pull them in as dependencies), they will fight over the same power settings, causing unpredictable behavior like GPU mode not sticking, fan profiles resetting, or battery drain.

The fix is to remove the conflicting services and let `system76-power` handle everything:

```bash
sudo apt remove tlp tlp-rdw
sudo apt remove power-profiles-daemon
```

Only `system76-power` and `thermald` should be running. Verify with:
```bash
systemctl is-active system76-power    # should be active
systemctl is-active thermald          # should be active
systemctl is-active tlp               # should be inactive or not found
systemctl is-active power-profiles-daemon  # should be inactive or not found
```

### Storage Optimization

Add `noatime` to your storage drive mount options in `/etc/fstab` to reduce unnecessary write I/O. Without it, every file read updates the access timestamp.

Find your storage drive line in `/etc/fstab` and add `noatime` to the options:
```
# Before
UUID=xxxx  /mnt/storage  ext4  defaults,nofail  0  2

# After
UUID=xxxx  /mnt/storage  ext4  defaults,noatime,nofail  0  2
```

> **Note:** Only apply this to secondary storage drives. The root partition on Pop!_OS typically already has `noatime`.

### Disabled Services

These services are safe to disable on Pop!_OS:

| Service | Reason |
|---------|--------|
| `grub-common.service` | Pop!_OS uses systemd-boot, not GRUB |
| `grub-initrd-fallback.service` | Same as above |
| `libvirt-guests.service` | Only needed if running VMs with libvirt |
| `acct.service` | Process accounting, not needed for desktop use |

## Manual Installation

If you prefer to apply changes yourself, see the individual config files in the `configs/` directory and the documented kernel parameters above.

### OEM Kernel
```bash
sudo apt install linux-image-oem-24.04d
sudo kernelstub -k /boot/vmlinuz-$(ls /lib/modules/ | grep oem | sort -V | tail -1) \
                -i /boot/initrd.img-$(ls /lib/modules/ | grep oem | sort -V | tail -1)
```
Reboot and confirm with `uname -r` before continuing.

### NVIDIA driver
```bash
sudo apt install nvidia-driver-570-open
```
Use the highest `-open` version available in your repos. Do NOT install the non-open variant.

### Speaker firmware
```bash
sudo ./configs/fix-speakers.sh
```
Or manually create the symlinks listed above in `/lib/firmware/cirrus/`.

### Kernel parameters
```bash
sudo kernelstub -a "pci=noaer"
sudo kernelstub -a "pcie_aspm=off"
sudo kernelstub -a "nvme_core.default_ps_max_latency_us=0"
sudo kernelstub -a "nvme_core.io_timeout=4"
sudo kernelstub -a "reboot=efi"
sudo kernelstub -a "i915.enable_dpcd_backlight=3"
sudo kernelstub -a "loglevel=4"
sudo kernelstub -a "systemd.show_status=true"
```

### Initramfs modules
```bash
sudo tee -a /etc/initramfs-tools/modules << 'EOF'

# MEI modules for i915 GSC proxy - prevent 17s boot timeout
mei
mei_me
mei_gsc_proxy
EOF
sudo update-initramfs -u
```

### Systemd drop-ins
```bash
sudo mkdir -p /etc/systemd/system/cosmic-greeter.service.d
sudo cp configs/cosmic-greeter-nvidia-wait.conf /etc/systemd/system/cosmic-greeter.service.d/nvidia-wait.conf

sudo mkdir -p /etc/systemd/system/nvidia-persistenced.service.d
sudo cp configs/nvidia-persistenced-override.conf /etc/systemd/system/nvidia-persistenced.service.d/override.conf

sudo systemctl daemon-reload
```

### Remove conflicting power managers
```bash
sudo apt remove tlp tlp-rdw power-profiles-daemon
```

### Disable unused services
```bash
sudo systemctl disable grub-common.service
sudo systemctl disable grub-initrd-fallback.service
sudo systemctl disable libvirt-guests.service
sudo systemctl disable acct.service
```

## Reverting Changes

### Remove kernel parameters
```bash
sudo kernelstub -d "pci=noaer"
sudo kernelstub -d "pcie_aspm=off"
# ... repeat for each parameter
```

### Remove speaker firmware symlinks
```bash
sudo rm /lib/firmware/cirrus/cs35l56-b0-dsp1-misc-10431034-*
```

### Remove initramfs modules
Edit `/etc/initramfs-tools/modules` and remove the MEI lines, then run `sudo update-initramfs -u`.

### Remove systemd drop-ins
```bash
sudo rm -rf /etc/systemd/system/cosmic-greeter.service.d
sudo rm -rf /etc/systemd/system/nvidia-persistenced.service.d
sudo systemctl daemon-reload
```

### Re-enable services
```bash
sudo systemctl enable grub-common.service grub-initrd-fallback.service libvirt-guests.service acct.service
```

## Troubleshooting

### Boot hangs after configuring encrypted swap

If you (or another AI assistant) configured encrypted swap via `/etc/crypttab` and the system now hangs on boot, the actual root cause is likely PCIe bus errors from Intel VMD, not the swap encryption itself. The cryptswap setup just happens to expose the timing.

**To recover:**
1. Boot from a Pop!_OS live USB
2. Mount your root partition (e.g., `sudo mount /dev/nvme0n1p3 /mnt`)
3. Edit `/mnt/etc/crypttab` and comment out or remove the cryptswap entry
4. Unmount and reboot
5. Disable Intel VMD in BIOS (the actual fix)

Do not chase the cryptswap rabbit hole. Fix VMD first, then re-evaluate if you actually need encrypted swap.

## Notes

- **BIOS:** You must disable Intel VMD before installing. This is the single most important step. PCIe bus errors from VMD will cause persistent reboot/sleep hangs that no amount of kernel parameters will fix.
- **OEM Kernel:** Pop!_OS does not auto-create boot entries for OEM kernels. You must register it with `kernelstub` manually. Once the mainline Pop!_OS kernel catches up to 6.11+, the OEM kernel is no longer needed.
- **NVIDIA:** RTX 50 series (Blackwell) requires the `-open` kernel modules. The proprietary driver flat out will not work. Do not waste time troubleshooting the non-open driver.
- **Speakers:** The firmware symlink workaround should eventually become unnecessary as `linux-firmware` updates add the 10431034 subsystem ID natively. Check `dmesg | grep cs35l56` after a firmware update to see if the symlinks are still needed.
- These fixes are specific to the Intel Core Ultra (Meteor Lake) + NVIDIA dGPU combo. Some parameters may not apply to AMD variants of the G16.
- The `pcie_aspm=off` parameter trades a small amount of battery life for reliable sleep/wake. If you need maximum battery, test without it first.
- The `COSMIC_RENDER_DEVICE` in the greeter drop-in may need adjustment depending on which `/dev/dri/card*` is your display GPU. Check with `ls -la /dev/dri/by-path/`.
- Tested on Pop!_OS 24.04 with COSMIC desktop.

## Disclaimer

This repository is provided as is. I am not responsible for anything these changes cause to your system. You are responsible for your own hardware, software, and any modifications you make. Back up your data before making system level changes.

## License

MIT
