SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

CONFIG_FILE='/data/adb/remote-adb.conf'
OLD_SERVICE='/data/adb/modules/remote_adb/service.sh'

ui_print "- Installing Remote ADB Wi-Fi Bootstrap"
ui_print "- Wi-Fi waits: auto-connect 60s, active connect 120s"
ui_print "- Failed Wi-Fi rounds retry every 15s"
ui_print "- Native TLS wireless debugging will start at boot"

# v1.1.x stored private values directly in service.sh. During the first
# public-safe upgrade, copy only approved assignments to a persistent root-only
# file outside the replaceable module directory.
if [ ! -s "$CONFIG_FILE" ] && [ -f "$OLD_SERVICE" ]; then
    tmp_config="${CONFIG_FILE}.tmp.$$"
    : >"$tmp_config"
    for key in \
        WIFI_SSID WIFI_SECURITY WIFI_PASSWORD WIFI_BSSID \
        REPORT_HOST REPORT_PORT REPORT_INTERVAL \
        WIFI_AUTOCONNECT_WAIT WIFI_CONNECT_WAIT WIFI_RETRY_DELAY WIFI_POLL_INTERVAL
    do
        line="$(grep -m 1 "^${key}=" "$OLD_SERVICE" 2>/dev/null)"
        if [ -n "$line" ]; then
            printf '%s\n' "$line" >>"$tmp_config"
        fi
    done
    if grep -q '^WIFI_SSID=' "$tmp_config" && grep -q '^WIFI_PASSWORD=' "$tmp_config"; then
        mv -f "$tmp_config" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        chown 0:0 "$CONFIG_FILE"
        ui_print "- Migrated existing private Wi-Fi settings to $CONFIG_FILE"
    else
        rm -f "$tmp_config"
        ui_print "- Existing settings could not be migrated"
    fi
fi

if [ -s "$CONFIG_FILE" ]; then
    chmod 600 "$CONFIG_FILE"
    chown 0:0 "$CONFIG_FILE"
    ui_print "- Using persistent private config: $CONFIG_FILE"
else
    ui_print "- ACTION REQUIRED: create $CONFIG_FILE"
    ui_print "- Template: $MODPATH/remote-adb.conf.example"
fi

set_perm "$MODPATH/service.sh" 0 0 0700
set_perm "$MODPATH/remote-adb.conf.example" 0 0 0600

