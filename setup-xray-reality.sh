#!/bin/bash
set -euo pipefail
# setup-xray-reality.sh — настройка Xray Reality + генерация ссылок
# Репозиторий: https://github.com/AleksandrHavok/setup-xray-reality

CONF="/usr/local/etc/xray/config.json"
PUBKEY_FILE="/usr/local/etc/xray/.reality_pubkey"
LOG="/var/log/xray-setup.log"
REPO_RAW="https://raw.githubusercontent.com/AleksandrHavok/setup-xray-reality/main"

# Функция вывода: экран + файл лога
: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }

log "=== $(date '+%Y-%m-%d %H:%M:%S') Xray Reality Setup ==="

# ── 0. Синхронизация времени (Reality критичен к рассинхрону) ──
command -v timedatectl &>/dev/null && timedatectl set-ntp true 2>/dev/null || true

# ── 1. Установка jq, если отсутствует ──
if ! command -v jq &> /dev/null; then
    log "[INFO] Устанавливаем jq..."
    if command -v apt &> /dev/null; then
        sudo apt update -qq && sudo apt install -y jq >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        sudo yum install -y jq >/dev/null 2>&1
    else
        log "[ERROR] Не удалось установить jq. Попробуйте вручную: sudo apt install jq"
        exit 1
    fi
fi

# ── 2. Установка Xray, если отсутствует ──
if ! command -v xray &> /dev/null; then
    log "[INFO] Устанавливаем Xray (latest stable)..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    log "[OK] Xray установлен: $(xray version | head -n1)"
else
    log "[OK] Xray уже установлен: $(xray version | head -n1)"
fi

# ── 3. Проверка конфига ──
if [ ! -f "$CONF" ]; then
    log "[ERROR] Файл конфига не найден: $CONF"
    log "[HINT] Создайте базовый конфиг по гайду перед запуском скрипта."
    exit 1
fi

# Бэкап перед правками
BACKUP="${CONF}.bak.$(date '+%Y%m%d%H%M%S')"
cp "$CONF" "$BACKUP"

# ── 4. Генерация данных для нового устройства ──
NEW_UUID=$(/usr/local/bin/xray uuid)
CLIENT_COUNT=$(jq '[.inbounds[] | select(.protocol=="vless" and .port==443) | .settings.clients | length] | add // 0' "$CONF")
DEVICE_NAME="device_$(printf '%02d' $((CLIENT_COUNT + 1)))"

# Генерируем уникальный shortId (8 hex символов)
NEW_SID=$(openssl rand -hex 4)

# ── 5. First run или добавление устройства ──
CURRENT_PKEY=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.privateKey // empty' "$CONF" 2>/dev/null || echo "")

if [ -z "$CURRENT_PKEY" ] || [ "$CURRENT_PKEY" = "null" ]; then
    log "[🔑 FIRST RUN] Генерируем пару Reality-ключей..."
    read -r PRIVATE_KEY PUBLIC_KEY < <(/usr/local/bin/xray x25519 | awk '/Private:|Public:/ {print $2}' | xargs)
    echo "$PUBLIC_KEY" > "$PUBKEY_FILE" && chmod 600 "$PUBKEY_FILE"
    
    # Первый запуск: подставляем ключи + первого клиента + первый shortId
    jq --arg pkey "$PRIVATE_KEY" --arg uuid "$NEW_UUID" --arg email "$DEVICE_NAME" --arg sid "$NEW_SID" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)) |= 
          (.streamSettings.realitySettings.privateKey = $pkey |
           .streamSettings.realitySettings.shortIds = [$sid] |
           .settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}])' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
else
    log "[➕ ADD] Добавляем устройство: $DEVICE_NAME (ключи не меняются)"
    
    # Добавляем новый shortId в массив (если его ещё нет)
    jq --arg sid "$NEW_SID" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)).streamSettings.realitySettings.shortIds |= 
          (if index($sid) then . else . + [$sid] end)' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
    
    # Добавляем нового клиента
    jq --arg uuid "$NEW_UUID" --arg email "$DEVICE_NAME" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)).settings.clients += 
          [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}]' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
fi

# ── 6. Валидация и перезапуск ──
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

# ── 7. Подготовка данных для ссылки ──
SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ВАШ_IP")
SNI=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.serverNames[0]' "$CONF")

# Пробуем взять PublicKey из файла
PUBLIC_KEY=""
[ -f "$PUBKEY_FILE" ] && [ -s "$PUBKEY_FILE" ] && PUBLIC_KEY=$(cat "$PUBKEY_FILE")

# ── 8. Генерация ссылки (ВСЕГДА, даже если нет PublicKey) ──
PBK_VALUE="${PUBLIC_KEY:-__ВСТАВЬТЕ_ВАШ_PUBLIC_KEY_СЮДА__}"
VLESS_LINK="vless://${NEW_UUID}@${SERVER_IP}:443?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK_VALUE}&sid=${NEW_SID}&type=tcp&flow=xtls-rprx-vision#${DEVICE_NAME}"

# ── 9. Вывод результата ──
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✅  Готово! Устройство: ${DEVICE_NAME}"
echo "║  🔗  Ссылка для импорта:                                    ║"
echo "║                                                              ║"
echo "║  ${VLESS_LINK}"
echo "║                                                              ║"
if [ -z "$PUBLIC_KEY" ]; then
    echo "║  ⚠️  В ссылке параметр pbk= содержит плейсхолдер.       ║"
    echo "║     Замените __ВСТАВЬТЕ_ВАШ_PUBLIC_KEY_СЮДА__          ║"
    echo "║     на ваш реальный PublicKey из записей.              ║"
    echo "║     (Ctrl+F по строке → заменить один раз)             ║"
fi
echo "║  📋  Или по отдельности:                                   ║"
echo "║     UUID: ${NEW_UUID} | IP: ${SERVER_IP}                   ║"
echo "║     SNI: ${SNI} | SID: ${NEW_SID} | Flow: xtls-rprx-vision ║"
[ -z "$PUBLIC_KEY" ] && echo "║     PublicKey: возьмите из своих записей      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo "💡 Чтобы добавить ещё одно устройство — запустите скрипт снова."

# ── 10. Опционально: установка автообновления ──
echo -n "[?] Настроить автообновление Xray? (y/n): "
read -n 1 -r REPLY
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "[INFO] Скачиваем скрипт автообновления..."
    curl -fsSL "${REPO_RAW}/xray-auto-update.sh" -o /usr/local/bin/xray-auto-update.sh 2>/dev/null && {
        chmod +x /usr/local/bin/xray-auto-update.sh
        if ! sudo crontab -l 2>/dev/null | grep -q "xray-auto-update.sh"; then
            (sudo crontab -l 2>/dev/null || echo ""; echo "0 4 * * 1 /usr/local/bin/xray-auto-update.sh") | sudo crontab -
            log "[OK] Автообновление добавлено в cron (понедельник, 04:00)."
        else
            log "[OK] Автообновление уже настроено."
        fi
    } || log "[WARN] Не удалось скачать скрипт автообновления."
else
    log "[INFO] Автообновление пропущено."
fi