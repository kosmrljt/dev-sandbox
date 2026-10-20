#!/usr/bin/env bash
# setup-root.sh — runs as ROOT during the profile build (dev-sandbox TOOLS stage).
# Installs the RE toolchain into the IMAGE, so a rebuild refreshes it. Volumes hold
# only user state (Claude login, caches, XFCE/VNC config).
#
# Design:
#   - Downloaded/compiled tools (JDK, Ghidra, .NET, pycdc, GUI apps) -> /opt + a
#     symlink in /usr/local/bin (on PATH for dev; no PATH editing needed).
#   - OUR scripts are NOT copied: they live in /opt/ctx (COPYed by the Dockerfile)
#     and we just symlink them into /usr/local/bin. Single source, no duplication.
#   - JDK 21 is made the DEFAULT java (Fedora 44 ships java-25, which Ghidra can't
#     use); nothing else here needs Java, so 21 as default is safe.
#
# OFFLINE option: drop installers into ./vendor and they're used instead of
# downloading (see vendor/README.md). GUI-app installs are best-effort (|| true):
# a changed URL never hard-fails the build; check GUI-TOOLS.md if one is missing.

set -euxo pipefail

CTX=/opt/ctx                 # where the Dockerfile COPYed this directory
VENDOR="$CTX/vendor"
mkdir -p /usr/local/bin /usr/share/applications

dl() {  # dl <url> <out> — download helper (proxy-friendly curl)
    curl -fsSL -o "$2" "$1"
}
gh_asset() {  # gh_asset <owner/repo> <regex> — print first matching asset URL of latest release
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
        | grep -o "https://[^\"]*$2" | head -n1
}

# --- JDK 21, made the default java -------------------------------------------
arch="$(uname -m)"; case "$arch" in x86_64) AQ=x64;; aarch64) AQ=aarch64;; *) AQ="$arch";; esac
JDK_TGZ="$(ls "$VENDOR"/*jdk*21*linux*.tar.gz "$VENDOR"/OpenJDK21*.tar.gz 2>/dev/null | head -n1 || true)"
if [[ -n "$JDK_TGZ" ]]; then echo "Using local JDK 21: $JDK_TGZ"; cp "$JDK_TGZ" /tmp/jdk21.tgz
else dl "https://api.adoptium.net/v3/binary/latest/21/ga/linux/${AQ}/jdk/hotspot/normal/eclipse" /tmp/jdk21.tgz; fi
mkdir -p /opt/jdk21
tar -xzf /tmp/jdk21.tgz -C /opt/jdk21 --strip-components=1
rm /tmp/jdk21.tgz
# Make 21 the default java for everything (there is no other JDK in the image).
for b in java javac jar keytool; do ln -sf "/opt/jdk21/bin/$b" "/usr/local/bin/$b"; done
export JAVA_HOME=/opt/jdk21
export PATH="/opt/jdk21/bin:$PATH"

