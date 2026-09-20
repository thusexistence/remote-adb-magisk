#!/system/bin/sh

# Android 11+ / Magisk
# Manual run: su -c /data/adb/service.d/remote-adb.sh
# Boot run:   install as /data/adb/service.d/remote-adb.sh, chmod 700

# ---- Configuration ---------------------------------------------------------
# Keep private network credentials outside the module directory so Magisk
# upgrades can safely replace the module without publishing or losing them.
CONFIG_FILE='/data/adb/remote-adb.conf'
WIFI_SSID=''
WIFI_SECURITY='wpa2'
WIFI_PASSWORD=''
WIFI_BSSID=''
REPORT_HOST=''
REPORT_PORT='39393'
REPORT_INTERVAL='20'

# Give Android and the access point enough time to finish boot-time Wi-Fi
# initialization.  A failed round is retried forever instead of terminating
# the Magisk service until the next reboot.
WIFI_AUTOCONNECT_WAIT='60'
WIFI_CONNECT_WAIT='120'
WIFI_RETRY_DELAY='15'
WIFI_POLL_INTERVAL='2'

if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

LOG_FILE='/data/local/tmp/remote-adb.log'
ADDRESS_FILE='/data/local/tmp/remote-adb-address.txt'

# ---- Helpers ---------------------------------------------------------------
umask 077

log() {
    message="$*"
    echo "$message"
    echo "$message" >>"$LOG_FILE"
}

get_wifi_ip() {
    ip -4 -o addr show wlan0 scope global 2>/dev/null |
        awk 'NR == 1 { split($4, address, "/"); print address[1] }'
}

get_tls_port() {
    getprop service.adb.tls.port 2>/dev/null
}

