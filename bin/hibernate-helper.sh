#!/bin/bash
# hibernado Helper Script
# This script sets up hibernation
# Based on: https://github.com/nazar256/publications/blob/main/guides/steam-deck-hibernation.md

set -e

log() {
    echo "[hibernado] $1" >&2
}

# --- Paths -------------------------------------------------------------------
# Sleep policy is written as a drop-in (NOT the main /etc/systemd/sleep.conf).
# systemd merges drop-ins on top of the main file, and SteamOS ships its own
# /usr/lib/systemd/sleep.conf.d/steamos-suspend-then-hibernate.conf. The main
# file is the LOWEST precedence, so writing there gets silently overridden. A
# drop-in named to sort AFTER "steamos-" (and living in /etc, which beats
# /usr/lib) is what actually takes effect.
SLEEP_DROPIN="/etc/systemd/sleep.conf.d/zz-hibernado.conf"
LEGACY_SLEEP_CONF="/etc/systemd/sleep.conf"
LOGIND_BYPASS="/etc/systemd/system/systemd-logind.service.d/hibernado-override.conf"
DEFAULT_DELAY_MIN=60
DEFAULT_AC_POWER=no   # match SteamOS: only auto-hibernate on battery by default

# Opt-in: persistently disable SteamOS's zram swap. zram holds compressed pages
# in RAM, which (a) bloats the hibernation image and (b) starves the physical
# RAM the GPU driver needs to evict its buffers during hibernate -> amdgpu
# returns -ENOMEM and the hibernate is refused (or, historically, crashed).
# /etc/systemd/zram-generator.conf overrides the SteamOS /usr/lib config; a
# device with final size 0 is discarded (per zram-generator.conf(5)).
ZRAM_CONF="/etc/systemd/zram-generator.conf"
ZRAM_CONF_BAK="/etc/systemd/zram-generator.conf.hibernado-orig"

zram_is_disabled() {
    [ -f "$ZRAM_CONF" ] && grep -q "hibernado" "$ZRAM_CONF" 2>/dev/null
}

apply_zram_off_now() {
    # Deactivate zram immediately so the change applies without a reboot.
    swapoff /dev/zram0 2>/dev/null || true
    systemctl stop dev-zram0.swap 2>/dev/null || true
    systemctl stop "systemd-zram-setup@zram0.service" 2>/dev/null || true
}

apply_zram_on_now() {
    # Best-effort re-activation without a reboot (a reboot always restores it).
    systemctl daemon-reload 2>/dev/null || true
    systemctl start "systemd-zram-setup@zram0.service" 2>/dev/null || true
    systemctl start dev-zram0.swap 2>/dev/null || true
}

enable_zram_disable() {
    # Preserve a pre-existing (non-ours) config so we can restore it later.
    if [ -f "$ZRAM_CONF" ] && ! grep -q "hibernado" "$ZRAM_CONF" 2>/dev/null; then
        log "Backing up existing zram-generator.conf..."
        mv "$ZRAM_CONF" "$ZRAM_CONF_BAK"
    fi
    cat > "$ZRAM_CONF" << EOF
# hibernado plugin - disable zram so hibernation has enough free RAM.
# Remove this file (or toggle off in the plugin) to restore SteamOS zram.
[zram0]
zram-size = 0
host-memory-limit = 0
EOF
    systemctl daemon-reload 2>/dev/null || true
    apply_zram_off_now
}

disable_zram_disable() {
    if [ -f "$ZRAM_CONF" ] && grep -q "hibernado" "$ZRAM_CONF" 2>/dev/null; then
        rm -f "$ZRAM_CONF"
    fi
    if [ -f "$ZRAM_CONF_BAK" ]; then
        mv "$ZRAM_CONF_BAK" "$ZRAM_CONF"
    fi
    apply_zram_on_now
}

