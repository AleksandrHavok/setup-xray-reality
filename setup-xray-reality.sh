#!/bin/bash
set -euo pipefail
# setup-xray-reality.sh — настройка Xray Reality (1 UUID + много SID)

CONF="/usr/local/etc/xray/config.json"
PUBKEY_FILE="/usr/local/etc/xray/.reality_pubkey"
LOG="/var/log/xray-setup.log"

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

# ── [5] ОСНОВНАЯ ЛОГИКА ──
if [ -z "$EXISTING_UUID" ] || [ "$EXISTING_UUID" = "null" ]; then
    # === FIRST RUN: генерируем всё с нуля ===
    log "[🔑 FIRST RUN] Генерируем ключи и базовый UUID..."
    NEW_UUID=$(/usr/local/bin/xray uuid)
    
    OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
    PRIVATE_KEY=$(echo "$OUTPUT" | grep "PrivateKey:" | awk '{print $2}' || true)
    PUBLIC_KEY=$(echo "$OUTPUT" | grep -E "PublicKey:|Password \(PublicKey\):" | awk '{print $NF}' || true)
    
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        log "[ERROR] Не удалось получить ключи!"
        cp "$BACKUP" "$CONF"
        exit 1
    fi
    
    echo "$PUBLIC_KEY" > "$PUBKEY_FILE" && chmod 600 "$PUBKEY_FILE"
    
    jq --arg pkey "$PRIVATE_KEY" --arg uuid "$NEW_UUID" --arg sid "$NEW_SID" '
      .inbounds = [.inbounds[] | 
        if .protocol=="vless" and .port==443 then 
          .streamSettings.realitySettings.privateKey = $pkey |
          .streamSettings.realitySettings.shortIds = [$sid] |
          .settings.clients = [{"id": $uuid, "flow": "xtls-rprx-vision", "email": "shared"}]
        else . end
      ]
    ' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
else
    # === ADD: последовательно добавляем SID и клиента через пайп ===
    log "[➕ ADD] Используем существующий UUID. Добавляем SID: ${NEW_SID}"
    NEW_UUID="$EXISTING_UUID"
    
    # Один jq-запрос: сначала добавляем SID, потом клиента (через |)
    jq --arg sid "$NEW_SID" --arg uuid "$NEW_UUID" '
      .inbounds = [.inbounds[] |
        if .protocol=="vless" and .port==443 then
          # 1. Добавляем SID (если нет)
          (.streamSettings.realitySettings.shortIds // []) as $sids |
          (if ($sids | index($sid)) then $sids else $sids + [$sid] end) as $new_sids |
          .streamSettings.realitySettings.shortIds = $new_sids |
          # 2. Добавляем клиента
          .settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": "shared"}]
        else . end
      ]
    ' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
fi

# ── [6] ВАЛИДАЦИЯ И ПЕРЕЗАПУСК ──
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

# ── [7-8] СБОРКА И ВЫВОД ССЫЛКИ ──
SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ВАШ_IP")
SNI=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.serverNames[0]' "$CONF")

PBK_VALUE="${PUBLIC_KEY:-__ВАШ_PUBLIC_KEY__}"
VLESS_LINK="vless://${NEW_UUID}@${SERVER_IP}:443?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK_VALUE}&sid=${NEW_SID}&type=tcp&flow=xtls-rprx-vision#shared-device"

echo ""
echo "════════════════════════════════════════════"
echo "Ссылка для импорта в клиент готова! Новый SID: ${NEW_SID}"
[ -z "$PUBLIC_KEY" ] && echo "⚠️  Не забудьте заменить pbk=__ВАШ_PUBLIC_KEY__ на ваш публичный ключ"
echo "Ссылка:"
echo "${VLESS_LINK}"
echo "════════════════════════════════════════════"
echo ""