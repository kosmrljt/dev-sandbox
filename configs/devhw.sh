# dev-sandbox config: Development with USB, camera, Wayland desktop
#
# Usage:
#   cp devhw.sh ~/.dev-sandbox/
#   dev-sandbox --config devhw.sh
#
# Prerequisites on host:
#   - User must be in 'dialout' group: sudo usermod -aG dialout $USER
#   - For video devices: sudo usermod -aG video $USER
#   - Logout/login after group changes
#
# Verify devices:
#   lsusb                          # USB devices
#   ls /dev/video*                 # cameras
#   echo $WAYLAND_DISPLAY          # Wayland socket


PROFILE_devhw_DESCRIPTION="Claude Code — USB + camera + Wayland development"
PROFILE_devhw_COLOR="32"               # Green prompt — trusted agent
PROFILE_devhw_USE_KRUN=false           # Required — krun VM cannot pass through devices
PROFILE_devhw_SSH_PORT=0
PROFILE_devhw_AGENTS=(
    'curl -fsSL https://claude.ai/install.sh | bash'
)
PROFILE_devhw_DNF=(
    usbutils                             # lsusb
    picocom minicom                      # Serial terminal
    python3-pyserial                     # Python serial library
    mesa-libGL mesa-libEGL qt5-qtwayland # Wayland/OpenGL
    v4l-utils mpv dialog
)
PROFILE_devhw_VOLUMES=(
    .claude
    .cache
)

# Discover video devices dynamically
VIDEO_DEVICES=()
for dev in /dev/video*; do
    [ -e "$dev" ] && VIDEO_DEVICES+=(--device "$dev")
done

# Build podman args
WORK_PODMAN_ARGS=(
    # Standard tmpfs
    --tmpfs /var/log:rw,size=50m,mode=1777
    --tmpfs /tmp:rw,size=300m,mode=1777

    # USB device access
    --device /dev/bus/usb

    # Group access for serial ports and video
    --group-add keep-groups

    # Video camera access (if any)
    "${VIDEO_DEVICES[@]}"

    # GPU access
    --device /dev/dri
)

# Wayland desktop sharing (only if Wayland session is active)
if [[ -n "${WAYLAND_DISPLAY:-}" ]] && [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    WORK_PODMAN_ARGS+=(
        -e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
        -e "XDG_RUNTIME_DIR=/tmp/runtime-user"
        -v "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:/tmp/runtime-user/${WAYLAND_DISPLAY}:ro"
        -e "MOZ_ENABLE_WAYLAND=1"
        -e "QT_QPA_PLATFORM=wayland"
        -e "GDK_BACKEND=wayland"
    )
fi

PROFILE_devhw_PODMAN_ARGS=("${WORK_PODMAN_ARGS[@]}")

# Ensure /tmp/runtime-user exists for Wayland socket mount
PROFILE_devhw_ROOT_STARTUP='
mkdir -p /tmp/runtime-user
chmod 700 /tmp/runtime-user
chown "${U}:${U}" /tmp/runtime-user
'

# Only devhw profile when using this config
ALL_PROFILES=(devhw)
