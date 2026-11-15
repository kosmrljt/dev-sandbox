#!/usr/bin/env bash
# ==============================================================================
# setup-root.sh — Installs the Reverse Engineering toolchain (runs as ROOT)
# ==============================================================================
# Architecture:
#   - Binaries & tools (Ghidra, .NET, pycdc, GUI apps) -> /opt + symlink in /usr/local/bin
#   - Project scripts -> stay in /opt/ctx (symlinked to /usr/local/bin, no duplication)
#   - Java 25 -> provided via DNF (required by Ghidra 12.2+)
#   - Offline support -> place installers in ./vendor to skip downloads
#   - GUI apps -> best-effort (|| true); URL failures only trigger a warning
# ==============================================================================

set -euo pipefail

# --- Temporary Home & Pip Configuration ---------------------------------------
# Redirects all caches (.cache/pip, .cache/uv, .m2, .nuget, .dotnet) into /tmp
# so they can be wiped at the end of the container RUN layer.
export HOME=/tmp/root-home
mkdir -p "$HOME"
export PIP_BREAK_SYSTEM_PACKAGES=1

CTX=/opt/ctx
VENDOR="$CTX/vendor"
mkdir -p /usr/local/bin /usr/share/applications

# --- Colored Logging Helpers --------------------------------------------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_BLUE='\033[1;34m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'

log_section() { printf "\n${C_BLUE}======================================================================${C_RESET}\n${C_CYAN}  ==> %s${C_RESET}\n${C_BLUE}======================================================================${C_RESET}\n" "$1"; }
log_info()    { printf "${C_BOLD}  [i]${C_RESET} %s\n" "$1"; }
log_ok()      { printf "${C_GREEN}  [✓] %s${C_RESET}\n" "$1"; }
log_warn()    { printf "${C_YELLOW}  [!] WARN: %s${C_RESET}\n" "$1" >&2; }

# --- Download Helpers ---------------------------------------------------------
dl() {
    log_info "Downloading: $1"
    curl -fsSL -o "$2" "$1"
}

gh_asset() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
        | grep -o "https://[^\"]*$2" | head -n1
}


# ==============================================================================
# [1/9] Ghidra & PyGhidra
# ==============================================================================
# Set GHIDRA_URL and GHIDRA_SHA256 to pin a specific version, otherwise the
# latest release is fetched automatically.
log_section "[1/9] Installing Ghidra & PyGhidra"

GHIDRA_URL="${GHIDRA_URL:-}"
GHIDRA_SHA256="${GHIDRA_SHA256:-}"
GHIDRA_ZIP="$(ls "$VENDOR"/ghidra_*_PUBLIC_*.zip 2>/dev/null | head -n1 || true)"

if [[ -n "$GHIDRA_ZIP" ]]; then
    log_info "Using local Ghidra archive: $GHIDRA_ZIP"
    cp "$GHIDRA_ZIP" /tmp/ghidra.zip
elif [[ -n "$GHIDRA_URL" ]]; then
    dl "$GHIDRA_URL" /tmp/ghidra.zip