valid_port() {
    case "$1" in
        ''|0|-1|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

wait_for_wifi_ip() {
    timeout="$1"
    elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if [ -n "$(get_wifi_ip)" ]; then
            return 0
        fi
        sleep "$WIFI_POLL_INTERVAL"
        elapsed=$((elapsed + WIFI_POLL_INTERVAL))
    done

    return 1
}

enable_wifi_and_connect() {
    log 'Enabling Wi-Fi'
    svc wifi enable

    # First allow Android to reconnect to a previously saved network.
    log "Waiting up to ${WIFI_AUTOCONNECT_WAIT}s for Android Wi-Fi auto-connect"
    if wait_for_wifi_ip "$WIFI_AUTOCONNECT_WAIT"; then
        return 0
    fi

    if [ -z "$WIFI_SSID" ]; then
        log "WARNING: WIFI_SSID is not configured in $CONFIG_FILE"
        return 1
    fi

    log "Connecting to Wi-Fi: $WIFI_SSID ($WIFI_BSSID)"
    if [ -n "$WIFI_BSSID" ]; then
        cmd wifi connect-network "$WIFI_SSID" "$WIFI_SECURITY" "$WIFI_PASSWORD" \
            -b "$WIFI_BSSID" >>"$LOG_FILE" 2>&1
    else
        cmd wifi connect-network "$WIFI_SSID" "$WIFI_SECURITY" "$WIFI_PASSWORD" \
            >>"$LOG_FILE" 2>&1
    fi

    log "Waiting up to ${WIFI_CONNECT_WAIT}s for a Wi-Fi IPv4 address"
    wait_for_wifi_ip "$WIFI_CONNECT_WAIT"
}

connect_wifi_until_ready() {
    attempt=1
    while ! enable_wifi_and_connect; do
        log "WARNING: Wi-Fi connection attempt ${attempt} failed; retrying in ${WIFI_RETRY_DELAY}s"
        attempt=$((attempt + 1))
        sleep "$WIFI_RETRY_DELAY"
    done
}

enable_native_wireless_debugging() {
    # Start Android 11+'s native TLS wireless-debugging server directly,
    # without opening the Settings confirmation dialog.
    if command -v resetprop >/dev/null 2>&1; then
        resetprop persist.adb.tls_server.enable 1
    else
        setprop persist.adb.tls_server.enable 1
    fi

    # Safe when this is run by Magisk or a phone-local root terminal.
    stop adbd
    sleep 1
    start adbd
}

report_endpoint() {
    device_id="$1"
    endpoint="$2"
    payload="ADB|${device_id}|${endpoint}|$(date +%s)"

    # Reporting is optional. The endpoint is still written to ADDRESS_FILE.
    if [ -z "$REPORT_HOST" ]; then
        return 0
    fi

    if [ -x /data/adb/magisk/busybox ]; then
        if printf '%s\n' "$payload" |
            /data/adb/magisk/busybox nc -w 5 "$REPORT_HOST" "$REPORT_PORT" \
            >>"$LOG_FILE" 2>&1; then
            log "Reported $endpoint to $REPORT_HOST:$REPORT_PORT"
            return 0
        fi
    fi

    log "WARNING: failed to report $endpoint to $REPORT_HOST:$REPORT_PORT"
    return 1
}

main() {
    : >"$LOG_FILE"
    chmod 600 "$LOG_FILE"
    log "===== $(date '+%F %T') remote-adb starting ====="

    while [ "$(getprop sys.boot_completed)" != '1' ]; do
        sleep 2
    done

    # Wi-Fi credentials are credential-encrypted on Android. Wait for the
    # primary user to be unlocked before asking WifiService to connect.
    ce_available="$(getprop sys.user.0.ce_available)"
    if [ -n "$ce_available" ]; then
        while [ "$(getprop sys.user.0.ce_available)" != 'true' ]; do
            sleep 2
        done
    fi

    android_sdk="$(getprop ro.build.version.sdk)"
    if [ -z "$android_sdk" ] || [ "$android_sdk" -lt 30 ]; then
        log "ERROR: Android SDK 30+ is required; current SDK: $android_sdk"
        exit 1
    fi

    connect_wifi_until_ready

    wifi_ip="$(get_wifi_ip)"
    log "Wi-Fi IP: $wifi_ip"

    tls_port="$(get_tls_port)"
    if ! valid_port "$tls_port"; then
        log 'Starting Android native TLS wireless debugging'
        enable_native_wireless_debugging

        count=0
        while [ "$count" -lt 20 ]; do
            tls_port="$(get_tls_port)"
            if valid_port "$tls_port"; then
                break
            fi
            count=$((count + 1))
            sleep 1
        done
    fi

    if ! valid_port "$tls_port"; then
        log 'ERROR: service.adb.tls.port is empty; wireless debugging did not start'
        exit 1
    fi

    device_id="$(getprop ro.serialno)"
    if [ -z "$device_id" ] || [ "$device_id" = 'unknown' ]; then
        device_id="$(settings get secure android_id 2>/dev/null)"
    fi
    device_id="$(printf '%s' "$device_id" | tr -cd 'A-Za-z0-9._-')"

    # Keep reporting so the computer learns the address after boot, and again
    # if DHCP or adbd changes the endpoint.
    last_endpoint=''
    while true; do
        wifi_ip="$(get_wifi_ip)"
        if [ -z "$wifi_ip" ]; then
            log 'Wi-Fi lost its IPv4 address; reconnecting'
            connect_wifi_until_ready
            continue
        fi

        tls_port="$(get_tls_port)"
        if ! valid_port "$tls_port"; then
            log 'TLS port disappeared; restarting adbd'
            enable_native_wireless_debugging >/dev/null 2>&1
            sleep 5
            tls_port="$(get_tls_port)"
        fi

        if valid_port "$tls_port"; then
            endpoint="${wifi_ip}:${tls_port}"
            printf '%s\n' "$endpoint" >"$ADDRESS_FILE"
            chmod 600 "$ADDRESS_FILE"

            if [ "$endpoint" != "$last_endpoint" ]; then
                log "TLS port: $tls_port"
                log "ADB endpoint: $endpoint"
                log "Saved to: $ADDRESS_FILE"
                printf '%s\n' "$endpoint"
                last_endpoint="$endpoint"
            fi

            report_endpoint "$device_id" "$endpoint"
        else
            log 'ERROR: service.adb.tls.port is empty'
        fi

        sleep "$REPORT_INTERVAL"
    done
}

main