read_current_delay() {
    # Echo the current delay (minutes) from the drop-in, or the default.
    local d=""
    if [ -f "$SLEEP_DROPIN" ]; then
        d=$(grep "^HibernateDelaySec=" "$SLEEP_DROPIN" | cut -d'=' -f2 | sed 's/min$//')
    fi
    echo "${d:-$DEFAULT_DELAY_MIN}"
}

read_current_ac() {
    # Echo the current HibernateOnACPower (yes/no) from the drop-in, or default.
    local a=""
    if [ -f "$SLEEP_DROPIN" ]; then
        a=$(grep "^HibernateOnACPower=" "$SLEEP_DROPIN" | cut -d'=' -f2)
    fi
    echo "${a:-$DEFAULT_AC_POWER}"
}

write_sleep_dropin() {
    # $1 = hibernate delay in minutes (defaults to DEFAULT_DELAY_MIN)
    # $2 = HibernateOnACPower, "yes" or "no" (defaults to DEFAULT_AC_POWER)
    local delay_min="${1:-$DEFAULT_DELAY_MIN}"
    local ac_power="${2:-$DEFAULT_AC_POWER}"
    mkdir -p "$(dirname "$SLEEP_DROPIN")"
    cat > "$SLEEP_DROPIN" << EOF
# hibernado plugin - suspend-then-hibernate configuration
# Drop-in (sorts after SteamOS's steamos-*.conf and lives in /etc) so it takes
# precedence over the SteamOS-shipped /usr/lib sleep defaults.
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=${delay_min}min
# HibernateOnACPower=no  -> only count the timer down on battery (stay suspended
#   while charging = fast resume). =yes -> also hibernate after the delay on AC.
HibernateOnACPower=${ac_power}
EOF
}

remove_memory_check_bypass() {
    # Older versions installed a logind override setting
    # SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1. That disabled systemd's
    # pre-hibernate memory check, which let an out-of-memory hibernate be
    # *attempted* (aborting mid-snapshot and crashing amdgpu) instead of being
    # safely refused. Never install it; remove it if present (migration).
    if [ -f "$LOGIND_BYPASS" ]; then
        log "Removing unsafe hibernation memory-check bypass..."
        rm -f "$LOGIND_BYPASS"
        rmdir /etc/systemd/system/systemd-logind.service.d 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi
}

migrate_legacy_sleep_conf() {
    # Older versions overwrote the main /etc/systemd/sleep.conf (lowest
    # precedence, overridden by SteamOS's drop-in). Remove it only if we
    # recognise it as ours, so our drop-in wins cleanly.
    if [ -f "$LEGACY_SLEEP_CONF" ] && grep -q "hibernado plugin" "$LEGACY_SLEEP_CONF" 2>/dev/null; then
        log "Removing legacy hibernado /etc/systemd/sleep.conf (superseded by drop-in)..."
        rm -f "$LEGACY_SLEEP_CONF"
    fi
}

ACTION="${1:-status}"