else
    dl "$(gh_asset NationalSecurityAgency/ghidra 'ghidra_[^"]*_PUBLIC_[^"]*\.zip')" /tmp/ghidra.zip
fi

if [[ -n "$GHIDRA_SHA256" ]]; then
    log_info "Verifying Ghidra SHA256 checksum..."
    echo "$GHIDRA_SHA256  /tmp/ghidra.zip" | sha256sum -c -
fi

log_info "Extracting Ghidra to /opt/ghidra..."
unzip -q /tmp/ghidra.zip -d /opt
mv /opt/ghidra_*_PUBLIC /opt/ghidra
rm /tmp/ghidra.zip
ln -sf /opt/ghidra/support/analyzeHeadless /usr/local/bin/analyzeHeadless
ln -sf /opt/ghidra/ghidraRun /usr/local/bin/ghidraRun
log_ok "Ghidra installed"

# Ghidra 12.x replaced Jython with PyGhidra. Prefer the bundled wheel to match versions.
log_info "Installing PyGhidra launcher..."
PYG_DIST="$(ls -d /opt/ghidra/Ghidra/Features/PyGhidra/pypkg/dist 2>/dev/null | head -n1 || true)"
if [[ -n "$PYG_DIST" ]]; then
    pip install --no-index -f "$PYG_DIST" pyghidra || pip install pyghidra
else
    pip install pyghidra
fi
log_ok "PyGhidra installed"


# ==============================================================================
# [2/9] .NET SDK & ilspycmd (C# CLI Decompiler)
# ==============================================================================
log_section "[2/9] Installing .NET SDK & ilspycmd"

export DOTNET_ROOT=/opt/dotnet
if [[ -d "$VENDOR/dotnet" ]]; then
    log_info "Using local .NET SDK from vendor/"
    cp -a "$VENDOR/dotnet" /opt/dotnet
else
    dl https://dot.net/v1/dotnet-install.sh /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel LTS --install-dir /opt/dotnet
    rm /tmp/dotnet-install.sh
fi

log_info "Installing ilspycmd tool..."
/opt/dotnet/dotnet tool install ilspycmd --tool-path /opt/dotnet-tools
ln -sf /opt/dotnet/dotnet /usr/local/bin/dotnet
ln -sf /opt/dotnet-tools/ilspycmd /usr/local/bin/ilspycmd
log_ok ".NET SDK & ilspycmd installed"


# ==============================================================================
# [3/9] pycdc / pycdas (Python Bytecode Decompiler)
# ==============================================================================
log_section "[3/9] Building pycdc / pycdas (.pyc decompiler)"

if [[ -d "$VENDOR/pycdc" ]]; then
    log_info "Using local pycdc source from vendor/"
    cp -a "$VENDOR/pycdc" /tmp/pycdc
else
    log_info "Cloning pycdc repository..."
    git clone --depth 1 https://github.com/zrax/pycdc /tmp/pycdc
fi

cmake -S /tmp/pycdc -B /tmp/pycdc/build
cmake --build /tmp/pycdc/build -j"$(nproc)"
install -m755 /tmp/pycdc/build/pycdc  /usr/local/bin/pycdc
install -m755 /tmp/pycdc/build/pycdas /usr/local/bin/pycdas
rm -rf /tmp/pycdc
log_ok "pycdc & pycdas built and installed"


# ==============================================================================
# [4/9] GhidraMCP (bethington fork)
# ==============================================================================
# Provides rich data-type manipulation tools (structs, unions, enums, prototypes).
# Builds both from the same checkout to keep protocol versions in sync:
#   1. Java Ghidra Extension (REST server on 127.0.0.1:8089)
#   2. Python stdio MCP bridge (`bridge-mcp-ghidra`) for Claude Code
# Pin via GHIDRA_MCP_REF (commit/tag) if needed. Best-effort install.
log_section "[4/9] Building GhidraMCP Extension & Bridge"

GHIDRA_MCP_REF="${GHIDRA_MCP_REF:-}"
(
    pip install uv || true
    if [[ -n "$GHIDRA_MCP_REF" ]]; then
        log_info "Cloning bethington/ghidra-mcp (pinned to $GHIDRA_MCP_REF)..."
        git clone https://github.com/bethington/ghidra-mcp /tmp/ghidra-mcp-b
        git -C /tmp/ghidra-mcp-b checkout --detach "$GHIDRA_MCP_REF"
    else
        log_info "Cloning bethington/ghidra-mcp (latest)..."
        git clone --depth 1 https://github.com/bethington/ghidra-mcp /tmp/ghidra-mcp-b
    fi
    cd /tmp/ghidra-mcp-b
    log_info "Setting up Ghidra JAR dependencies & compiling plugin with Maven..."
    python3 -m tools.setup ensure-prereqs --ghidra-path /opt/ghidra
    python3 -m tools.setup build
    unzip -q -o target/GhidraMCP-*.zip -d /opt/ghidra/Ghidra/Extensions
    log_info "Installing Python MCP bridge..."
    pip install .
    cd / && rm -rf /tmp/ghidra-mcp-b
    log_ok "GhidraMCP installed (Java extension + bridge-mcp-ghidra)"
) || log_warn "GhidraMCP not installed — see docs/GUIDE.md to build manually"


# ==============================================================================
# [5/9] Python Analysis Libraries
# ==============================================================================
# - numpy / scipy / matplotlib : numeric analysis & plotting
# - pillow / opencv-headless   : image processing & visual diffing
# - pefile / lief              : PE headers, sections & Delphi .dfm resource parsing
# - capstone / unicorn         : fast disassembly & single-function CPU emulation
# - pyinstxtractor-ng          : PyInstaller unpacking (unfreeze-python.sh)
# - duckdb                     : required by `outq sql` for querying exports/Parquet/CSV
log_section "[5/9] Installing Python RE & Analysis Libraries"

log_info "Installing scientific & binary analysis packages..."
pip install \
    numpy pillow matplotlib opencv-python-headless \
    pefile capstone lief pyinstxtractor-ng unicorn \
    scipy || log_warn "Some optional Python analysis libraries failed to install"

log_info "Installing DuckDB (required for outq sql)..."
pip install duckdb
log_ok "Python analysis libraries installed"


# ==============================================================================
# [6/9] yq v4 (mikefarah)
# ==============================================================================
# Standalone Go binary that preserves YAML comments when editing decompile.yaml
# (unlike the distro jq-wrapper package).
log_section "[6/9] Installing yq (YAML Processor)"

YQ_VER=v4.44.3
YQ_SHA=a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7
if [[ -f "$VENDOR/yq_linux_amd64" ]]; then
    log_info "Using local yq from vendor/"
    cp "$VENDOR/yq_linux_amd64" /tmp/yq
else
    dl "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_amd64" /tmp/yq
fi
echo "${YQ_SHA}  /tmp/yq" | sha256sum -c -
install -m755 /tmp/yq /usr/local/bin/yq && rm -f /tmp/yq
log_ok "yq ${YQ_VER} installed"


# ==============================================================================
# [7/9] GUI Reverse Engineering Tools (VNC Desktop)
# ==============================================================================
# Best-effort installs. AppImages use --appimage-extract-and-run (no FUSE needed).
# Note: Geany (GTK) is installed via DNF as the lightweight VNC editor.
log_section "[7/9] Installing GUI Tools (Cutter, ImHex, jadx)"

# --- Cutter (Rizin/radare2 GUI) ---
(
    log_info "Installing Cutter..."
    CUT="$(ls "$VENDOR"/Cutter-*.AppImage 2>/dev/null | head -n1 || true)"
    [[ -n "$CUT" ]] && cp "$CUT" /opt/Cutter.AppImage \
        || dl "$(gh_asset rizinorg/cutter 'Cutter-[^"]*Linux-x86_64\.AppImage')" /opt/Cutter.AppImage
    chmod +x /opt/Cutter.AppImage
    printf '#!/bin/sh\nexec /opt/Cutter.AppImage --appimage-extract-and-run "$@"\n' > /usr/local/bin/cutter
    chmod +x /usr/local/bin/cutter
    log_ok "Cutter installed"
) || log_warn "Cutter not installed"

