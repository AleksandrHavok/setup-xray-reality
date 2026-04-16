#!/bin/bash
# /usr/local/bin/xray-auto-update.sh — безопасное автообновление Xray
# Репозиторий: https://github.com/AleksandrHavok/setup-xray-reality
set -euo pipefail

CONF="/usr/local/etc/xray/config.json"
LOG="/var/log/xray-auto-update.log"
BACKUP_DIR="/usr/local/etc/xray/.backups"
MAX_BACKUPS=5
exec >> "$LOG" 2>&1

echo "=== $(date '+%Y-%m-%d %H:%M:%S') [AUTO-UPDATE] ==="
mkdir -p "$BACKUP_DIR"

# ── 1. Определяем версии ──
CURRENT_VER=$(xray version 2>/dev/null | awk '{print $2}' | head -n1 || echo "unknown")
LATEST_VER=$(curl -s --fail --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
  | grep -oP '"tag_name": "\Kv?[\d.]+' | sed 's/v//' || echo "")

if [ -z "$LATEST_VER" ]; then
    echo "[WARN] Не удалось получить версию с GitHub. Пропускаем обновление."
    exit 0
fi

if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
    echo "[OK] Обновление не требуется (установлено: $CURRENT_VER)."
    exit 0
fi

echo "[INFO] Обновление: $CURRENT_VER → $LATEST_VER"

# ── 2. Бэкап конфига ──
if [ -f "$CONF" ]; then
    BACKUP_FILE="${BACKUP_DIR}/config.json.$(date '+%Y%m%d%H%M%S')"
    cp "$CONF" "$BACKUP_FILE"
    echo "[OK] Бэкап: $BACKUP_FILE"
    
    # Чистим старые бэкапы (оставляем последние MAX_BACKUPS)
    ls -t "${BACKUP_DIR}/config.json."* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f || true
else
    echo "[WARN] Файл конфига не найден. Продолжаем без бэкапа."
    BACKUP_FILE=""
fi

# ── 3. Обновление через официальный скрипт ──
echo "[INFO] Запуск официального установщика..."
if ! bash -c "$(curl -L --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$LATEST_VER"; then
    echo "[ERROR] Ошибка установки! Восстанавливаем бэкап..."
    [ -n "${BACKUP_FILE:-}" ] && [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$CONF"
    exit 1
fi
echo "[OK] Бинарники обновлены."

# ── 4. Проверка конфига (ИСПРАВЛЕНО: xray -test) ──
echo "[INFO] Проверяем конфиг..."
if [ -f "$CONF" ] && ! /usr/local/bin/xray -test -config "$CONF" >/dev/null 2>&1; then
    echo "[ERROR] Конфиг невалиден после обновления! Откат..."
    if [ -n "${BACKUP_FILE:-}" ] && [ -f "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" "$CONF"
        systemctl restart xray
        echo "[OK] Сервис восстановлен из бэкапа."
    else
        echo "[ERROR] Бэкап не найден. Требуется ручное вмешательство."
    fi
    exit 1
fi
echo "[OK] Конфиг валиден."

# ── 5. Перезапуск и финальная проверка ──
echo "[INFO] Перезапускаем Xray..."
systemctl restart xray && sleep 3

if systemctl is-active --quiet xray; then
    echo "[✅ SUCCESS] Xray обновлён до $LATEST_VER и запущен."
    exit 0
else
    echo "[ERROR] Xray не запустился! Проверьте: journalctl -u xray -n 30"
    echo "[HINT] Для ручного отката: cp ${BACKUP_FILE:-/path/to/backup} $CONF && systemctl restart xray"
    exit 1
fi