# --- Ghidra ------------------------------------------------------------------
GHIDRA_ZIP="$(ls "$VENDOR"/ghidra_*_PUBLIC_*.zip 2>/dev/null | head -n1 || true)"
if [[ -n "$GHIDRA_ZIP" ]]; then echo "Using local Ghidra: $GHIDRA_ZIP"; cp "$GHIDRA_ZIP" /tmp/ghidra.zip
else dl "$(gh_asset NationalSecurityAgency/ghidra 'ghidra_[^"]*_PUBLIC_[^"]*\.zip')" /tmp/ghidra.zip; fi
unzip -q /tmp/ghidra.zip -d /opt
mv /opt/ghidra_*_PUBLIC /opt/ghidra
rm /tmp/ghidra.zip
ln -sf /opt/ghidra/support/analyzeHeadless /usr/local/bin/analyzeHeadless
ln -sf /opt/ghidra/ghidraRun /usr/local/bin/ghidraRun

# PyGhidra: Ghidra 12.x removed Jython, so Python GhidraScripts (ExportJson.py,
# DecompileAll.py, ContextPack.py) only run via PyGhidra. Install the pip package
# that ships WITH this Ghidra (version-matched, offline from the bundled dist);
# fall back to PyPI. The `pyghidra` launcher this provides imports+analyzes a
# binary and runs a .py script against it (our wrappers use it instead of
# analyzeHeadless, whose headless mode cannot start PyGhidra).
PYG_DIST="$(ls -d /opt/ghidra/Ghidra/Features/PyGhidra/pypkg/dist 2>/dev/null | head -n1 || true)"
if [[ -n "$PYG_DIST" ]]; then
    pip install --break-system-packages --no-index -f "$PYG_DIST" pyghidra \
        || pip install --break-system-packages pyghidra || true
else
    pip install --break-system-packages pyghidra || true
fi

# --- .NET SDK + ilspycmd (C# CLI decompiler) ---------------------------------
export DOTNET_ROOT=/opt/dotnet
if [[ -d "$VENDOR/dotnet" ]]; then echo "Using local .NET SDK"; cp -a "$VENDOR/dotnet" /opt/dotnet
else dl https://dot.net/v1/dotnet-install.sh /tmp/dotnet-install.sh
     bash /tmp/dotnet-install.sh --channel LTS --install-dir /opt/dotnet; rm /tmp/dotnet-install.sh; fi
/opt/dotnet/dotnet tool install ilspycmd --tool-path /opt/dotnet-tools
ln -sf /opt/dotnet/dotnet /usr/local/bin/dotnet
ln -sf /opt/dotnet-tools/ilspycmd /usr/local/bin/ilspycmd

# --- pycdc / pycdas (.pyc decompiler) ----------------------------------------
if [[ -d "$VENDOR/pycdc" ]]; then echo "Using local pycdc"; cp -a "$VENDOR/pycdc" /tmp/pycdc
else git clone --depth 1 https://github.com/zrax/pycdc /tmp/pycdc; fi
cmake -S /tmp/pycdc -B /tmp/pycdc/build
cmake --build /tmp/pycdc/build -j"$(nproc)"
install -m755 /tmp/pycdc/build/pycdc  /usr/local/bin/pycdc
install -m755 /tmp/pycdc/build/pycdas /usr/local/bin/pycdas
rm -rf /tmp/pycdc

# --- GhidraMCP (bethington fork): rich data-type tools + matching bridge ------
# We use bethington/ghidra-mcp rather than upstream LaurieWired because it adds
# the data-type tools the native-code rebuild loop needs: create_struct,
# create_union, create_enum, add/modify/remove_struct_field, apply_data_type,
# create_typedef, set_function_prototype, and so on.
#
# Two parts, both from the SAME source checkout so plugin and bridge share one
# protocol version:
#   (a) the Ghidra PLUGIN (Java extension) -> serves REST on http://127.0.0.1:8089
#   (b) the BRIDGE `bridge-mcp-ghidra` (stdio MCP server) that Claude Code launches
#
# The plugin is version-locked to Ghidra, so we build it from source against the
# installed Ghidra (12.1.4). Build backend is Maven (hence `maven` in the DNF
# list); `uv` is installed because the project's setup helper expects it.
# Best-effort: if the build can't fetch its deps, MCP is simply absent (see
# docs/GUIDE.md to build it by hand).
( pip install --break-system-packages uv || true
  git clone --depth 1 https://github.com/bethington/ghidra-mcp /tmp/ghidra-mcp-b
  cd /tmp/ghidra-mcp-b
  # Copy the installed Ghidra's jars into ~/.m2 (local, no network), then build.
  python3 -m tools.setup ensure-prereqs --ghidra-path /opt/ghidra
  python3 -m tools.setup build
  # Install the built extension system-wide so Ghidra lists it under Extensions.
  unzip -q -o target/GhidraMCP-*.zip -d /opt/ghidra/Ghidra/Extensions
  # Install the matching Python bridge -> `bridge-mcp-ghidra` on PATH.
  pip install --break-system-packages .
  cd / && rm -rf /tmp/ghidra-mcp-b
  echo "GhidraMCP (bethington) installed: extension + bridge-mcp-ghidra" ) \
  || echo "WARN: GhidraMCP (bethington) not installed - see docs/GUIDE.md to build it manually"

# --- Python analysis libraries (used by review/ and python/ helper scripts) ---
# numpy/pillow/matplotlib: arrays, image handling, plots (COP curves, trajectories).
# opencv-python-headless: pixel-diff a screenshot against a reconstruction.
# pefile/lief: parse PE sections/resources (Delphi .dfm forms + strings live in
# resources and point at event handlers -> good entry points). capstone: quick
# disassembly without Ghidra.
pip install --break-system-packages \
    numpy pillow matplotlib opencv-python-headless \
    pefile capstone lief || true

# =============================================================================
# GUI decompile tools (for the VNC desktop). Best-effort: a changed URL won't
# fail the build. jadx-gui (Java) is clean; Cutter/ImHex use AppImages; .NET has
# no clean Linux GUI, so ilspycmd (CLI) + Geany is the primary .NET path.
# =============================================================================

# Cutter — radare2 GUI (native). AppImage, run with extract-and-run (no FUSE).
( CUT="$(ls "$VENDOR"/Cutter-*.AppImage 2>/dev/null | head -n1 || true)"
  [[ -n "$CUT" ]] && cp "$CUT" /opt/Cutter.AppImage \
    || dl "$(gh_asset rizinorg/cutter 'Cutter-[^"]*Linux-x86_64\.AppImage')" /opt/Cutter.AppImage
  chmod +x /opt/Cutter.AppImage
  printf '#!/bin/sh\nexec /opt/Cutter.AppImage --appimage-extract-and-run "$@"\n' > /usr/local/bin/cutter
  chmod +x /usr/local/bin/cutter ) || echo "WARN: Cutter not installed"

