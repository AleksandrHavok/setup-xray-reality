#!/bin/bash
set -euo pipefail
# setup-xray-reality.sh — настройка Xray Reality + генерация ссылок
# Репозиторий: https://github.com/AleksandrHavok/setup-xray-reality

CONF="/usr/local/etc/xray/config.json"
PUBKEY_FILE="/usr/local/etc/xray/.reality_pubkey"
LOG="/var/log/xray-setup.log"
REPO_RAW="https://raw.githubusercontent.com/AleksandrHavok/setup-xray-reality/main"

# Функция вывода: терминал + лог
log() { echo "$@" | tee -a "$LOG"; }
# Очистим старый лог для чистоты
> "$LOG"

log "=== $(date '+%Y-%m-%d %H:%M:%S') Xray Reality Setup ==="

# ── 0. Синхронизация времени (Reality критичен к рассинхрону) ──
command -v timedatectl &>/dev/null && timedatectl set-ntp true 2>/dev/null || true

# ── 1. jq (нужен для безопасной работы с JSON) ──
if ! command -v jq &> /dev/null; then
    log "[INFO] Устанавливаем jq..."
    if command -v apt &> /dev/null; then
        sudo apt update -qq && sudo apt install -y jq >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        sudo yum install -y jq >/dev/null 2>&1
    else
        log "[ERROR] Не удалось установить jq. Попробуйте вручную: apt install jq"
        exit 1
    fi
fi

# ── 2. Установка Xray (последняя стабильная версия) ──
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

# ── 5. First run or add device ──
CURRENT_PKEY=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.privateKey // empty' "$CONF" 2>/dev/null || echo "")

if [ -z "$CURRENT_PKEY" ] || [ "$CURRENT_PKEY" = "null" ]; then
    # === ПЕРВЫЙ ЗАПУСК: Ключей нет, генерируем ===
    log "[🔑 FIRST RUN] Генерируем пару Reality-ключей..."
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
    log "[➕ ADD] Добавляем устройство: $DEVICE_NAME (существующие ключи сохранены)"
    
    PUBLIC_KEY=""
    # Пробуем взять PublicKey из файла
    if [ -f "$PUBKEY_FILE" ] && [ -s "$PUBKEY_FILE" ]; then
        PUBLIC_KEY=$(cat "$PUBKEY_FILE")
    else
        log "[INFO] Файл с PublicKey не найден (сервер настраивался вручную?)."
        echo -n "[?] Введите ваш PublicKey для генерации ссылки (или нажмите Enter, чтобы пропустить): "
        read -r PUBLIC_KEY
        if [ -n "$PUBLIC_KEY" ]; then
            echo "$PUBLIC_KEY" > "$PUBKEY_FILE" && chmod 600 "$PUBKEY_FILE"
            log "[OK] PublicKey сохранён для будущих запусков."
        else
            log "[INFO] Пропускаем автогенерацию ссылки. Клиент всё равно добавлен в конфиг."
        fi
    fi
    
    # Добавляем ТОЛЬКО нового клиента. realitySettings и privateKey НЕ ИЗМЕНЯЮТСЯ
    jq --arg uuid "$NEW_UUID" --arg email "$DEVICE_NAME" \
       '(.inbounds[] | select(.protocol=="vless" and .port==443)).settings.clients += 
          [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}]' \
       "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
fi

# ── 6. Validate & restart ──
log "[INFO] Проверяем конфиг..."
if ! /usr/local/bin/xray -test -config "$CONF" >/dev/null 2>&1; then
    log "[ERROR] Конфиг невалиден! Откат..."
    cp "$BACKUP" "$CONF"
    exit 1
fi

log "[INFO] Перезапускаем Xray..."
sudo systemctl restart xray && sleep 3
if ! systemctl is-active --quiet xray; then
    log "[ERROR] Xray не запустился! Проверьте: journalctl -u xray -n 30"
    cp "$BACKUP" "$CONF"
    exit 1
fi

# ── 7. Сборка vless:// ссылки ──
SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ВАШ_IP")
SNI=$(jq -r '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.serverNames[0]' "$CONF")
SID=$(jq -r '.inbounds[]