# --- ImHex (Hex Editor) ---
(
    log_info "Installing ImHex..."
    IMH="$(ls "$VENDOR"/imhex-*.AppImage 2>/dev/null | head -n1 || true)"
    [[ -n "$IMH" ]] && cp "$IMH" /opt/ImHex.AppImage \
        || dl "$(gh_asset WerWolv/ImHex 'imhex-[^"]*x86_64\.AppImage')" /opt/ImHex.AppImage
    chmod +x /opt/ImHex.AppImage
    printf '#!/bin/sh\nexec /opt/ImHex.AppImage --appimage-extract-and-run "$@"\n' > /usr/local/bin/imhex
    chmod +x /usr/local/bin/imhex
    log_ok "ImHex installed"
) || log_warn "ImHex not installed"

# --- jadx-gui (Java/APK Decompiler) ---
(
    log_info "Installing jadx..."
    JZ="$(ls "$VENDOR"/jadx-*.zip 2>/dev/null | head -n1 || true)"
    [[ -n "$JZ" ]] && cp "$JZ" /tmp/jadx.zip \
        || dl "$(gh_asset skylot/jadx 'jadx-[0-9][^"]*\.zip')" /tmp/jadx.zip
    mkdir -p /opt/jadx && unzip -q /tmp/jadx.zip -d /opt/jadx && rm /tmp/jadx.zip
    ln -sf /opt/jadx/bin/jadx     /usr/local/bin/jadx
    ln -sf /opt/jadx/bin/jadx-gui /usr/local/bin/jadx-gui
    log_ok "jadx & jadx-gui installed"
) || log_warn "jadx not installed"


