#!/usr/bin/env bash
# SharkDeck Installer — zero-terminal for end users.
# Double-click "Install SharkDeck.desktop" or run: bash install.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

YELLOW='\033[0;33m'

info()  { echo -e "${CYAN}[sharkdeck]${NC} $*"; }
ok()    { echo -e "${GREEN}[sharkdeck]${NC} $*"; }
warn()  { echo -e "${YELLOW}[sharkdeck]${NC} $*"; }
err()   { echo -e "${RED}[sharkdeck]${NC} $*" >&2; }

# --- Pre-flight checks ---
if [[ "$(uname)" != "Linux" ]]; then
    err "SharkDeck requires Linux (SteamOS). Detected: $(uname)"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/sharkdeck-daemon" ]]; then
    err "sharkdeck-daemon not found in $SCRIPT_DIR"
    exit 1
fi

if [[ ! -d "$SCRIPT_DIR/ui" ]]; then
    err "ui/ folder not found in $SCRIPT_DIR"
    exit 1
fi

echo ""
info "${BOLD}SharkDeck Installer${NC}"
echo ""

# --- Create directories ---
info "Setting up directories..."
mkdir -p ~/.local/bin
mkdir -p ~/.config/sharkdeck/trainers
mkdir -p ~/.config/systemd/user
mkdir -p ~/.local/share/sharkdeck/{launcher,logs,cache}
mkdir -p ~/.local/share/sharkdeck/launcher/ui
mkdir -p ~/.local/share/applications
ok "Directories ready"

# --- Clean up old mugen installation ---
systemctl --user stop mugen.service 2>/dev/null || true
systemctl --user disable mugen.service 2>/dev/null || true
rm -f ~/.config/systemd/user/mugen.service 2>/dev/null
rm -f ~/.local/share/applications/mugen.desktop 2>/dev/null
rm -f ~/.local/bin/mugen-launcher 2>/dev/null
rm -f ~/.local/bin/mugen-daemon 2>/dev/null
rm -rf ~/.config/mugen-chrome 2>/dev/null

# --- Stop existing daemon if running ---
info "Stopping old daemon..."
systemctl --user stop sharkdeck.service 2>/dev/null &
STOP_PID=$!
# Wait up to 5 seconds for graceful stop
for i in 1 2 3 4 5; do
    if ! kill -0 "$STOP_PID" 2>/dev/null; then break; fi
    sleep 1
done
# If still running, force kill the daemon process directly
if kill -0 "$STOP_PID" 2>/dev/null; then
    pkill -9 -f sharkdeck-daemon 2>/dev/null || true
    wait "$STOP_PID" 2>/dev/null || true
fi
ok "Old daemon stopped"

# --- Copy daemon ---
info "Installing daemon..."
cp "$SCRIPT_DIR/sharkdeck-daemon" ~/.local/bin/sharkdeck-daemon
chmod +x ~/.local/bin/sharkdeck-daemon
ok "Daemon installed"

