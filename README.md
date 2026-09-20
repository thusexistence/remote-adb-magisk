# Remote ADB Wi-Fi Bootstrap

A Magisk service module for Android 11+ that restores Wi-Fi, starts Android's native TLS wireless debugging, and optionally reports the dynamic ADB endpoint to a computer on the same LAN.

## Features

- Waits for Android to finish booting and unlock credential-encrypted storage.
- Enables Wi-Fi and gives saved-network auto-connect up to 60 seconds.
- Falls back to an explicit Wi-Fi connection and waits up to 120 seconds.
- Retries failed Wi-Fi rounds every 15 seconds instead of exiting permanently.
- Starts native Android TLS wireless debugging without disabling ADB authentication.
- Saves the active endpoint to `/data/local/tmp/remote-adb-address.txt`.
- Optionally reports the endpoint to `windows-adb-receiver.ps1` every 20 seconds.
- Preserves private settings across module upgrades.

## Requirements

- Android 11 or later (SDK 30+)
- Magisk or a compatible fork
- Root access
- One successful native wireless-debugging pairing with the controlling computer

## Private configuration

Network credentials are deliberately not stored in the public module ZIP. Create this root-only file on the phone:

```text
/data/adb/remote-adb.conf
```

Use `remote-adb-magisk/remote-adb.conf.example` as the template:

```sh
WIFI_SSID='YOUR_WIFI_SSID'
WIFI_SECURITY='wpa2'
WIFI_PASSWORD='YOUR_WIFI_PASSWORD'
WIFI_BSSID=''

# Optional. Leave empty to disable endpoint reporting.
REPORT_HOST='192.168.1.100'
REPORT_PORT='39393'
REPORT_INTERVAL='20'

WIFI_AUTOCONNECT_WAIT='60'
WIFI_CONNECT_WAIT='120'
WIFI_RETRY_DELAY='15'
WIFI_POLL_INTERVAL='2'
```

Protect it after copying:

```sh
su -c 'chown 0:0 /data/adb/remote-adb.conf; chmod 600 /data/adb/remote-adb.conf'
```

When upgrading from v1.1.x, `customize.sh` migrates the old embedded values into this file automatically before replacing the module.

## Build

From Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-remote-adb-module.ps1
```

This creates:

```text
remote-adb-magisk-v1.2.1.zip
remote-adb-magisk.zip
```

Generated ZIP files are intentionally excluded from Git. Release ZIPs belong in GitHub Releases.

## Install or upgrade one phone

Install the ZIP in the Magisk application, or from an existing rooted ADB connection:

```sh
adb push remote-adb-magisk-v1.2.1.zip /data/local/tmp/
adb shell "su -c 'magisk --install-module /data/local/tmp/remote-adb-magisk-v1.2.1.zip'"
adb reboot
```

The module ID remains `remote_adb`, so Magisk upgrades the existing installation in place.

## Upgrade a device fleet from Windows

Preview detected devices without changing them:

```powershell
.\update-remote-adb-all.ps1 -ListOnly
```

Recommended rollout:

1. Run `update_remote_adb_one_and_reboot.bat` and enter one physical device ID.
2. Confirm that the canary phone reappears in `adb devices` after reboot.
3. Run `update_remote_adb_all.bat` to stage the update everywhere without rebooting.
4. Reboot in a controlled batch, or use `update_remote_adb_all_and_reboot.bat` after the canary succeeds.

The updater deduplicates changing wireless endpoints by `ro.serialno` and only targets devices that already have the `remote_adb` module.

## Windows endpoint receiver

Start the receiver on the computer whose private LAN address is configured as `REPORT_HOST`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows-adb-receiver.ps1
```

The receiver listens on TCP `39393`, validates private IPv4 endpoint reports, and calls `adb connect IP:PORT`.

## Logs and diagnostics

On the phone:

```sh
cat /data/local/tmp/remote-adb.log
cat /data/local/tmp/remote-adb-address.txt
```

## Online updates

`module.prop` points Magisk to:

```text
https://raw.githubusercontent.com/thusexistence/remote-adb-magisk/main/update.json
```

`update.json` publishes the current `version`, monotonically increasing `versionCode`, release ZIP URL, and changelog URL. Pushing a `v*` tag runs the release workflow and attaches the generated module ZIP to a GitHub Release.

## Security notes

- Never commit `/data/adb/remote-adb.conf` or real Wi-Fi credentials.
- The module does not disable ADB authentication and does not expose a fixed unauthenticated ADB port.
- Endpoint reporting is plaintext and is intended only for a trusted private LAN.
- No software license is granted unless a license file is added later.
