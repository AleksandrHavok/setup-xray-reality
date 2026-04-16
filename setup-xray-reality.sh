#!/bin/bash
set -euo pipefail
# setup-xray-reality.sh — настройка Xray Reality (1 UUID + много SID)
# Репозиторий: https://github.com/AleksandrHavok/setup-xray-reality

CONF="/usr/local/etc/xray/config.json"
PUBKEY_FILE="/usr/local/etc/xray/.reality_pubkey"
LOG="/var/log/xray-setup.log"
REPO_RAW="https://raw.githubusercontent.com/AleksandrHavok/setup-xray-reality/main"

: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }

log "=== $(date '+%Y-%m-%d %H:%M:%S') Xray Reality Setup ==="

command -v timedatectl &>/dev/null && timedatectl set-ntp true 2>/dev/null || true

if ! command -v jq &> /dev/null; then
    log "[INFO] Устанавливаем jq..."
    (command -v apt &>/dev/null && sudo apt update -qq && sudo apt install -y jq >/dev/null 2>&1) || \
    (command -v yum &>/dev/null && sudo yum install -y jq >/dev/null 2>&1) || \
    { log "[ERROR] Не удалось установить jq."; exit 1; }
fi

if ! command -v xray &> /dev/null; then
    log "[INFO] Устанавливаем Xray (latest stable)..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

[ ! -f "$CONF" ] && { log "[ERROR] Конфиг не найден: $CONF"; exit 1; }
BACKUP="${CONF}.bak.$(date '+%Y%m%d%H%M%S')"
cp "$CONF" "$BACKUP"

NEW_SID=$(openssl rand -hex 4 2>/dev/null || head -c 4 /dev/urandom | xxd -p)
EXISTING_UUID=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .settings.clients[0].id // empty' "$CONF" 2>/dev/null || echo "")
CURRENT_PKEY=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.privateKey // empty' "$CONF" 2>/dev/null || echo "")

if [ -z "$EXISTING_UUID" ] || [ "$EXISTING_UUID" = "null" ]; then
    log "[🔑 FIRST RUN] Генерируем ключи и базовый UUID..."
    NEW_UUID=$(/usr/local/bin/xray uuid)
    read -r PRIVATE_KEY PUBLIC_KEY < <(/usr/local/bin/xray x25519 | awk '/Private:|Public:/ {print $2}' | xargs)
    echo "$PUBLIC_KEY" > "$PUBKEY_FILE" && chmod 600 "$PUBKEY_FILE"
    
    jq --arg pkey "$PRIVATE_KEY" --arg uuid "$NEW_UUID" --arg sid "$NEW_SID" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)) |= 
          (.streamSettings.realitySettings.privateKey = $pkey |
           .streamSettings.realitySettings.shortIds = [$sid] |
           .settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": "shared"}])' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
else
    log "[➕ ADD] Используем существующий UUID. Добавляем SID: ${NEW_SID}"
    NEW_UUID="$EXISTING_UUID"
    
    jq --arg sid "$NEW_SID" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)).streamSettings.realitySettings.shortIds |= 
          (if index($sid) then . else . + [$sid] end)' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
fi

log "[INFO] Проверяем конфиг..."
if ! /usr/local/bin/xray -test -config "$CONF" > /dev/null 2>&1; then
    log "[ERROR] Конфиг невалиден! Откат..."
    cp "$BACKUP" "$CONF"
    exit 1
fi

log "[INFO] Перезапускаем Xray..."
sudo systemctl restart xray && sleep 3
if ! systemctl is-active --quiet xray; then
    log "[ERROR] Xray не запустился!"
    cp "$BACKUP" "$CONF"
    exit 1
fi

SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ВАШ_IP")
SNI=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.serverNames[0]' "$CONF")

PUBLIC_KEY=""
[ -f "$PUBKEY_FILE" ] && [ -s "$PUBKEY_FILE" ] && PUBLIC_KEY=$(cat "$PUBKEY_FILE")

PBK_VALUE="${PUBLIC_KEY:-__ВАШ_PUBLIC_KEY__}"
VLESS_LINK="vless://${NEW_UUID}@${SERVER_IP}:443?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK_VALUE}&sid=${NEW_SID}&type=tcp&flow=xtls-rprx-vision#shared-device"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✅  Готово! Новый SID: ${NEW_SID}"
echo "║  🔗  Ссылка для импорта:                                    ║"
echo "║  ${VLESS_LINK}"
[ -z "$PUBLIC_KEY" ] && echo "║  ⚠️  Замените __ВАШ_PUBLIC_KEY__ в pbk= на ваш PublicKey"
echo "╚════════════════════════════════════════════════════════════╝"
echo "💡 UUID общий. Разделение устройств идёт по уникальному SID."

echo -n "[?] Настроить автообновление Xray? (y/n): "
read -n 1 -r REPLY; echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "[INFO] Скачиваем скрипт автообновления..."
    curl -fsSL "${REPO_RAW}/xray-auto-update.sh" -o /usr/local/bin/xray-auto-update.sh 2>/dev/null && {
        chmod +x /usr/local/bin/xray-auto-update.sh
        if ! sudo crontab -l 2>/dev/null | grep -q "xray-auto-update.sh"; then
            (sudo crontab -l 2>/dev/null || echo ""; echo "0 4 * * 1 /usr/local/bin/xray-auto-update.sh") | sudo crontab -
            log "[OK] Автообновление добавлено в cron."
        else log "[OK] Автообновление уже настроено."; fi
    } || log "[WARN] Не удалось скачать скрипт автообновления."
else log "[INFO] Автообновление пропущено."; fi