<p align="center">
  <img src="ui/sharkdeck-logo.png" width="280" alt="SharkDeck Logo">
</p>

<p align="center"><strong>Game trainers on Steam Deck, no terminal required.</strong></p>

<p align="center">
  <a href="https://github.com/tekkenfreya/SharkDeck/releases/download/1.0.1/sharkdeck-install.zip">
    <img src="https://img.shields.io/badge/Download-SharkDeck-1a5fa8?style=for-the-badge&logo=steam&logoColor=white" alt="Download SharkDeck">
  </a>
</p>

---

## What is SharkDeck?

SharkDeck lets you search, download, and run game trainers (cheats) on your Steam Deck — entirely from the UI, no terminal needed.

## Install

1. Download and extract the ZIP to your Steam Deck
2. Double-click **`Install SharkDeck.desktop`**
3. Restart Steam
4. **SharkDeck** appears in your Steam library

That's it. The daemon runs in the background and auto-starts on boot.

## How to Use

1. Launch **SharkDeck** from your Steam library
2. Search for your game
3. Pick a trainer and tap **Enable**
4. Launch your game — the trainer starts automatically
5. Use Steam's controller mapping to bind trainer hotkeys (F1, Num1, etc.)

## Uninstall

Double-click **`Uninstall SharkDeck.desktop`**, or run in Konsole:
```bash
systemctl --user stop sharkdeck && systemctl --user disable sharkdeck && rm -rf ~/.local/bin/sharkdeck-* ~/.config/sharkdeck* ~/.config/sharkdeck-chrome ~/.local/share/sharkdeck ~/.config/systemd/user/sharkdeck.service && systemctl --user daemon-reload
```

## Requirements

- Steam Deck (SteamOS 3.x)
- Google Chrome Flatpak (pre-installed on SteamOS)

---

<p align="center"><sub>Made by <a href="https://github.com/tekkenfreya">tekkenfreya</a></sub></p>
