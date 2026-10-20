# vendor/ — optional local installers (for offline / no-network builds)

`setup-root.sh` uses whatever is here instead of downloading. Leave it empty to
download from the official sources at build time.

- `*jdk*21*linux*.tar.gz` — an Eclipse Temurin JDK 21 tarball (e.g.
  `OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz`). Used instead of downloading from
  Adoptium. Ghidra 12.x needs JDK 21; Fedora 44 no longer ships it, so this is
  how you keep it offline/pinned.
- `ghidra_*_PUBLIC_*.zip` — a Ghidra release zip. Used instead of the GitHub
  release. Runs on the private /opt/jdk21 installed by setup-root.sh.
- `pycdc/` — a local checkout of https://github.com/zrax/pycdc (built here).
- `dotnet/` — a pre-extracted .NET SDK dir (copied to /opt/dotnet). Advanced;
  normally the .NET install script from dot.net is fine.
- GUI tools (optional, for offline): `Cutter-*Linux-x86_64.AppImage`,
  `imhex-*x86_64.AppImage`, `jadx-*.zip`.
# Note: GhidraMCP (bethington fork) is built from source at image-build time
# (Maven, against the installed Ghidra), so it needs network for its build deps
# and has no vendor slot here. For a fully offline build, build it once on a
# machine with network and install the resulting target/GhidraMCP-*.zip plus the
# bridge by hand (see docs/GUIDE.md).

Nothing here is committed by default; this folder just needs to exist.
