# Remote ADB Wi-Fi Bootstrap

## 1.2.1

- Change the Magisk module author metadata to the GitHub username `thusexistence`.

## 1.2.0

- Wait up to 60 seconds for Android's saved-network auto-connect.
- After an explicit connect request, wait up to 120 seconds for an IPv4 address.
- Retry failed Wi-Fi connection rounds every 15 seconds instead of exiting permanently.
- Reconnect persistently if Wi-Fi loses its IPv4 address while the service is running.
- Move private Wi-Fi and receiver settings to `/data/adb/remote-adb.conf`.
- Migrate embedded v1.1.x settings during an in-place Magisk upgrade.
- Add fleet update scripts and GitHub update metadata.
