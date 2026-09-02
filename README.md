# 🔔 Omarchy Notifications Settings

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Omarchy Quattro](https://img.shields.io/badge/Omarchy-Quattro-blue)](https://omarchy.com)

A high-performance, feature-packed notification daemon, status bar control panel, and UI replacement for Omarchy Quattro (Quickshell).

Provides seamless 1-click 2FA/OTP code copying, 6 flexible screen positions, smart channel/conversation grouping, persistent chat alerts, live preview tester, and a hardened zero-trust persistence and rendering architecture.

---

## ✨ Features

- 🎛️ **Dedicated Bar Widget & Control Panel:**
  - Placed anywhere on your status bar (`left`, `center`, or `right`).
  - When placed in the center section, it seamlessly reveals on hover alongside your other utility indicators.
  - Left-click opens the configuration popup; right-click quickly toggles **Do Not Disturb** mode.
- 📋 **Automatic 2FA / OTP Code Extraction & 1-Click Copy:**
  - Automatically parses incoming verification notifications (Google, GitHub, Slack, Signal, Steam, Discord, banks, and more) for one-time passcodes and security tokens.
  - Automatically strips service prefixes (e.g. `G-492019` becomes pure `492019`) so you copy only the numbers you need to enter.
  - Injects a native, prominent **"Copy Code: XXXXXX"** button directly on the notification card.
  - Copies directly to your Wayland clipboard via `wl-copy` with instant visual confirmation (`✓ Copied to Clipboard!`).
- 📐 **6 Dynamic Screen Positions:**
  - Easily place notification toasts anywhere on your screen:
    - **Top Left**, **Top Center**, **Top Right**
    - **Bottom Left**, **Bottom Center**, **Bottom Right**
  - Card alignment, stacking order, and status bar clearance adjust automatically.
- 🗂️ **Smart Notification Grouping:**
  - **1 Per Channel (Default):** Keeps at most 1 active alert per channel or conversation (e.g. messages in `#dev` and `#general` stay separate, but rapid posts in `#dev` won't flood your screen).
  - **1 Per App:** Keeps 1 alert per application total (newer alerts from the same app supersede older ones).
  - **All Alerts:** Displays all incoming notifications without deduplication.
- 🏷️ **Conversation & Channel Badges:**
  - Automatically identifies channels and groups from DBus hints (`tag`, `x-kde-tag`, `group`) and title syntax.
  - Displays a clean accent-colored breadcrumb badge (`Slack · [ #dev ]`) right on the card.
- ⏱️ **Configurable Display Timeouts:**
  - Choose auto-dismiss timing: **3s**, **5s**, **8s**, **12s**, or **15s**.
- 💬 **Sticky Chat Alerts:**
  - Messaging apps like **Slack** and **Signal** stay visible until dismissed so you never miss urgent communications.
- 👁️ **Live Notification Preview:**
  - One-click **"Preview Notification Toast"** button inside the settings panel lets you immediately test your active position, duration, grouping, and OTP copy button in real time.
- 💾 **Session Resilience & History:**
  - Survives shell reloads and restarts, restoring live popups without duplicating expired toasts. Replay recent notifications at any time.

---

## 🔒 Security & Hardened Architecture

This plugin adheres to strict security and privilege boundary standards:

1. **No Executable Payload Data:**
   - Arbitrary command execution hints (such as `omarchy-exec`) have been completely removed.
   - Notification cards never execute shell commands when clicked. Standard client callbacks use the native FreeDesktop `default` action invoked over DBus within the originating client's process boundary.
2. **Hard Producer-Side Field & Cardinality Bounds:**
   - String inputs are capped before entering QML (`app` <= 64B, `summary` <= 256B, `body` <= 2048B, `glyph` <= 8B, `channel` <= 64B, `appIcon` <= 256B, `image` <= 512B).
   - Dangerous ASCII control characters are stripped.
   - Active toast cardinality is capped to a maximum of 20 concurrent popups (`maxActivePopups = 20`) to prevent UI resource exhaustion.
3. **Hardened Text Sinks:**
   - All text sinks in `NotificationCard.qml` explicitly specify `textFormat: Text.PlainText`. Default `AutoText` and `StyledText` markup rendering are disabled, eliminating HTML/rich-text injection vectors.
4. **Strict Image Scheme Allowlist:**
   - App icons and images are verified before loading: only local files (`file:///` or `/`), in-process `image://` providers, or standard themed icon names are permitted.
   - Remote URL schemes (`http://`, `https://`, `data:`, `qrc:`, etc.) and path traversal sequences (`..`) are strictly rejected.
5. **Private Descriptor & Atomic State Persistence (`scripts/storage.sh`):**
   - Verified private directories (`~/.local/state/omarchy/notifications/`, `history/`, `images/`) are initialized with mode `0700` (`umask 077`) and verified not to be symlinks.
   - Notification and settings writes use exclusive temporary files in the same directory (`0600`) followed by atomic rename (`mv -f`).
   - Bounded reads (`head -c 32768`) reject symlinks (`! -L`) and enforce strict timestamp-id filename matching (`^[0-9]+-[0-9]+\.json$`).

---

## 📦 Dependencies

All dependencies are standard in default Omarchy installations:
- **Quickshell** (included in Omarchy Quattro)
- **wl-clipboard** (`wl-copy` for 1-click OTP clipboard copying)
- **libnotify** (`notify-send` for preview simulations)
- **Nerd Font** (system icon glyphs)

---

## 🚀 Replacement Notification Server Setup

Because only one service can own the `org.freedesktop.Notifications` DBus session name at a time, this plugin acts as a **complete drop-in replacement** for the built-in `omarchy.notifications` service.

### 1. Installation

Clone this repository into your Omarchy plugins directory:

```bash
git clone https://github.com/andrewscofield/omarchy-notification-settings.git ~/.config/omarchy/plugins/andrewscofield.notifications-settings
```

### 2. Enable in Shell Configuration

Edit `~/.config/omarchy/shell.json`:
- Add `"andrewscofield.notifications-settings"` to `"plugins"`
- Add `"omarchy.notifications"` to `"disabledPlugins"` (disables stock daemon so this plugin claims DBus `org.freedesktop.Notifications`)

```json
{
  "plugins": [
    { "id": "andrewscofield.notifications-settings" }
  ],
  "disabledPlugins": [
    "omarchy.notifications"
  ]
}
```

### 3. Add to Bar Layout (Optional)

To place the notification bell directly in your bar, add it to `bar.layout` in `~/.config/omarchy/shell.json`:

```json
{
  "bar": {
    "layout": {
      "center": [
        { "id": "andrewscofield.notifications-settings" },
        { "id": "omarchy.clock" }
      ]
    }
  }
}
```

*(Note: If you use `andrew.indicators`, the DND indicator can also directly trigger the settings panel).*

### 4. Restart Shell

Restart Omarchy Quattro to activate the replacement notification daemon:

```bash
omarchy restart shell
```

---

## 🔄 Reverting to Stock Notifications

If you ever wish to switch back to the default Omarchy notification daemon:

1. In `~/.config/omarchy/shell.json`:
   - Remove `"omarchy.notifications"` from `"disabledPlugins"`
   - Remove `"andrewscofield.notifications-settings"` from `"plugins"` and `"bar.layout"`
2. Restart the shell:
   ```bash
   omarchy restart shell
   ```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
