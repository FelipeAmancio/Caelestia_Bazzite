#!/usr/bin/bash
set -Eeuo pipefail

# Build-time overlay for a HyprBazzite-based bootc image.
# Intended to run as root from the image-template Containerfile.

WORKDIR="$(mktemp -d /tmp/caelestia-build.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { printf '\n\033[1;34m[caelestia-image]\033[0m %s\n' "$*"; }

log 'Enabling the Quickshell COPR and installing runtime/build dependencies'
dnf5 -y copr enable errornointernet/quickshell
dnf5 -y install --setopt=install_weak_deps=False \
  quickshell \
  cmake ninja-build gcc gcc-c++ make git meson python3-pip python3-devel pkgconf-pkg-config curl \
  aubio-devel libqalculate-devel qt6-qtdeclarative-devel qt6-qtbase-devel \
  qt6-qtshadertools-devel qt6-qtimageformats pipewire-devel iniparser-devel \
  fftw-devel lm_sensors-devel brightnessctl fish swappy \
  google-rubik-fonts cascadia-code-nf-fonts

log 'Building libcava for Caelestia'
git clone --depth 1 https://github.com/LukashonakV/cava.git "$WORKDIR/cava"
meson setup "$WORKDIR/cava/build" "$WORKDIR/cava" \
  --prefix=/usr/local \
  --libdir=lib64 \
  --buildtype=release \
  -Dwarning_level=1

if ! meson compile -C "$WORKDIR/cava/build" --verbose \
    > "$WORKDIR/cava-build.log" 2>&1; then
  echo "ERRO: a compilação do Cava falhou. Diagnóstico:"
  tail -n 120 "$WORKDIR/cava-build.log"
  exit 1
fi

meson install -C "$WORKDIR/cava/build"

CAVA_PC=/usr/local/lib64/pkgconfig/libcava.pc
if [[ ! -f "$CAVA_PC" ]]; then
  echo "ERROR: Expected libcava pkg-config file at $CAVA_PC, but it was not created." >&2
  find /usr/local -name '*cava*.pc' -print >&2 || true
  exit 1
fi
# The shell includes <cava/cavacore.h>; make the include parent directory visible
# to pkg-config in addition to the subdirectory emitted by this Cava fork.
sed -i '/^Cflags:/s|Cflags: |Cflags: -I${includedir} |' "$CAVA_PC"
export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

log 'Installing app2unit'
git clone --depth 1 https://github.com/Vladimir-csp/app2unit.git "$WORKDIR/app2unit"
make -C "$WORKDIR/app2unit" PREFIX=/usr/local install

log 'Installing the Caelestia CLI'
git clone --depth 1 https://github.com/caelestia-dots/cli.git "$WORKDIR/caelestia-cli"
python3 -m pip install --break-system-packages --prefix=/usr/local "$WORKDIR/caelestia-cli"

log 'Fetching the Bazzite-specific Caelestia configuration and shell fork'
git clone --depth 1 https://github.com/spundone/hyprbazzite-config.git "$WORKDIR/hyprbazzite-config"
# Do not shallow-clone the shell: its CMake build derives VERSION from git tags.
git clone https://github.com/28allday/nosignal-shell.git "$WORKDIR/nosignal-shell"

# This configuration repo keeps these two source overrides as patches.
# Fail clearly if the shell fork has moved the expected customization point.
if [[ ! -d "$WORKDIR/nosignal-shell/modules/nexus/pages/wallandstyle" ]]; then
  echo "ERROR: nosignal-shell layout changed; review the ColourSelect.qml override before continuing." >&2
  exit 1
fi
install -D -m 0644 \
  "$WORKDIR/hyprbazzite-config/caelestia-overrides/ColourSelect.qml" \
  "$WORKDIR/nosignal-shell/modules/nexus/pages/wallandstyle/ColourSelect.qml"
install -D -m 0644 \
  "$WORKDIR/hyprbazzite-config/caelestia-overrides/shell.qml" \
  "$WORKDIR/nosignal-shell/shell.qml"

log 'Compiling and installing the Caelestia shell system-wide'
cmake -S "$WORKDIR/nosignal-shell" -B "$WORKDIR/nosignal-shell/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/ \
  -DINSTALL_LIBDIR=/usr/lib64/caelestia \
  -DINSTALL_QMLDIR=/usr/lib64/qt6/qml \
  -DINSTALL_QSCONFDIR=/usr/share/quickshell/caelestia
cmake --build "$WORKDIR/nosignal-shell/build" --parallel "$(nproc)"
cmake --install "$WORKDIR/nosignal-shell/build"

