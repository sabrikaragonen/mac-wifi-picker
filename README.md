# WiFi Picker

A macOS menu bar app that switches you to the best Wi-Fi you already know.

macOS keeps whichever network it joined first and stays there, even when a
better one is in range. WiFi Picker reads the networks macOS has already saved,
checks which of them are actually nearby, and moves you to the best one. You
give each network a **High**, **Normal**, or **Low** priority from the menu.
Nothing to configure and no SSID lists to maintain — your saved networks are
the list.

- iPhone hotspots default to Low, so you don't burn cellular data by accident.
- On a Low network, it upgrades as soon as a known Normal/High network is in range.
- On a healthy High network, it stays put.
- Switching between equal-priority networks needs a 12 dB signal gain, two
  consecutive readings, and a 15-minute cooldown, so it won't flap.

## Install

Requires macOS 12+ and Apple's command line tools
(`xcode-select --install` if `swiftc` is missing).

```bash
git clone https://github.com/sabrikaragonen/mac-wifi-picker.git
cd mac-wifi-picker
./install.sh
```

That builds `~/Applications/WiFi Picker.app`, launches it, and registers a login
agent so it starts with your Mac. Re-run the same script to update.

## First run

Look for the circled Wi-Fi icon in the menu bar — that's how you tell it apart
from macOS's own. Open it, choose **Enable nearby Wi-Fi scanning…**, and allow
Location access. macOS requires Location permission before any app can read
nearby SSIDs; the app never uses your position for anything else. Notifications
are optional.

## The menu

Current network and last check status, **Find better Wi-Fi now**, **Refresh
nearby networks**, and the nearby known networks with their priority. Toggles,
the full saved-network history, and the log live under **Settings**.

Every three minutes the app pings the current connection to judge its health,
scans for nearby networks without disconnecting, ranks the candidates by
priority and signal, then switches to at most one of them and verifies it. If
that network turns out to be worse, it goes back.

One Wi-Fi adapter can scan other networks while connected, but it cannot test
another network's real internet path without briefly joining it — which is why
only a single pre-selected candidate is ever tried.

Settings: `~/Library/Application Support/WiFi Picker/config.json`
Log: `~/Library/Logs/wifi-picker.log`

## Uninstall

```bash
./uninstall.sh
```

Your settings and log are left behind.

## License

Apache License 2.0. See [LICENSE](LICENSE).