case "$ACTION" in
    status)
        SWAP="/home/swapfile"
        
        if [ ! -f "$SWAP" ]; then
            echo "SWAPFILE_MISSING"
            exit 0
        fi
        
        SWAP_SIZE=$(stat -c "%s" "$SWAP" 2>/dev/null || echo 0)
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        MIN_SIZE=$((TOTAL_RAM_KB * 1024))
        if [ "$SWAP_SIZE" -lt "$MIN_SIZE" ]; then
            echo "SWAPFILE_TOO_SMALL"
            exit 0
        fi
        
        if ! swapon --show=NAME | grep -q "$SWAP"; then
            echo "SWAP_INACTIVE"
            exit 0
        fi
        
        if ([ -f /etc/default/grub.d/hibernado.cfg ] && grep -q "resume=" /etc/default/grub.d/hibernado.cfg 2>/dev/null) || \
           ([ -f /etc/default/grub ] && grep -q "resume=" /etc/default/grub 2>/dev/null); then
            :
        else
            echo "RESUME_NOT_CONFIGURED"
            exit 0
        fi
        
        if [ ! -f /etc/systemd/system/fix-bluetooth-resume.service ]; then
            echo "BLUETOOTH_FIX_MISSING"
            exit 0
        fi
        
        # Sleep policy must live in our drop-in (see write_sleep_dropin). A
        # legacy main sleep.conf alone is NOT sufficient - it gets overridden.
        if [ ! -f "$SLEEP_DROPIN" ] || ! grep -q "HibernateDelaySec" "$SLEEP_DROPIN" 2>/dev/null; then
            echo "SLEEP_CONF_NOT_CONFIGURED"
            exit 0
        fi
        
        echo "READY"
        ;;
        
    prepare)
        log "Starting hibernation preparation..."
        
        UUID=$(findmnt -no UUID -T /home)
        if [ -z "$UUID" ]; then
            log "ERROR: Could not find UUID for /home"
            echo "ERROR: Could not determine filesystem UUID for /home" >&2
            exit 1
        fi
        log "Found filesystem UUID: $UUID"
        
        SWAP=/home/swapfile
        MARKER=/home/.hibernado-swapfile
        log "Setting up hibernation (filesystem-friendly method)..."
        
        NEEDS_RECREATION=false
        ORIGINAL_SIZE=0
        if [ -f "$SWAP" ]; then
            SWAP_SIZE=$(stat -c "%s" "$SWAP" 2>/dev/null || echo 0)
            TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            MIN_SIZE=$((TOTAL_RAM_KB * 1024))
            
            if [ "$SWAP_SIZE" -lt "$MIN_SIZE" ]; then
                log "Existing swapfile is too small (${SWAP_SIZE} bytes < ${MIN_SIZE} bytes required)"
                NEEDS_RECREATION=true
                ORIGINAL_SIZE=$SWAP_SIZE
            fi
            
            if ! file "$SWAP" | grep -q "swap file"; then
                log "Existing swapfile is invalid"
                NEEDS_RECREATION=true
            fi
        else
            log "Swapfile does not exist"
            NEEDS_RECREATION=true
        fi
        
        if [ "$NEEDS_RECREATION" = true ]; then
            if swapon --show=NAME | grep -q "$SWAP"; then
                log "Deactivating existing swapfile for recreation..."
                swapoff "$SWAP" 2>&1 || log "WARNING: Failed to deactivate swapfile"
            fi
            
            log "Removing old swapfile..."
            rm -f "$SWAP"
            
            SWAP_SIZE_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 + 1024 ))
            log "Creating ${SWAP_SIZE_MB}MB swapfile (RAM + 1GB) using fallocate..."
            
            if ! fallocate -l ${SWAP_SIZE_MB}M "$SWAP" 2>&1; then
                log "ERROR: Failed to create swapfile with fallocate"
                echo "ERROR: Failed to create swapfile" >&2
                exit 1
            fi
            log "Swapfile created successfully"
            
            log "Setting swapfile permissions..."
            chmod 600 "$SWAP"
            
            log "Formatting swapfile..."
            if ! mkswap "$SWAP" >/dev/null 2>&1; then
                log "ERROR: Failed to format swapfile"
                echo "ERROR: Failed to format swapfile" >&2
                exit 1
            fi
            log "Swapfile formatted successfully"
            
            log "Creating marker file to track Hibernado-created swapfile..."
            echo "$ORIGINAL_SIZE" > "$MARKER"
        fi
        
        if ! swapon --show=NAME | grep -q "$SWAP"; then
            log "Activating swapfile with priority for hibernation..."
            if ! swapon -p -1 "$SWAP" 2>&1; then
                log "ERROR: Failed to activate swapfile"
                echo "ERROR: Failed to activate swapfile" >&2
                exit 1
            fi
            
            if swapon --show=NAME,PRIO | grep -q "$SWAP"; then
                SWAP_PRIO=$(swapon --show=NAME,PRIO --noheadings | grep "$SWAP" | awk '{print $2}')
                log "Swapfile activated with priority: $SWAP_PRIO"
            else
                log "ERROR: Swapfile activation verification failed"
                echo "ERROR: Swapfile not showing in active swaps" >&2
                exit 1
            fi
        else
            log "Swapfile already active"
        fi
        
        log "Checking swapfile fragmentation..."
        e4defrag "$SWAP" 2>/dev/null || log "Defrag not needed or not supported"
        
        log "Getting swapfile offset..."
        OFF=$(filefrag -v "$SWAP" | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')
        if [ -z "$OFF" ]; then
            log "ERROR: Could not determine swapfile offset"
            echo "ERROR: Could not determine swapfile offset" >&2
            exit 1
        fi
        
        log "Swapfile UUID: $UUID"
        log "Swapfile offset: $OFF"
        
        log "Creating systemd swap unit..."
        cat > /etc/systemd/system/home-swapfile.swap << EOF
[Unit]
Description=Hibernado Swap File
Documentation=man:systemd.swap(5)

[Swap]
What=$SWAP
Priority=-1

[Install]
WantedBy=swap.target
EOF
        systemctl daemon-reload
        systemctl enable home-swapfile.swap 2>/dev/null || true
        
        if [ ! -f /etc/default/grub.d/hibernado.cfg ]; then
            log "Configuring GRUB for hibernation resume..."
            mkdir -p /etc/default/grub.d
            cat > /etc/default/grub.d/hibernado.cfg << EOF
# hibernado plugin - hibernation resume parameters
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT resume=/dev/disk/by-uuid/$UUID resume_offset=$OFF"
EOF
            if ! update-grub 2>&1; then
                log "WARNING: update-grub failed, may need manual run"
                echo "NOTE: Please run 'sudo update-grub' manually" >&2
            fi
        else
            log "GRUB config already exists"
        fi
        
        # NOTE: We intentionally do NOT bypass systemd's pre-hibernate memory
        # check. If free RAM is too low to build the hibernation image (e.g. a
        # heavy game is loaded), systemd will now *refuse* to hibernate (staying
        # safely suspended) instead of aborting mid-snapshot and crashing the GPU.
        remove_memory_check_bypass
        
        log "Setting up Bluetooth fix for resume..."
        mkdir -p /home/deck/.local/bin
        cat > /home/deck/.local/bin/fix-bluetooth.sh << 'EOF'
#!/bin/bash
PATH=/sbin:/usr/sbin:/bin:/usr/bin

is_bluetooth_ok() {
    echo "Checking Bluetooth status..."
    bluetoothctl discoverable on
    if [ $? -ne 0 ]; then
        echo "Bluetooth is misbehaving."
        return 1
    else
        echo "Bluetooth is working fine."
        return 0
    fi
}

sleep 2

if ! is_bluetooth_ok; then
    (echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/unbind ; sleep 1 && echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/bind)
fi
EOF
        chmod +x /home/deck/.local/bin/fix-bluetooth.sh
        chown deck:deck /home/deck/.local/bin/fix-bluetooth.sh
        
        log "Creating Bluetooth fix systemd service..."
        cat > /etc/systemd/system/fix-bluetooth-resume.service << EOF
[Unit]
Description=Fix Bluetooth after resume from hibernation
After=hibernate.target hybrid-sleep.target suspend-then-hibernate.target bluetooth.service

[Service]
Type=oneshot
ExecStart=/home/deck/.local/bin/fix-bluetooth.sh

[Install]
WantedBy=hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF
        systemctl daemon-reload
        systemctl enable fix-bluetooth-resume.service
        
        # 7. Configure suspend-then-hibernate timing via a drop-in that actually
        #    overrides SteamOS's shipped defaults (default delay).
        log "Configuring suspend-then-hibernate timing..."
        migrate_legacy_sleep_conf
        # Preserve any values the user already chose via the UI on re-setup.
        write_sleep_dropin "$(read_current_delay)" "$(read_current_ac)"
        
        log "Creating hibernate resume setup script in /home..."
        mkdir -p /home/deck/.local/libexec
        cat > /home/deck/.local/libexec/hibernado-set-resume.sh << 'EOF'
#!/bin/bash
# hibernado - Set resume parameters before hibernation

SWAP=/home/swapfile

if [ ! -f "$SWAP" ]; then
    echo "[hibernado] Swapfile not found, skipping resume setup" >&2
    exit 0
fi

# Get device information
DEV_PATH=$(findmnt -no SOURCE -T /home 2>/dev/null)
if [ -z "$DEV_PATH" ]; then
    echo "[hibernado] Could not find /home device" >&2
    exit 1
fi

# Get major:minor device numbers
MAJOR=$(stat -c "%t" "$DEV_PATH" 2>/dev/null)
MINOR=$(stat -c "%T" "$DEV_PATH" 2>/dev/null)

if [ -z "$MAJOR" ] || [ -z "$MINOR" ]; then
    echo "[hibernado] Could not get device numbers" >&2
    exit 1
fi

# Convert hex to decimal
MAJOR_DEC=$((16#$MAJOR))
MINOR_DEC=$((16#$MINOR))
RESUME_DEV="$MAJOR_DEC:$MINOR_DEC"

# Get swapfile offset
OFF=$(filefrag -v "$SWAP" 2>/dev/null | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')

if [ -z "$OFF" ]; then
    echo "[hibernado] Could not get swapfile offset" >&2
    exit 1
fi

# Set resume parameters
echo "[hibernado] Setting resume device: $RESUME_DEV, offset: $OFF" >&2
echo "$RESUME_DEV" > /sys/power/resume 2>/dev/null || echo "[hibernado] WARNING: Could not set resume device" >&2
echo "$OFF" > /sys/power/resume_offset 2>/dev/null || echo "[hibernado] WARNING: Could not set resume offset" >&2

# Set hibernation mode
echo "platform" > /sys/power/disk 2>/dev/null || echo "[hibernado] WARNING: Could not set hibernation mode" >&2

# Shrink the hibernation image as much as possible before snapshotting. This
# forces the kernel to reclaim memory up front, leaving enough free physical
# RAM for the GPU driver to evict its buffers during freeze (amdgpu otherwise
# fails with -ENOMEM when a heavy game is running). Costs a little extra time.
echo 0 > /sys/power/image_size 2>/dev/null || echo "[hibernado] WARNING: Could not set image_size" >&2
EOF
        chmod +x /home/deck/.local/libexec/hibernado-set-resume.sh
        chown deck:deck /home/deck/.local/libexec/hibernado-set-resume.sh
        
        log "Creating systemd service to set resume parameters before hibernation..."
        mkdir -p /etc/systemd/system/systemd-hibernate.service.d
        cat > /etc/systemd/system/systemd-hibernate.service.d/hibernado-resume.conf << EOF
[Service]
ExecStartPre=/home/deck/.local/libexec/hibernado-set-resume.sh
ExecStartPost=-/home/deck/.local/bin/fix-bluetooth.sh
ExecStartPost=-/usr/bin/steamos-bootconf set-mode booted
EOF
        
        mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
        cat > /etc/systemd/system/systemd-suspend-then-hibernate.service.d/hibernado-resume.conf << EOF
[Service]
ExecStartPre=/home/deck/.local/libexec/hibernado-set-resume.sh
ExecStartPost=-/home/deck/.local/bin/fix-bluetooth.sh
ExecStartPost=-/usr/bin/steamos-bootconf set-mode booted
EOF
        systemctl daemon-reload
        
        log "Setting up SteamOS boot counter fix..."
        cat > /etc/systemd/system/steamos-hibernate-success.service << 'EOF'
[Unit]
Description=Mark hibernation resume as successful boot
After=hibernate.target hybrid-sleep.target suspend-then-hibernate.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/bin/steamos-bootconf set-mode booted
RemainAfterExit=yes

[Install]
WantedBy=hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF
        systemctl daemon-reload
        systemctl enable steamos-hibernate-success.service 2>/dev/null || log "Note: steamos-bootconf may not be available on this system"
        
        log "Hibernation setup complete!"
        echo "SUCCESS:$UUID:$OFF"
        ;;
        
    hibernate)
        # Trigger immediate hibernation via systemd so that hibernate.target is
        # reached and the post-resume hooks (Bluetooth fix, boot-counter reset)
        # run. Resume parameters are set by the ExecStartPre drop-in that
        # `prepare` installs on systemd-hibernate.service.
        log "Triggering hibernation via systemctl..."
        systemctl hibernate
        ;;
        
    suspend-then-hibernate)
        systemctl suspend-then-hibernate
        ;;
        
    set-power-button)
        # Usage: set-power-button enable hibernate|suspend-then-hibernate
        #        set-power-button disable
        POWER_ACTION="${2:-}"
        MODE="${3:-}"
        
        SYMLINK_PATH="/etc/systemd/system/systemd-suspend.service"
        
        if [ "$POWER_ACTION" = "enable" ]; then
            if [ -z "$MODE" ]; then
                log "ERROR: Mode not specified (hibernate or suspend-then-hibernate)"
                echo "ERROR: Mode required for enable" >&2
                exit 1
            fi
            
            # Remove existing symlink if present
            if [ -L "$SYMLINK_PATH" ] || [ -e "$SYMLINK_PATH" ]; then
                log "Removing existing systemd-suspend.service..."
                rm -f "$SYMLINK_PATH"
            fi
            
            # Create the appropriate symlink based on mode
            if [ "$MODE" = "hibernate" ]; then
                log "Creating symlink for immediate hibernate on power button..."
                ln -s /usr/lib/systemd/system/systemd-hibernate.service "$SYMLINK_PATH"
                log "Power button will now trigger immediate hibernation"
            elif [ "$MODE" = "suspend-then-hibernate" ]; then
                log "Creating symlink for suspend-then-hibernate on power button..."
                ln -s /usr/lib/systemd/system/systemd-suspend-then-hibernate.service "$SYMLINK_PATH"
                log "Power button will now trigger suspend-then-hibernate"
            else
                log "ERROR: Invalid mode '$MODE' (must be hibernate or suspend-then-hibernate)"
                echo "ERROR: Invalid mode" >&2
                exit 1
            fi
            
            systemctl daemon-reload
            log "Power button override enabled successfully"
            
        elif [ "$POWER_ACTION" = "disable" ]; then
            if [ -L "$SYMLINK_PATH" ] || [ -e "$SYMLINK_PATH" ]; then
                log "Removing power button override symlink..."
                rm -f "$SYMLINK_PATH"
                systemctl daemon-reload
                log "Power button restored to normal suspend behavior"
            else
                log "No power button override was active"
            fi
        else
            log "ERROR: Invalid action '$POWER_ACTION' (must be enable or disable)"
            echo "ERROR: Invalid action" >&2
            exit 1
        fi
        ;;
        
    cleanup)
        SWAP=/home/swapfile
        MARKER=/home/.hibernado-swapfile
        
        log "Cleaning up hibernation configuration..."
        
        # Remove power button override if present
        SYMLINK_PATH="/etc/systemd/system/systemd-suspend.service"
        if [ -L "$SYMLINK_PATH" ] || [ -e "$SYMLINK_PATH" ]; then
            log "Removing power button override..."
            rm -f "$SYMLINK_PATH"
        fi
        
        if [ -f /etc/default/grub.d/hibernado.cfg ]; then
            log "Removing GRUB hibernation config..."
            rm -f /etc/default/grub.d/hibernado.cfg
            rmdir /etc/default/grub.d 2>/dev/null || true
            log "Rebuilding GRUB configuration..."
            if ! update-grub 2>&1; then
                log "WARNING: update-grub failed"
                echo "NOTE: Please run 'sudo update-grub' manually" >&2
            else
                log "GRUB configuration updated successfully"
            fi
        fi
        
        if [ -f /etc/systemd/system/systemd-logind.service.d/hibernado-override.conf ]; then
            log "Removing systemd-logind override..."
            rm -f /etc/systemd/system/systemd-logind.service.d/hibernado-override.conf
            rmdir /etc/systemd/system/systemd-logind.service.d 2>/dev/null || true
        fi
        
        log "Removing Bluetooth fix service..."
        systemctl disable fix-bluetooth-resume.service 2>/dev/null || true
        rm -f /etc/systemd/system/fix-bluetooth-resume.service
        rm -f /home/deck/.local/bin/fix-bluetooth.sh
        rmdir /home/deck/.local/bin 2>/dev/null || true
        
        log "Removing SteamOS boot counter fix service..."
        systemctl disable steamos-hibernate-success.service 2>/dev/null || true
        rm -f /etc/systemd/system/steamos-hibernate-success.service
        
        if [ -f "$SLEEP_DROPIN" ]; then
            log "Removing sleep configuration drop-in..."
            rm -f "$SLEEP_DROPIN"
            rmdir /etc/systemd/sleep.conf.d 2>/dev/null || true
        fi
        # Remove any legacy main sleep.conf we may have written in older versions
        migrate_legacy_sleep_conf

        # Restore SteamOS zram if we had disabled it
        if zram_is_disabled || [ -f "$ZRAM_CONF_BAK" ]; then
            log "Restoring zram configuration..."
            disable_zram_disable
        fi
        
        if [ -d /etc/systemd/system/systemd-hibernate.service.d ]; then
            log "Removing hibernate service drop-in..."
            rm -f /etc/systemd/system/systemd-hibernate.service.d/hibernado-resume.conf
            rmdir /etc/systemd/system/systemd-hibernate.service.d 2>/dev/null || true
        fi
        
        if [ -d /etc/systemd/system/systemd-suspend-then-hibernate.service.d ]; then
            log "Removing suspend-then-hibernate service drop-in..."
            rm -f /etc/systemd/system/systemd-suspend-then-hibernate.service.d/hibernado-resume.conf
            rmdir /etc/systemd/system/systemd-suspend-then-hibernate.service.d 2>/dev/null || true
        fi
        
        if [ -f /home/deck/.local/libexec/hibernado-set-resume.sh ]; then
            log "Removing resume setup script..."
            rm -f /home/deck/.local/libexec/hibernado-set-resume.sh
            rmdir /home/deck/.local/libexec 2>/dev/null || true
        fi
        
        log "Reloading systemd configuration..."
        systemctl daemon-reload
        
        if [ -f /etc/systemd/system/home-swapfile.swap ]; then
            log "Removing systemd swap unit..."
            systemctl disable home-swapfile.swap 2>/dev/null || true
            systemctl stop home-swapfile.swap 2>/dev/null || true
            rm -f /etc/systemd/system/home-swapfile.swap
        fi
        
        if [ -f "$MARKER" ]; then
            if swapon --show=NAME | grep -q "$SWAP"; then
                log "Deactivating swapfile..."
                swapoff "$SWAP" 2>&1 || log "WARNING: Failed to deactivate swapfile"
            fi
            
            ORIGINAL_SIZE=$(cat "$MARKER" 2>/dev/null || echo 0)
            if [ -f "$SWAP" ]; then
                log "Removing Hibernado-created swapfile..."
                rm -f "$SWAP" 2>&1 || log "WARNING: Failed to remove swapfile"
            fi
            
            if [ "$ORIGINAL_SIZE" -gt 0 ]; then
                log "Recreating original swapfile (${ORIGINAL_SIZE} bytes)..."
                if fallocate -l "$ORIGINAL_SIZE" "$SWAP" 2>&1 && chmod 600 "$SWAP" && mkswap "$SWAP" >/dev/null 2>&1; then
                    log "Original swapfile restored"
                else
                    log "WARNING: Failed to restore original swapfile"
                fi
            fi
            
            log "Removing marker file..."
            rm -f "$MARKER"
        else
            log "Marker file not found - preserving user's existing swapfile"
        fi
        
        log "Cleanup complete. All hibernation configuration has been removed."
        log "NOTE: A reboot is recommended to ensure all kernel parameters are reset."
        ;;
    
    get-delay)
        # Get current hibernate delay setting from our sleep drop-in
        if [ -f "$SLEEP_DROPIN" ]; then
            # Extract the delay value (strip 'min' suffix and get the number)
            DELAY=$(grep "^HibernateDelaySec=" "$SLEEP_DROPIN" | cut -d'=' -f2 | sed 's/min$//')
            if [ -n "$DELAY" ]; then
                echo "$DELAY"
                exit 0
            fi
        fi
        # Default if not found
        echo "$DEFAULT_DELAY_MIN"
        exit 0
        ;;
    
    set-delay)
        # Set hibernate delay: $2 = delay in minutes
        if [ -z "$2" ]; then
            log "ERROR: Delay minutes not specified"
            exit 1
        fi
        
        DELAY_MIN="$2"
        
        if ! [[ "$DELAY_MIN" =~ ^[0-9]+$ ]]; then
            log "ERROR: Invalid delay value (must be a number)"
            exit 1
        fi
        
        log "Setting hibernate delay to $DELAY_MIN minutes..."
        
        # Update the sleep drop-in with the new delay, preserving the AC setting.
        migrate_legacy_sleep_conf
        write_sleep_dropin "$DELAY_MIN" "$(read_current_ac)"
        log "Hibernate delay set to $DELAY_MIN minutes"
        exit 0
        ;;
    
    get-ac-power)
        # Echo current HibernateOnACPower value ("yes" or "no")
        read_current_ac
        exit 0
        ;;
    
    set-ac-power)
        # Set whether to hibernate while on AC power: $2 = "yes" or "no"
        AC="${2:-}"
        if [ "$AC" != "yes" ] && [ "$AC" != "no" ]; then
            log "ERROR: set-ac-power requires 'yes' or 'no'"
            exit 1
        fi
        
        log "Setting HibernateOnACPower to $AC..."
        # Rewrite the drop-in with the new AC setting, preserving the delay.
        migrate_legacy_sleep_conf
        write_sleep_dropin "$(read_current_delay)" "$AC"
        log "HibernateOnACPower set to $AC"
        exit 0
        ;;
    
    get-zram-disabled)
        # Echo "yes" if hibernado has persistently disabled zram, else "no"
        if zram_is_disabled; then echo "yes"; else echo "no"; fi
        exit 0
        ;;
    
    set-zram-disabled)
        # Persistently disable/enable SteamOS zram: $2 = "yes" (disable) | "no" (enable)
        case "${2:-}" in
            yes)
                log "Disabling zram (persistent, for hibernating under memory pressure)..."
                enable_zram_disable
                log "zram disabled"
                ;;
            no)
                log "Re-enabling zram..."
                disable_zram_disable
                log "zram enabled"
                ;;
            *)
                log "ERROR: set-zram-disabled requires 'yes' or 'no'"
                exit 1
                ;;
        esac
        exit 0
        ;;
        
    *)
        echo "Usage: $0 {status|prepare|hibernate|suspend-then-hibernate|set-power-button|get-delay|set-delay|get-ac-power|set-ac-power|get-zram-disabled|set-zram-disabled|cleanup}"
        exit 1
        ;;
esac