# --- Migrate old mugen data if it exists ---
if [[ -d ~/.config/mugen/trainers ]] || [[ -d ~/.local/share/mugen/cache ]]; then
    info "Migrating data from old install..."

    # Move cached trainer files
    if [[ -d ~/.local/share/mugen/cache/trainers ]]; then
        cp -rn ~/.local/share/mugen/cache/trainers/* ~/.local/share/sharkdeck/cache/trainers/ 2>/dev/null || true
    fi
    if [[ -d ~/.local/share/mugen/cache/deps ]]; then
        mkdir -p ~/.local/share/sharkdeck/cache/deps
        cp -rn ~/.local/share/mugen/cache/deps/* ~/.local/share/sharkdeck/cache/deps/ 2>/dev/null || true
    fi
    if [[ -d ~/.local/share/mugen/cache/prefixes ]]; then
        mkdir -p ~/.local/share/sharkdeck/cache/prefixes
        cp -rn ~/.local/share/mugen/cache/prefixes/* ~/.local/share/sharkdeck/cache/prefixes/ 2>/dev/null || true
    fi

    # Copy and fix trainer config paths (mugen → sharkdeck)
    if [[ -d ~/.config/mugen/trainers ]]; then
        for f in ~/.config/mugen/trainers/*.json; do
            [[ -f "$f" ]] || continue
            basename="$(basename "$f")"
            sed 's|/.local/share/mugen/|/.local/share/sharkdeck/|g' "$f" > ~/.config/sharkdeck/trainers/"$basename"
        done
    fi

    ok "Migration complete"
fi

# --- Install trainer hook script ---
# This script is added to Steam launch options per game.
# It reads trainer config from ~/.config/sharkdeck/trainers/<appid>.json
# and sets PROTON_REMOTE_DEBUG_CMD so the trainer starts with the game.
info "Installing trainer hook..."
cat > ~/.local/share/sharkdeck/trainer-hook.sh << 'HOOKEOF'
#!/bin/bash
# SharkDeck Trainer Hook — runs before game launch via Steam launch options.
# Set your game launch options to:
#   /home/deck/.local/share/sharkdeck/trainer-hook.sh %command%

SHARKDECK_TRAINERS="$HOME/.config/sharkdeck/trainers"
APP_ID="${SteamAppId:-0}"
TRAINER_CONFIG="$SHARKDECK_TRAINERS/$APP_ID.json"

if [[ -f "$TRAINER_CONFIG" ]]; then
    # Read trainer path from config (simple grep, no jq dependency)
    TRAINER_PATH=$(grep -o '"path": *"[^"]*"' "$TRAINER_CONFIG" | head -1 | sed 's/"path": *"\(.*\)"/\1/')
    if [[ -n "$TRAINER_PATH" && -f "$TRAINER_PATH" ]]; then
        export PROTON_REMOTE_DEBUG_CMD="'$TRAINER_PATH'"
        TRAINER_DIR=$(dirname "$TRAINER_PATH")
        # Expose trainer directory to pressure-vessel container
        if [[ -n "$PRESSURE_VESSEL_FILESYSTEMS_RW" ]]; then
            export PRESSURE_VESSEL_FILESYSTEMS_RW="$PRESSURE_VESSEL_FILESYSTEMS_RW:$TRAINER_DIR"
        else
            export PRESSURE_VESSEL_FILESYSTEMS_RW="$TRAINER_DIR"
        fi
    fi
fi

exec "$@"
HOOKEOF
chmod +x ~/.local/share/sharkdeck/trainer-hook.sh
ok "Trainer hook installed"

# --- Copy frontend files (clean old files first) ---
info "Installing launcher UI..."
rm -rf ~/.local/share/sharkdeck/launcher/ui/*
cp -r "$SCRIPT_DIR/ui/"* ~/.local/share/sharkdeck/launcher/ui/
ok "Launcher UI installed"

# --- Nuke Chrome profile so new UI loads fresh ---
# Chrome caches JS aggressively — partial clears leave stale code.
# The profile is just for SharkDeck, so nuking it is safe.
info "Resetting launcher profile..."
rm -rf ~/.config/sharkdeck-chrome
ok "Profile reset"

# --- Install winetricks (needed for trainer .NET dependencies) ---
info "Installing winetricks..."
if [[ -f ~/.local/bin/winetricks ]]; then
    ok "winetricks already present"
else
    if curl -Lo ~/.local/bin/winetricks https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks 2>/dev/null; then
        chmod +x ~/.local/bin/winetricks
        ok "winetricks installed"
    else
        warn "Could not download winetricks — trainer .NET deps may fail"
    fi
fi

# --- Set up Chrome profile (skip first-run dialogs + usage stats popup) ---
mkdir -p ~/.config/sharkdeck-chrome
touch ~/.config/sharkdeck-chrome/'First Run'
mkdir -p ~/.config/sharkdeck-chrome/Default
cat > ~/.config/sharkdeck-chrome/Default/Preferences << 'PREFEOF'
{
  "browser": {
    "check_default_browser": false,
    "has_seen_welcome_page": true
  },
  "default_search_provider_data": {
    "template_url_data": {}
  },
  "profile": {
    "default_content_setting_values": {},
    "exited_cleanly": true
  },
  "sync_promo": {
    "startup_count": 999
  }
}
PREFEOF
cat > ~/.config/sharkdeck-chrome/'Local State' << 'STATEEOF'
{
  "browser": {
    "enabled_labs_experiments": []
  },
  "user_experience_metrics": {
    "reporting_enabled": false
  }
}
STATEEOF

# --- Create launcher script (Chrome --app mode) ---
cat > ~/.local/bin/sharkdeck-launcher << 'EOF'
#!/bin/bash
# SharkDeck Launcher — opens the UI in Chrome app mode
# Flags explained:
#   --window-size=1280,800    Match Steam Deck display exactly (no zoom/resize)
#   --force-device-scale-factor=1   Prevent DPI scaling that causes zoom glitches
#   --ozone-platform=x11     Force X11 backend (Gamescope provides Xwayland)
#   --disable-gpu-compositing Prevent Chrome's own compositor fighting Gamescope
exec flatpak run com.google.Chrome \
  --app=http://127.0.0.1:7331/ui/ \
  --user-data-dir=/home/deck/.config/sharkdeck-chrome \
  --class=sharkdeck \
  --window-size=1280,800 \
  --force-device-scale-factor=1 \
  --ozone-platform=x11 \
  --disable-gpu-compositing \
  --no-first-run \
  --no-default-browser-check \
  --disable-default-apps \
  --disable-features=TranslateUI \
  --disable-background-networking \
  --disable-client-side-phishing-detection
EOF
chmod +x ~/.local/bin/sharkdeck-launcher

# --- Create .desktop entry ---
cat > ~/.local/share/applications/sharkdeck.desktop << EOF
[Desktop Entry]
Name=SharkDeck
Comment=SharkDeck Trainer Manager
Exec=$HOME/.local/bin/sharkdeck-launcher
Icon=$HOME/.local/share/sharkdeck/launcher/ui/sharkdeck-logo.png
Type=Application
Categories=Game;
Terminal=false
EOF

# --- Add SharkDeck to Steam library + set artwork ---
# Adds SharkDeck as a non-Steam shortcut directly into shortcuts.vdf so users
# never have to manually "Add a Non-Steam Game". Also copies grid artwork.
info "Adding SharkDeck to Steam library..."
LOGO="$HOME/.local/share/sharkdeck/launcher/ui/sharkdeck-logo.png"
LAUNCHER_EXE="$HOME/.local/bin/sharkdeck-launcher"

if command -v python3 &>/dev/null && [[ -f "$LOGO" ]]; then
    for USERDATA in "$HOME/.local/share/Steam/userdata"/*/; do
        [[ -d "$USERDATA" ]] || continue

        # Add SharkDeck to shortcuts.vdf if missing, return appid for grid images
        SHORTCUT_ID=$(USERDATA_DIR="$USERDATA" python3 << 'PYEOF'
import struct, os, zlib, shutil

home = os.path.expanduser("~")
userdata = os.environ.get("USERDATA_DIR", "")
vdf_path = os.path.join(userdata, "config", "shortcuts.vdf")
exe_path = os.path.join(home, ".local", "bin", "sharkdeck-launcher")
icon_path = os.path.join(home, ".local", "share", "sharkdeck", "launcher", "ui", "sharkdeck-logo.png")
app_name = "SharkDeck"

def find_sharkdeck_appid(data):
    pos = 0
    while pos < len(data):
        idx = data.lower().find(b"sharkdeck", pos)
        if idx == -1:
            return None
        search_start = max(0, idx - 300)
        chunk = data[search_start:idx]
        appid_tag = b"\x02appid\x00"
        tag_pos = chunk.rfind(appid_tag)
        if tag_pos != -1:
            abs_pos = search_start + tag_pos + len(appid_tag)
            if abs_pos + 4 <= len(data):
                appid = struct.unpack("<I", data[abs_pos:abs_pos + 4])[0]
                if appid != 0:
                    return appid
        pos = idx + 1
    return None

def generate_shortcut_id(exe, name):
    key = ('"' + exe + '"' + name).encode("utf-8")
    crc = zlib.crc32(key) & 0xFFFFFFFF
    return (crc | 0x80000000) & 0xFFFFFFFF

def build_shortcut_entry(index, appid, exe, name, icon):
    entry = b""
    entry += b"\x02" + b"appid\x00" + struct.pack("<I", appid)
    entry += b"\x01" + b"AppName\x00" + name.encode("utf-8") + b"\x00"
    entry += b"\x01" + b"Exe\x00" + ('"' + exe + '"').encode("utf-8") + b"\x00"
    start_dir = os.path.dirname(exe)
    entry += b"\x01" + b"StartDir\x00" + ('"' + start_dir + '"').encode("utf-8") + b"\x00"
    entry += b"\x01" + b"icon\x00" + icon.encode("utf-8") + b"\x00"
    entry += b"\x01" + b"ShortcutPath\x00\x00"
    entry += b"\x01" + b"LaunchOptions\x00\x00"
    entry += b"\x02" + b"IsHidden\x00" + struct.pack("<I", 0)
    entry += b"\x02" + b"AllowDesktopConfig\x00" + struct.pack("<I", 1)
    entry += b"\x02" + b"AllowOverlay\x00" + struct.pack("<I", 1)
    entry += b"\x02" + b"OpenVR\x00" + struct.pack("<I", 0)
    entry += b"\x02" + b"Devkit\x00" + struct.pack("<I", 0)
    entry += b"\x01" + b"DevkitGameID\x00\x00"
    entry += b"\x02" + b"DevkitOverrideAppID\x00" + struct.pack("<I", 0)
    entry += b"\x02" + b"LastPlayTime\x00" + struct.pack("<I", 0)
    entry += b"\x01" + b"FlatpakAppID\x00\x00"
    entry += b"\x00" + b"tags\x00" + b"\x08\x08"
    entry += b"\x08"
    return b"\x00" + str(index).encode("utf-8") + b"\x00" + entry

data = b""
if os.path.exists(vdf_path):
    with open(vdf_path, "rb") as f:
        data = f.read()

appid = find_sharkdeck_appid(data)
if appid:
    print(appid)
else:
    appid = generate_shortcut_id(exe_path, app_name)
    if os.path.exists(vdf_path):
        shutil.copy2(vdf_path, vdf_path + ".bak")
    next_index = 0
    if data:
        i = 0
        while i < len(data):
            idx = data.find(b"\x02appid\x00", i)
            if idx == -1:
                break
            next_index += 1
            i = idx + 1
    new_entry = build_shortcut_entry(next_index, appid, exe_path, app_name, icon_path)
    if data and len(data) > 2:
        insert_pos = len(data)
        while insert_pos > 0 and data[insert_pos - 1:insert_pos] == b"\x08":
            insert_pos -= 1
        new_data = data[:insert_pos] + new_entry + b"\x08\x08"
    else:
        new_data = b"\x00shortcuts\x00" + new_entry + b"\x08\x08"
    os.makedirs(os.path.dirname(vdf_path), exist_ok=True)
    with open(vdf_path, "wb") as f:
        f.write(new_data)
    print(appid)
PYEOF
)

        if [[ -n "$SHORTCUT_ID" ]]; then
            GRID_DIR="${USERDATA}config/grid"
            mkdir -p "$GRID_DIR"
            cp "$LOGO" "$GRID_DIR/${SHORTCUT_ID}p.png" 2>/dev/null || true
            cp "$LOGO" "$GRID_DIR/${SHORTCUT_ID}.png" 2>/dev/null || true
            cp "$LOGO" "$GRID_DIR/${SHORTCUT_ID}_hero.png" 2>/dev/null || true
            cp "$LOGO" "$GRID_DIR/${SHORTCUT_ID}_logo.png" 2>/dev/null || true
            cp "$LOGO" "$GRID_DIR/${SHORTCUT_ID}_icon.png" 2>/dev/null || true
            ok "SharkDeck added to Steam (appid=$SHORTCUT_ID) with artwork"
        else
            warn "Could not add SharkDeck to Steam library"
        fi
    done