# ==============================================================================
# [8/9] Mermaid.js (Offline Architecture Diagrams)
# ==============================================================================
log_section "[8/9] Fetching Mermaid.js for Offline Docs"

MERMAID_VER=11.17.2
MERMAID_SHA=581ed7d74bd9048d0e3a91363927d72ef22942d7722546b27f7cc29e35390eb8
MERMAID_DIR="$CTX/init/skills/re-doc/vendor"

if [ -d "$MERMAID_DIR" ] && [ ! -f "$MERMAID_DIR/mermaid.min.js" ]; then
    if curl -fsSL "https://cdn.jsdelivr.net/npm/mermaid@${MERMAID_VER}/dist/mermaid.min.js" -o /tmp/mermaid.min.js \
       && echo "${MERMAID_SHA}  /tmp/mermaid.min.js" | sha256sum -c - >/dev/null 2>&1; then
        mv /tmp/mermaid.min.js "$MERMAID_DIR/mermaid.min.js"
        curl -fsSL "https://cdn.jsdelivr.net/npm/mermaid@${MERMAID_VER}/LICENSE" -o "$MERMAID_DIR/LICENSE-mermaid.txt" || true
        log_ok "Mermaid ${MERMAID_VER} cached for offline use"
    else
        log_warn "Mermaid ${MERMAID_VER} download/checksum failed; archdoc.py will fall back to CDN"
        rm -f /tmp/mermaid.min.js
    fi
else
    log_info "Mermaid directory not present or file already exists — skipping"
fi


# ==============================================================================
# [9/9] Symlinks, Desktop Launchers & Cleanup
# ==============================================================================
log_section "[9/9] Wiring Scripts & XFCE Desktop Launchers"

# Point Ghidra post-scripts to /opt/ctx/scripts
ln -sfn "$CTX/scripts" /opt/scripts

# Ensure executable permissions and symlink all helper scripts into PATH
chmod -R a+rX "$CTX"
chmod 0755 "$CTX"/scripts/* 2>/dev/null || true
for s in "$CTX"/scripts/*; do
    [ -f "$s" ] && ln -sf "$s" "/usr/local/bin/$(basename "$s")"
done
log_ok "Helper scripts symlinked from $CTX/scripts to /usr/local/bin"

# Create XFCE application menu entries (GTK/icon caches are auto-handled by RPM triggers)
mk_desktop() {
    cat > "/usr/share/applications/$1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$1
Exec=$2
Comment=$3
Terminal=false
Categories=Development;Utility;
Icon=applications-engineering
EOF
}
mk_desktop Ghidra  /usr/local/bin/ghidraRun "Software reverse engineering suite"
mk_desktop Cutter  /usr/local/bin/cutter    "radare2 GUI"
mk_desktop ImHex   /usr/local/bin/imhex     "Hex editor for reverse engineers"
mk_desktop jadx    /usr/local/bin/jadx-gui  "Java/APK decompiler"
log_ok "XFCE desktop launchers created"

# Wipe temporary home and caches if not already handled by caller
log_info "Cleaning up temporary build files in /tmp..."
rm -rf /tmp/* /tmp/.[!.]* 2>/dev/null || true

printf "\n${C_GREEN}======================================================================${C_RESET}\n"
printf "${C_GREEN}  [✓] setup-root.sh complete — RE toolchain ready!${C_RESET}\n"
printf "${C_GREEN}======================================================================${C_RESET}\n\n"
