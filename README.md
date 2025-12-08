# Twoggler - Alt+Tab alternative for MacOS

<p align="center">
  <img src=".github/icon.png" alt="Twoggler Logo" width="100"/>
</p>

A simple macOS window switcher app similar to Windows alt+tab. Switch between **windows** (across all apps) using **Cmd+Tab**.

Twoggler offers three display modes to suit your preference:
- **Icons** - Compact view showing application icons
- **List** - Detailed list view with window titles
- **Thumbnails** - Visual preview of window contents (requires Screen Recording permission)

<p align="center">
  <img src=".github/formats.png" alt="Twoggler Modes" width="50%"/>
</p>

## Installing

1. Download `Twoggler.app.zip` from the [Releases page](https://github.com/romulorvs/Twoggler/releases).
2. Unzip the file.
3. Drag `Twoggler` to your **Applications** folder.
4. Open `Twoggler`.

## Usage

1. Run the app — you'll see the `Twoggler` icon in the menu bar
2. Press `Cmd+Tab` to open the switcher and cycle forward
3. Press `Cmd+Shift+Tab` to cycle backward
4. Release keys to focus on selected window
5. Choose mode (`Icons`, `Thumbnails`, `List`) from the menu bar icon.
6. Set UI placement: `All Screens`, `Active Screen`, or `Mouse Position`.
7. Customize the keyboard shortcuts.

## Starting at Login (Recommended)

It is recommended to have Twoggler to start automatically when you log in:

1. Open **System Settings** → **General** → **Login Items**
2. Under "Open at Login", click the **+** button
3. Navigate to `/Applications/Twoggler` and click **Open**

## Permissions

On first run, the app will request **Accessibility** permission. You need to:

1. Go to **System Settings** → **Privacy & Security** → **Accessibility**
2. Enable **Twoggler**
3. You may need to restart the app after granting permission

If permission is not granted, an alert dialog will appear with a button to open System Settings.

**Note:** Screen Recording permission is required for `Thumbnails` mode.

## Building

```bash
# Build the application
./build.sh

# Copy to Applications
cp -r .build/Twoggler.app /Applications/

# Or run directly
open .build/Twoggler.app
```

## Requirements

- macOS 12.0 or later
- Accessibility permission (required for hotkeys and window management)