else
    warn "Could not set up Steam shortcut (python3 or logo missing)"
fi

# --- Create CheatBoard launcher script ---
cat > ~/.local/bin/cheatboard-launcher << 'EOF'
#!/bin/bash
# CheatBoard — keyboard overlay for trainer hotkeys
exec flatpak run com.google.Chrome \
  --app=http://127.0.0.1:7331/ui/cheatboard \
  --user-data-dir=/home/deck/.config/cheatboard-chrome \
  --class=cheatboard \
  --window-size=1280,800 \
  --force-device-scale-factor=1 \
  --ozone-platform=x11 \
  --disable-gpu-compositing \
  --no-first-run \
  --no-default-browser-check \
  --disable-default-apps \
  --disable-features=TranslateUI \
  --disable-background-networking \
  --disable-client-side-phishing-detection
EOF
chmod +x ~/.local/bin/cheatboard-launcher

# --- Create CheatBoard .desktop entry ---
cat > ~/.local/share/applications/cheatboard.desktop << EOF
[Desktop Entry]
Name=CheatBoard
Comment=Keyboard overlay for trainer hotkeys
Exec=$HOME/.local/bin/cheatboard-launcher
Icon=$HOME/.local/share/sharkdeck/launcher/ui/cheatboard-icon.png
Type=Application
Categories=Game;
Terminal=false
EOF

