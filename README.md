# 🔔 Omarchy Notifications Settings

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Omarchy Quattro](https://img.shields.io/badge/Omarchy-Quattro-blue)](https://omarchy.com)

A high-performance, feature-packed notification daemon, bar control panel, and UI replacement for Omarchy Quattro (Quickshell).

Provides seamless 1-click 2FA/OTP code copying, 6 flexible screen positions, smart channel/conversation grouping, persistent chat alerts, and an interactive live preview panel.

---

## ✨ Features

- 🎛️ **Dedicated Bar Widget & Control Panel:**
  - Placed anywhere on your status bar (`left`, `center`, or `right`).
  - When in the center section, it seamlessly reveals on hover alongside your other utility indicators.
  - Left-click opens the configuration popup; right-click quickly toggles **Do Not Disturb** mode.
- 📋 **Automatic 2FA / OTP Code Extraction & 1-Click Copy:**
  - Automatically parses incoming verification notifications (Google, GitHub, Slack, Signal, Steam, Discord, banks, and more) for one-time passcodes and security tokens.
  - Injects a native, prominent **"Copy Code: XXXXXX"** button directly on the notification card.
  - Copies directly to your Wayland clipboard via `wl-copy` with instant visual confirmation (`✓ Copied to Clipboard!`).
- 📐 **6 Dynamic Screen Positions:**
  - Easily place notification toasts anywhere on your screen:
    - **Top Left**, **Top Center**, **Top Right**
    - **Bottom Left**, **Bottom Center**, **Bottom Right**
  - Card alignment and status bar clearance adjust automatically.
- 🗂️ **Smart Notification Grouping:**
  - **1 Per Channel (Default):** Keeps at most 1 active alert per channel or conversation (e.g. messages in `#dev` and `#general` stay separate, but rapid posts in `#dev` won't flood your screen).
  - **1 Per App:** Keeps 1 alert per application total (newer alerts from the same app supersede older ones).
  - **All Alerts:** Displays all incoming notifications without deduplication.
- 🏷️ **Conversation & Channel Badges:**
  - Automatically identifies channels and groups from DBus hints (`tag`, `x-kde-tag`) and title syntax.
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

## 📦 Dependencies

All dependencies are standard in default Omarchy installations:
- **Quickshell** (included in Omarchy Quattro)
- **wl-clipboard** (`wl-copy` for 1-click OTP clipboard copying)
- **libnotify** (`notify-send` for preview simulations)
- **Nerd Font** (system icon glyphs)

---

## 🚀 Installation

### Option 1: Via Omaplug / Marketplace
Search for **Omarchy Notifications Settings** in the Omarchy Plugin Manager (`omaplug`) or on [omarchyplugins.com](https://omarchyplugins.com) and click **Install**.

### Option 2: Manual Git Installation
Clone this repository directly into your Omarchy plugins directory:

```bash
git clone https://github.com/your-username/omarchy-notifications-settings.git ~/.config/omarchy/plugins/andrew.notifications-settings
```

Enable the plugin in `~/.config/omarchy/shell.json`:

```json
{
  "plugins": [
    { "id": "andrew.notifications-settings" }
  ],
  "disabledPlugins": [
    "omarchy.notifications"
  ]
}
```

Then reload the shell:

```bash
omarchy restart shell
```

---

## 📌 Status Bar Setup

To add the notification bell icon to your status bar, add `andrew.notifications-settings` to `bar.layout` in `~/.config/omarchy/shell.json`:

```json
{
  "bar": {
    "layout": {
      "center": [
        { "id": "andrew.notifications-settings" },
        { "id": "omarchy.clock" }
      ]
    }
  }
}
```

*Note: You can also place it in `"left"` or `"right"`, or leave it in `"center"` to reveal on hover alongside your indicators.*

---

## 🗑️ Uninstallation

To remove the plugin:

1. Remove `"andrew.notifications-settings"` from `~/.config/omarchy/shell.json`.
2. Remove `"omarchy.notifications"` from `"disabledPlugins"` if you wish to revert to stock notifications.
3. Delete the plugin directory:
   ```bash
   rm -rf ~/.config/omarchy/plugins/andrew.notifications-settings
   ```
4. Restart the shell:
   ```bash
   omarchy restart shell
   ```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
