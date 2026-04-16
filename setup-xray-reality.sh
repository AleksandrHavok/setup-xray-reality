#!/bin/bash
set -euo pipefail
# setup-xray-reality.sh — настройка Xray Reality + генерация ссылок

CONF="/usr/local/etc/xray/config.json"
PUBKEY_FILE="/usr/local/etc/xray/.reality_pubkey"
LOG="/var/log/xray-setup.log"
REPO_RAW="https://raw.githubusercontent.com/AleksandrHavok/setup-xray-reality/main"
exec >> "$LOG" 2>&1

echo "=== $(date '+%Y-%m-%d %H:%M:%S') Xray Reality Setup ==="

# ── 0. Синхронизация времени ──
command -v timedatectl &>/dev/null && timedatectl set-ntp true 2>/dev/null || true

# ── 1. jq ──
if ! command -v jq &> /dev/null; then
    echo "[INFO] Устанавливаем jq..."
    if command -v apt &> /dev/null; then sudo apt update -qq && sudo apt install -y jq >/dev/null 2>&1
    elif command -v yum &> /dev/null; then sudo yum install -y jq >/dev/null 2>&1
    else echo "[ERROR] Установите jq вручную."; exit 1; fi
fi

# ── 2. Xray install ──
if ! command -v xray &> /dev/null; then
    echo "[INFO] Устанавливаем Xray (latest stable)..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# ── 3. Проверка конфига ──
if [ ! -f "$CONF" ]; then
    echo "[ERROR] Файл $CONF не найден. Создайте базовый конфиг по гайду."
    exit 1
fi
BACKUP="${CONF}.bak.$(date '+%Y%m%d%H%M%S')"
cp "$CONF" "$BACKUP"

# ── 4. Генерация данных ──
NEW_UUID=$(/usr/local/bin/xray uuid)
CLIENT_COUNT=$(jq '[.inbounds[] | select(.protocol=="vless" and .port==443) | .settings.clients | length] | add // 0' "$CONF")
DEVICE_NAME="device_$(printf '%02d' $((CLIENT_COUNT + 1)))"

# ── 5. First run or add device ──
CURRENT_PKEY=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.privateKey // empty' "$CONF" 2>/dev/null || echo "")

if [ -z "$CURRENT_PKEY" ]; then
    echo "[🔑 FIRST RUN] Генерируем Reality-ключи..."
    read -r PRIVATE_KEY PUBLIC_KEY < <(/usr/local/bin/xray x25519 | awk '/Private:|Public:/ {print $2}' | xargs)
    echo "$PUBLIC_KEY" > "$PUBKEY_FILE" && chmod 600 "$PUBKEY_FILE"
    jq --arg pkey "$PRIVATE_KEY" --arg uuid "$NEW_UUID" --arg email "$DEVICE_NAME" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)) |= 
          (.streamSettings.realitySettings.privateKey = $pkey |
           .settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}])' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
else
    echo "[➕ ADD] Добавляем устройство: $DEVICE_NAME"
    PUBLIC_KEY=$(cat "$PUBKEY_FILE" 2>/dev/null || echo "")
    [ -z "$PUBLIC_KEY" ] && { echo "[ERROR] Не найден PublicKey"; cp "$BACKUP" "$CONF"; exit 1; }
    jq --arg uuid "$NEW_UUID" --arg email "$DEVICE_NAME" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)).settings.clients += 
          [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}]' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
fi

# ── 6. Validate & restart ──
if ! /usr/local/bin/xray -test -config "$CONF" >/dev/null 2>&1; then
    echo "[ERROR] Конфиг невалиден! Откат..."
    cp "$BACKUP" "$CONF"; exit 1
fi
sudo systemctl restart xray && sleep 3
if ! systemctl is-active --quiet xray; then
    echo "[ERROR] Xray не запустился! journalctl -u xray -n 30"
    cp "$BACKUP" "$CONF"; exit 1
fi

# ── 7. Сборка vless:// ссылки ──
SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ВАШ_IP")
SNI=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.serverNames[0]' "$CONF")
SID=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.shortIds[0]' "$CONF")
VLESS_LINK="vless://${NEW_UUID}@${SERVER_IP}:443?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=tcp&flow=xtls-rprx-vision#${DEVICE_NAME}"

# ── 8. Вывод ──
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✅  Готово! Устройство: ${DEVICE_NAME}"
echo "║  🔗  Ссылка для импорта (скопируйте целиком):             ║"
echo "║                                                              ║"
echo "║  ${VLESS_LINK}"
echo "║                                                              ║"
echo "║  📋  Или по отдельности:                                   ║"
echo "║     IP: ${SERVER_IP} | UUID: ${NEW_UUID}"
echo "║     PublicKey: ${PUBLIC_KEY} | SNI: ${SNI} | SID: ${SID}"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "💡 Чтобы добавить ещё одно устройство — запустите скрипт снова."

# ── 9. Установка автообновления ──
echo "[INFO] Скачиваем скрипт автообновления..."
curl -fsSL "${REPO_RAW}/xray-auto-update.sh" -o /usr/local/bin/xray-auto-update.sh 2>/dev/null && {
    chmod +x /usr/local/bin/xray-auto-update.sh
    if ! sudo crontab -l 2>/dev/null | grep -q "xray-auto-update.sh"; then
        (sudo crontab -l 2>/dev/null || echo ""; echo "0 4 * * 1 /usr/local/bin/xray-auto-update.sh") | sudo crontab -
        echo "[OK] Автообновление добавлено в cron (понедельник, 04:00)."
    else
        echo "[OK] Автообновление уже настроено."
    fi
} || echo "[WARN] Не удалось скачать скрипт автообновления."