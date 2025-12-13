# Navi - Alt+Tab alternative for MacOS

<p align="center">
  <img src=".github/icon.png" alt="Navi Logo" width="100"/>
</p>

A simple macOS window switcher app similar to Windows alt+tab. Switch between **windows** (across all apps) using **Cmd+Tab**.

> **Note:** This project was 100% created by AI as an experiment in AI-assisted software development.


Navi offers three display modes to suit your preference:
- **Icons** - Compact view showing application icons
- **List** - Detailed list view with window titles
- **Thumbnails** - Visual preview of window contents (requires Screen Recording permission)

<p align="center">
  <img src=".github/formats.png" alt="Navi Modes" width="700px" />
</p>

## Installing

Run the following command on your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/romulorvs/Navi/main/install.sh | bash
```

## Usage

1. Run the app — you'll see the `Navi` icon in the menu bar
2. Press `Cmd+Tab` to open the switcher and cycle forward
3. Press `Cmd+Shift+Tab` to cycle backward
4. Release keys to focus on selected window
5. Choose mode (`Icons`, `Thumbnails`, `List`) from the menu bar icon.
6. Set UI placement: `All Screens`, `Active Screen`, or `Mouse Position`.
7. Customize the keyboard shortcuts.

## Starting at Login (Recommended)

It is recommended to have Navi to start automatically when you log in:

1. Open **System Settings** → **General** → **Login Items**
2. Under "Open at Login", click the **+** button
3. Navigate to `/Applications/Navi` and click **Open**

## Permissions

On first run, the app will request **Accessibility** permission. You need to:

1. Go to **System Settings** → **Privacy & Security** → **Accessibility**
2. Enable **Navi**
3. You may need to restart the app after granting permission

If permission is not granted, an alert dialog will appear with a button to open System Settings.

**Note:** Screen Recording permission is required for `Thumbnails` mode.

## Building

```bash
# Build the application
./build.sh

# Copy to Applications
cp -r .build/Navi.app /Applications/

# Or run directly
open .build/Navi.app
```

## Requirements

- macOS 14.0 or later
- Accessibility permission (required for hotkeys and window management)