# ImHex — hex editor for RE (native). AppImage, extract-and-run.
( IMH="$(ls "$VENDOR"/imhex-*.AppImage 2>/dev/null | head -n1 || true)"
  [[ -n "$IMH" ]] && cp "$IMH" /opt/ImHex.AppImage \
    || dl "$(gh_asset WerWolv/ImHex 'imhex-[^"]*x86_64\.AppImage')" /opt/ImHex.AppImage
  chmod +x /opt/ImHex.AppImage
  printf '#!/bin/sh\nexec /opt/ImHex.AppImage --appimage-extract-and-run "$@"\n' > /usr/local/bin/imhex
  chmod +x /usr/local/bin/imhex ) || echo "WARN: ImHex not installed"

# jadx-gui — Java/APK decompiler GUI (uses our JDK 21).
( JZ="$(ls "$VENDOR"/jadx-*.zip 2>/dev/null | head -n1 || true)"
  [[ -n "$JZ" ]] && cp "$JZ" /tmp/jadx.zip \
    || dl "$(gh_asset skylot/jadx 'jadx-[0-9][^"]*\.zip')" /tmp/jadx.zip
  mkdir -p /opt/jadx && unzip -q /tmp/jadx.zip -d /opt/jadx && rm /tmp/jadx.zip
  ln -sf /opt/jadx/bin/jadx     /usr/local/bin/jadx
  ln -sf /opt/jadx/bin/jadx-gui /usr/local/bin/jadx-gui ) || echo "WARN: jadx not installed"

# Editor: Geany (from dnf, in PROFILE_decompile_DNF) — lightweight, GTK, stable
# under VNC. VSCode/VSCodium (Electron) is intentionally NOT installed: under VNC
# in a container it needs --no-sandbox/--disable-gpu and still tends to crash the
# desktop. Edit on the host against the bind-mounted project for a full IDE.

# ILSpy GUI (.NET): no clean Linux package. Primary .NET path is ilspycmd (above)
# + viewing the decompiled C# project in VSCodium. See GUI-TOOLS.md to build
# AvaloniaILSpy from source if you want the GUI.

# --- Ghidra post-scripts: point scriptPath at the ctx copy (no duplication) --
ln -sfn "$CTX/scripts" /opt/scripts

# --- OUR scripts: symlink from /opt/ctx into /usr/local/bin (no copying) ------
# Force +x on the executables (COPY preserves source mode, which may be 0644;
# `chmod -R a+rX` would NOT add x to a non-executable file, so set it explicitly).
chmod -R a+rX "$CTX"
# Every file in scripts/ (decompile-init, ghidra-mcp-up, td32-import and the
# extension-less ghidra-bg included) becomes a command on PATH.
chmod 0755 "$CTX"/scripts/* 2>/dev/null || true
for s in "$CTX"/scripts/*; do
    [ -f "$s" ] && ln -sf "$s" "/usr/local/bin/$(basename "$s")"
done
# decompile-init reads its starter files straight from the ctx docs copy.
# (its DOC default is /opt/ctx/docs — no /usr/local/share copy needed)

# --- Desktop launchers (system-wide; appear in the XFCE menu) -----------------
mk_desktop() {  # mk_desktop <name> <exec> <comment>
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
# Geany ships its own /usr/share/applications/geany.desktop from dnf.

# --- GTK/desktop caches: handled by RPM file triggers, NOT by hand ------------
# The dnf packages (gdk-pixbuf2, shared-mime-info, hicolor-icon-theme, glib2,
# desktop-file-utils) ship %transfiletriggerin triggers that rebuild
# loaders.cache / mime.cache / icon caches / gschemas.compiled on install.
# Verified by A/B test: built automatically, so we do NOT run them here.
#
# Fedora 44: there is no gdk-pixbuf SVG loader anymore (librsvg2 dropped it;
# GTK4 uses glycin, GTK3 falls back to PNG icons). Rebuilding the pixbuf cache
# would register no SVG loader regardless, so there is nothing to do.
#
# The earlier "Wnck Bail out" desktop crash was NOT a missing loader: it was a
# full /tmp (a small RAM tmpfs) failing a pixbuf-cache write ("No space left on
# device"). Fixed by keeping /tmp disk-backed - see PROFILE_decompile_PODMAN_ARGS.

echo "setup-root.sh done - toolchain in the image, scripts symlinked from /opt/ctx."
