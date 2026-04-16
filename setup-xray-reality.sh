#!/bin/bash
set -euo pipefail
# setup-xray-reality.sh — настройка Xray Reality + генерация ссылок
# Репозиторий: https://github.com/AleksandrHavok/setup-xray-reality

CONF="/usr/local/etc/xray/config.json"
PUBKEY_FILE="/usr/local/etc/xray/.reality_pubkey"
LOG="/var/log/xray-setup.log"
REPO_RAW="https://raw.githubusercontent.com/AleksandrHavok/setup-xray-reality/main"
exec >> "$LOG" 2>&1

echo "=== $(date '+%Y-%m-%d %H:%M:%S') Xray Reality Setup ==="

# ── 0. Синхронизация времени (Reality критичен к рассинхрону) ──
command -v timedatectl &>/dev/null && timedatectl set-ntp true 2>/dev/null || true

# ── 1. jq (нужен для безопасной работы с JSON) ──
if ! command -v jq &> /dev/null; then
    echo "[INFO] Устанавливаем jq..."
    if command -v apt &> /dev/null; then
        sudo apt update -qq && sudo apt install -y jq >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        sudo yum install -y jq >/dev/null 2>&1
    else
        echo "[ERROR] Не удалось установить jq. Попробуйте вручную: apt install jq"
        exit 1
    fi
fi

# ── 2. Установка Xray (последняя стабильная версия) ──
if ! command -v xray &> /dev/null; then
    echo "[INFO] Устанавливаем Xray (latest stable)..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    echo "[OK] Xray установлен: $(xray version | head -n1)"
else
    echo "[OK] Xray уже установлен: $(xray version | head -n1)"
fi

# ── 3. Проверка конфига ──
if [ ! -f "$CONF" ]; then
    echo "[ERROR] Файл конфига не найден: $CONF"
    echo "[HINT] Создайте базовый конфиг по гайду перед запуском скрипта."
    exit 1
fi

# Бэкап перед правками
BACKUP="${CONF}.bak.$(date '+%Y%m%d%H%M%S')"
cp "$CONF" "$BACKUP"

# ── 4. Генерация данных для нового устройства ──
NEW_UUID=$(/usr/local/bin/xray uuid)
CLIENT_COUNT=$(jq '[.inbounds[] | select(.protocol=="vless" and .port==443) | .settings.clients | length] | add // 0' "$CONF")
DEVICE_NAME="device_$(printf '%02d' $((CLIENT_COUNT + 1)))"

# ── 5. Первый запуск или добавление устройства ──
CURRENT_PKEY=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.privateKey // empty' "$CONF" 2>/dev/null || echo "")

if [ -z "$CURRENT_PKEY" ] || [ "$CURRENT_PKEY" = "null" ]; then
    # === ПЕРВЫЙ ЗАПУСК: Ключей нет, генерируем ===
    echo "[🔑 FIRST RUN] Генерируем пару Reality-ключей..."
    read -r PRIVATE_KEY PUBLIC_KEY < <(/usr/local/bin/xray x25519 | awk '/Private:|Public:/ {print $2}' | xargs)
    echo "$PUBLIC_KEY" > "$PUBKEY_FILE" && chmod 600 "$PUBKEY_FILE"
    
    # Подставляем ключи + добавляем первого клиента
    jq --arg pkey "$PRIVATE_KEY" --arg uuid "$NEW_UUID" --arg email "$DEVICE_NAME" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)) |= 
          (.streamSettings.realitySettings.privateKey = $pkey |
           .settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}])' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
else
    # === ДОБАВЛЕНИЕ УСТРОЙСТВА: Ключи уже есть, НЕ ТРОГАЕМ ИХ ===
    echo "[➕ ADD] Добавляем устройство: $DEVICE_NAME (существующие ключи сохранены)"
    
    PUBLIC_KEY=""
    # Пробуем взять PublicKey из файла
    if [ -f "$PUBKEY_FILE" ] && [ -s "$PUBKEY_FILE" ]; then
        PUBLIC_KEY=$(cat "$PUBKEY_FILE")
    else
        echo "[INFO] Файл с PublicKey не найден (сервер настраивался вручную?)."
        echo "[?] Введите ваш PublicKey для генерации ссылки (или нажмите Enter, чтобы пропустить):"
        read -p "PublicKey: " PUBLIC_KEY
        if [ -n "$PUBLIC_KEY" ]; then
            echo "$PUBLIC_KEY" > "$PUBKEY_FILE" && chmod 600 "$PUBKEY_FILE"
            echo "[OK] PublicKey сохранён для будущих запусков."
        else
            echo "[INFO] Пропускаем автогенерацию ссылки. Клиент всё равно добавлен в конфиг."
        fi
    fi
    
    # Добавляем ТОЛЬКО нового клиента. realitySettings и privateKey НЕ ИЗМЕНЯЮТСЯ
    jq --arg uuid "$NEW_UUID" --arg email "$DEVICE_NAME" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)).settings.clients += 
          [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}]' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
fi

# ── 6. Validate & restart ──
echo "[INFO] Проверяем конфиг..."
if ! /usr/local/bin/xray -test -config "$CONF" >/dev/null 2>&1; then
    echo "[ERROR] Конфиг невалиден! Откат..."
    cp "$BACKUP" "$CONF"
    exit 1
fi

echo "[INFO] Перезапускаем Xray..."
sudo systemctl restart xray && sleep 3
if ! systemctl is-active --quiet xray; then
    echo "[ERROR] Xray не запустился! Проверьте: journalctl -u xray -n 30"
    cp "$BACKUP" "$CONF"
    exit 1
fi

# ── 7. Сборка vless:// ссылки ──
SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ВАШ_IP")
SNI=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.serverNames[0]' "$CONF")
SID=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.shortIds[0]' "$CONF")

if [ -n "$PUBLIC_KEY" ]; then
    VLESS_LINK="vless://${NEW_UUID}@${SERVER_IP}:443?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=tcp&flow=xtls-rprx-vision#${DEVICE_NAME}"
else
    VLESS_LINK=""
fi

# ── 8. Вывод результата ──
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✅  Готово! Устройство: ${DEVICE_NAME}"
if [ -n "$VLESS_LINK" ]; then
    echo "║  🔗  Готовая ссылка для импорта (скопируйте целиком):     ║"
    echo "║                                                              ║"
    echo "║  ${VLESS_LINK}"
    echo "║                                                              ║"
else
    echo "║  ⚠️  PublicKey не указан — ссылка не сгенерирована.       ║"
    echo "║  📋  Данные для ручной сборки:                             ║"
    echo "║     UUID: ${NEW_UUID}                                      ║"
    echo "║     IP: ${SERVER_IP} | SNI: ${SNI} | SID: ${SID}           ║"
fi
echo "║  📋  Или по отдельности:                                   ║"
echo "║     IP: ${SERVER_IP} | UUID: ${NEW_UUID}"
[ -n "$PUBLIC_KEY" ] && echo "║     PublicKey: ${PUBLIC_KEY}"
echo "║     Flow: xtls-rprx-vision | FP: chrome"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "💡 Чтобы добавить ещё одно устройство — запустите скрипт снова."

# ── 9. Опционально: установка автообновления ──
read -p "[?] Настроить автообновление Xray? (y/n): " -n 1 -r || true
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
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
else
    echo "[INFO] Автообновление пропущено. Настроить позже можно вручную по инструкции в README."
fi