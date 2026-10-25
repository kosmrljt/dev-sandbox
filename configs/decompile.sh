# decompile.sh — dev-sandbox profile for binary reverse engineering, with a
# VNC desktop for the Ghidra GUI.
#
# The scripts ship in ./decompile_src (next to this config). 
# To refresh after editing ./decompile_src:  rm -rf ~/.dev-sandbox/decompile/ctx
# (the next run re-stages, which changes ctx and triggers a rebuild).
#
# Layout:
#   <dir>/
#     decompile.conf
#     decompile_src/          <- source of truth (survives `clean`)
#       setup-root.sh
#       scripts/  (decompile-init, ghidra-mcp-up, td32-import, exportjson.sh, ...)
#       docs/  vendor/
#
# Use:    dev-sandbox --config decompile.sh
# Connect: VNC client -> 127.0.0.1:5901 (password $SANDBOX_VNC_PASS, default "sandbox").

# --- Auto-stage into ctx/ only when it's missing (first run / after clean) -----
_CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CTX="${SANDBOX_BASE:-$HOME/.dev-sandbox}/decompile/ctx"
if [[ ! -d "$_CTX" && -d "${_CONF_DIR}/decompile_src" ]]; then
    mkdir -p "$_CTX"
    cp -a "${_CONF_DIR}/decompile_src/." "$_CTX/"
fi

PROFILE_decompile_DESCRIPTION="RE sandbox — Ghidra via VNC, radare2, ilspycmd, python decompilers + Claude Code"
PROFILE_decompile_COLOR="35"
PROFILE_decompile_USE_KRUN=false
PROFILE_decompile_SSH_PORT=2232

PROFILE_decompile_DNF=(
    tigervnc-server
    xfwm4 xfce4-session xfce4-panel xfce4-terminal xfdesktop xfconf xfce4-settings thunar
    dbus-x11 xorg-x11-xinit
    dejavu-sans-fonts dejavu-serif-fonts fontconfig
    gdk-pixbuf2 shared-mime-info
    gtk-update-icon-cache desktop-file-utils hicolor-icon-theme adwaita-icon-theme
    geany
    file binutils radare2 binwalk perl-Image-ExifTool
    maven
    libicu
    ffmpeg-free tesseract tesseract-langpack-fra
    libxkbcommon mesa-libGL mesa-libEGL libglvnd-opengl
)

# ROOT stage (before USER dev) — installs the RE toolchain into the image, so a
# rebuild refreshes it. Nothing is written to ~/.local at build.
PROFILE_decompile_TOOLS=(
    "bash /opt/ctx/setup-root.sh"
)

# DEV stage (as dev) — Claude Code via its native installer into ~/.local/bin.
PROFILE_decompile_AGENTS=(
    "curl -fsSL https://claude.ai/install.sh | bash"
)

PROFILE_decompile_ENV=(
    "DISPLAY=:1"
    "GHIDRA_HOME=/opt/ghidra"
    "GHIDRA_INSTALL_DIR=/opt/ghidra"
    "JAVA_HOME=/opt/jdk21"
    "JAVA_HOME_OVERRIDE=/opt/jdk21"
    "DOTNET_ROOT=/opt/dotnet"
    "DOTNET_ROLL_FORWARD=Major"
    "DOTNET_CLI_TELEMETRY_OPTOUT=1"
)

PROFILE_decompile_VOLUMES=(
    .claude
    .cache
    .config
    .vnc
)

PROFILE_decompile_PODMAN_ARGS=(
    --shm-size 2g
    -p 127.0.0.1:5901:5901
    --tmpfs /var/log:rw,size=50m,mode=1777
)

PROFILE_decompile_ROOT_STARTUP="${PROFILE_vncgui_ROOT_STARTUP}"

# Set as the sole and default profile for this config
ALL_PROFILES=(decompile)