# --- Add CheatBoard to Steam library ---
info "Adding CheatBoard to Steam library..."
CB_EXE="$HOME/.local/bin/cheatboard-launcher"
CB_LOGO="$HOME/.local/share/sharkdeck/launcher/ui/cheatboard-icon.png"

if command -v python3 &>/dev/null && [[ -f "$CB_LOGO" ]]; then
    for USERDATA in "$HOME/.local/share/Steam/userdata"/*/; do
        [[ -d "$USERDATA" ]] || continue

        CB_SHORTCUT_ID=$(USERDATA_DIR="$USERDATA" python3 << 'PYEOF'
import struct, os, zlib, shutil

home = os.path.expanduser("~")
userdata = os.environ.get("USERDATA_DIR", "")
vdf_path = os.path.join(userdata, "config", "shortcuts.vdf")
exe_path = os.path.join(home, ".local", "bin", "cheatboard-launcher")
icon_path = os.path.join(home, ".local", "share", "sharkdeck", "launcher", "ui", "cheatboard-icon.png")
app_name = "CheatBoard"

def find_appid_by_name(data, name):
    pos = 0
    name_lower = name.lower().encode("utf-8")
    while pos < len(data):
        idx = data.lower().find(name_lower, pos)
        if idx == -1:
            return None
        search_start = max(0, idx - 300)
        chunk = data[search_start:idx]
        appid_tag = b"\x02appid\x00"
        tag_pos = chunk.rfind(appid_tag)
        if tag_pos != -1:
            abs_pos = search_start + tag_pos + len(appid_tag)
            if abs_pos + 4 <= len(data):
                appid = struct.unpack("<I", data[abs_pos:abs_pos + 4])[0]
                if appid != 0:
                    return appid
        pos = idx + 1
    return None

def generate_shortcut_id(exe, name):
    key = ('"' + exe + '"' + name).encode("utf-8")
    crc = zlib.crc32(key) & 0xFFFFFFFF
    return (crc | 0x80000000) & 0xFFFFFFFF

def build_shortcut_entry(index, appid, exe, name, icon):
    entry = b""
    entry += b"\x02" + b"appid\x00" + struct.pack("<I", appid)
    entry += b"\x01" + b"AppName\x00" + name.encode("utf-8") + b"\x00"
    entry += b"\x01" + b"Exe\x00" + ('"' + exe + '"').encode("utf-8") + b"\x00"
    start_dir = os.path.dirname(exe)
    entry += b"\x01" + b"StartDir\x00" + ('"' + start_dir + '"').encode("utf-8") + b"\x00"
    entry += b"\x01" + b"icon\x00" + icon.encode("utf-8") + b"\x00"
    entry += b"\x01" + b"ShortcutPath\x00\x00"
    entry += b"\x01" + b"LaunchOptions\x00\x00"
    entry += b"\x02" + b"IsHidden\x00" + struct.pack("<I", 0)
    entry += b"\x02" + b"AllowDesktopConfig\x00" + struct.pack("<I", 1)
    entry += b"\x02" + b"AllowOverlay\x00" + struct.pack("<I", 1)
    entry += b"\x02" + b"OpenVR\x00" + struct.pack("<I", 0)
    entry += b"\x02" + b"Devkit\x00" + struct.pack("<I", 0)
    entry += b"\x01" + b"DevkitGameID\x00\x00"
    entry += b"\x02" + b"DevkitOverrideAppID\x00" + struct.pack("<I", 0)
    entry += b"\x02" + b"LastPlayTime\x00" + struct.pack("<I", 0)
    entry += b"\x01" + b"FlatpakAppID\x00\x00"
    entry += b"\x00" + b"tags\x00" + b"\x08\x08"
    entry += b"\x08"
    return b"\x00" + str(index).encode("utf-8") + b"\x00" + entry

data = b""
if os.path.exists(vdf_path):
    with open(vdf_path, "rb") as f:
        data = f.read()

appid = find_appid_by_name(data, app_name)
if appid:
    print(appid)
else:
    appid = generate_shortcut_id(exe_path, app_name)
    if os.path.exists(vdf_path):
        shutil.copy2(vdf_path, vdf_path + ".bak")
    next_index = 0
    if data:
        i = 0
        while i < len(data):
            idx = data.find(b"\x02appid\x00", i)
            if idx == -1:
                break
            next_index += 1
            i = idx + 1
    new_entry = build_shortcut_entry(next_index, appid, exe_path, app_name, icon_path)
    if data and len(data) > 2:
        insert_pos = len(data)
        while insert_pos > 0 and data[insert_pos - 1:insert_pos] == b"\x08":
            insert_pos -= 1
        new_data = data[:insert_pos] + new_entry + b"\x08\x08"
    else:
        new_data = b"\x00shortcuts\x00" + new_entry + b"\x08\x08"
    os.makedirs(os.path.dirname(vdf_path), exist_ok=True)
    with open(vdf_path, "wb") as f:
        f.write(new_data)
    print(appid)
PYEOF
)

        if [[ -n "$CB_SHORTCUT_ID" ]]; then
            GRID_DIR="${USERDATA}config/grid"
            mkdir -p "$GRID_DIR"
            cp "$CB_LOGO" "$GRID_DIR/${CB_SHORTCUT_ID}p.png" 2>/dev/null || true
            cp "$CB_LOGO" "$GRID_DIR/${CB_SHORTCUT_ID}.png" 2>/dev/null || true
            cp "$CB_LOGO" "$GRID_DIR/${CB_SHORTCUT_ID}_hero.png" 2>/dev/null || true
            cp "$CB_LOGO" "$GRID_DIR/${CB_SHORTCUT_ID}_logo.png" 2>/dev/null || true
            cp "$CB_LOGO" "$GRID_DIR/${CB_SHORTCUT_ID}_icon.png" 2>/dev/null || true
            ok "CheatBoard added to Steam (appid=$CB_SHORTCUT_ID) with artwork"
        else
            warn "Could not add CheatBoard to Steam library"
        fi
    done
else
    warn "Could not set up CheatBoard Steam shortcut (python3 or logo missing)"
fi

# --- Install systemd service ---
info "Setting up auto-start..."
cat > ~/.config/systemd/user/sharkdeck.service << 'EOF'
[Unit]
Description=SharkDeck Daemon
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=%h/.local/bin/sharkdeck-daemon
Restart=always
RestartSec=5
TimeoutStopSec=5
Environment=RUST_LOG=info

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable sharkdeck.service
systemctl --user start sharkdeck.service
ok "Daemon running and set to auto-start on boot"

# --- Enable lingering (survive logout/reboot) ---
if command -v loginctl &>/dev/null; then
    loginctl enable-linger "$(whoami)" 2>/dev/null || true
fi

# --- Verify ---
echo ""
echo "============================================"
echo ""

sleep 2
if curl -sf http://127.0.0.1:7331/health >/dev/null 2>&1; then
    ok "${BOLD}SharkDeck installed successfully!${NC}"
    echo ""
    ok "The daemon is running in the background."
    ok "It will auto-start every time you turn on your Deck."
    echo ""
    info "Restart Steam, then launch SharkDeck from your library."
else
    err "Something went wrong. The daemon didn't start."
    err "Try rebooting your Deck and running this installer again."
fi

echo ""
