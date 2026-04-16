#!/bin/bash
# /usr/local/bin/xray-auto-update.sh — безопасное автообновление Xray
set -euo pipefail

CONF="/usr/local/etc/xray/config.json"
LOG="/var/log/xray-auto-update.log"
BACKUP_DIR="/usr/local/etc/xray/.backups"
MAX_BACKUPS=5
exec >> "$LOG" 2>&1

echo "=== $(date '+%Y-%m-%d %H:%M:%S') [AUTO-UPDATE] ==="
mkdir -p "$BACKUP_DIR"

# Версии
CURRENT_VER=$(xray version 2>/dev/null | awk '{print $2}' | head -n1 || echo "unknown")
LATEST_VER=$(curl -s --fail --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
  | grep -oP '"tag_name": "\Kv?[\d.]+' | sed 's/v//' || echo "")

[ -z "$LATEST_VER" ] && { echo "[WARN] Не удалось получить версию с GitHub"; exit 0; }
[ "$CURRENT_VER" = "$LATEST_VER" ] && { echo "[OK] Обновление не требуется"; exit 0; }

echo "[INFO] Обновление: $CURRENT_VER → $LATEST_VER"

# Бэкап
[ -f "$CONF" ] && { cp "$CONF" "${BACKUP_DIR}/config.json.$(date '+%Y%m%d%H%M%S')"; }
ls -t "${BACKUP_DIR}/config.json."* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f || true

# Обновление
if ! bash -c "$(curl -L --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$LATEST_VER"; then
    echo "[ERROR] Ошибка установки!"; exit 1
fi

# Проверка и рестарт
if [ -f "$CONF" ] && ! /usr/local/bin/xray -test -config "$CONF" > /dev/null 2>&1; then
    echo "[ERROR] Конфиг невалиден после обновления! Откат..."
    LATEST_BKP=$(ls -t "${BACKUP_DIR}/config.json."* 2>/dev/null | head -n1)
    [ -n "$LATEST_BKP" ] && cp "$LATEST_BKP" "$CONF"
    systemctl restart xray
    exit 1
fi

systemctl restart xray && sleep 3
if systemctl is-active --quiet xray; then
    echo "[✅ SUCCESS] Обновлено до $LATEST_VER"
else
    echo "[ERROR] Xray не запустился! journalctl -u xray -n 30"; exit 1
fi