log 'Installing fonts used by the Caelestia widgets'
install -d -m 0755 /usr/share/fonts/caelestia
curl --fail --location --retry 3 \
  'https://github.com/google/material-design-icons/raw/refs/heads/master/variablefont/MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf' \
  --output /usr/share/fonts/caelestia/MaterialSymbolsRounded.ttf
fc-cache -f

log 'Creating the default desktop configuration and first-login seeder'
PRESETS=/usr/share/caelestia-presets
install -d -m 0755 "$PRESETS/bin" "$PRESETS/hypr" "$PRESETS/caelestia"
install -m 0644 \
  "$WORKDIR/hyprbazzite-config/hypr/hyprland.lua" \
  "$PRESETS/hyprland.lua"
install -m 0644 \
  "$WORKDIR/hyprbazzite-config/caelestia/shell.json" \
  "$PRESETS/shell.json"

# Copy the helper scripts, but replace the upstream per-user shell wrapper with
# one that launches the shell installed in /usr/share by this image build.
for file in "$WORKDIR"/hyprbazzite-config/bin/*; do
  [[ -f "$file" ]] || continue
  [[ "$(basename "$file")" == 'caelestia-shell' ]] && continue
  install -m 0755 "$file" "$PRESETS/bin/$(basename "$file")"
done
cat > "$PRESETS/bin/caelestia-shell" <<'WRAPPER'
#!/usr/bin/bash
export QML2_IMPORT_PATH="/usr/lib64/qt6/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export LD_LIBRARY_PATH="/usr/lib64/caelestia:/usr/local/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CAELESTIA_LIB_DIR=/usr/lib64/caelestia
export QT_QPA_PLATFORM=wayland
exec quickshell -p /usr/share/quickshell/caelestia/shell.qml "$@"
WRAPPER
chmod 0755 "$PRESETS/bin/caelestia-shell"

# New accounts get the preset directly from /etc/skel.
install -D -m 0644 "$PRESETS/hyprland.lua" /etc/skel/.config/hypr/hyprland.lua
install -D -m 0644 "$PRESETS/shell.json" /etc/skel/.config/caelestia/shell.json
for file in "$PRESETS"/bin/*; do
  install -D -m 0755 "$file" "/etc/skel/.local/bin/$(basename "$file")"
done

# Existing accounts are seeded once at their next graphical login. Existing
# Hyprland config files are never overwritten.
cat > /usr/libexec/caelestia-seed-user-config <<'SEEDER'
#!/usr/bin/bash
set -Eeuo pipefail
PRESETS=/usr/share/caelestia-presets
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia-bazzite"
[[ -e "$STATE_DIR/seeded" ]] && exit 0
mkdir -p "$HOME/.config/hypr" "$HOME/.config/caelestia" "$HOME/.local/bin" "$STATE_DIR"
if [[ ! -e "$HOME/.config/hypr/hyprland.lua" && ! -e "$HOME/.config/hypr/hyprland.conf" ]]; then
  install -m 0644 "$PRESETS/hyprland.lua" "$HOME/.config/hypr/hyprland.lua"
fi
if [[ ! -e "$HOME/.config/caelestia/shell.json" ]]; then
  install -m 0644 "$PRESETS/shell.json" "$HOME/.config/caelestia/shell.json"
fi
for file in "$PRESETS"/bin/*; do
  install -m 0755 "$file" "$HOME/.local/bin/$(basename "$file")"
done
touch "$STATE_DIR/seeded"
SEEDER
chmod 0755 /usr/libexec/caelestia-seed-user-config

install -d -m 0755 /etc/xdg/autostart
cat > /etc/xdg/autostart/caelestia-seed.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Caelestia first-login configuration
Comment=Seed the Caelestia configuration for this user once
Exec=/usr/libexec/caelestia-seed-user-config
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP

# Provide an explicit session selector entry on SDDM/KDE-based Bazzite.
install -d -m 0755 /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/hyprland-caelestia.desktop <<'SESSION'
[Desktop Entry]
Name=Hyprland (Caelestia)
Comment=Hyprland desktop with the Caelestia shell
Exec=Hyprland
TryExec=Hyprland
Type=Application
DesktopNames=Hyprland
SESSION

log 'Checking the critical executables and cleaning the temporary COPR setting'
command -v quickshell >/dev/null
command -v caelestia >/dev/null
command -v Hyprland >/dev/null

dnf5 -y copr disable errornointernet/quickshell || true
ldconfig || true

log 'Caelestia overlay installation finished'
