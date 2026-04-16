# setup-xray-reality

Автоматическая настройка VPS под Xray (Reality + VLESS) с генерацией ссылок для клиентов и безопасным автообновлением.

Скрипт:
- Установит/обновит Xray до последней стабильной версии
- Сгенерирует ключи Reality (если их ещё нет)
- Добавит первое устройство (device_01)
- Выведет готовую ссылку vless://... для импорта в клиент
- Настроит автообновление (опционально)

### Настройка сервера (первый запуск)
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/AleksandrHavok/setup-xray-reality/main/setup-xray-reality.sh)
```

### Добавить новое устройство
Просто запустите ту же команду снова:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/AleksandrHavok/setup-xray-reality/main/setup-xray-reality.sh)
```

Он автоматически:
- Добавит device_02, device_03 и т.д.
- Сохранит старые ключи и подключения
- Выдаст новую ссылку для импорта в клиент на устройстве

Чтобы проверить, что новое устройство появилось в списке можно выполнить:
```bash
sudo jq '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.shortIds' /usr/local/etc/xray/config.json
```

### Автообновление
При первом запуске скрипт сам предложит настроить еженедельное обновление Xray (каждый понедельник в 04:00)

Просмотр логов:
```bash
tail -f /var/log/xray-auto-update.log
```

Ручное обновление:
```bash
sudo /usr/local/bin/xray-auto-update.sh
```

### Отключение автообновления:
Удалить задачу из cron
```bash
sudo crontab -l | grep -v "xray-auto-update.sh" | sudo crontab -
```
Удалить скрипт (опционально)
```bash
sudo rm -f /usr/local/bin/xray-auto-update.sh
```
### Безопасность
- PrivateKey никогда не выводится в логи и не передаётся по сети
- Перед каждым изменением создаётся бэкап конфига
- При любой ошибке установки — мгновенный откат к рабочей версии
- Используется только официальный установщик XTLS/Xray-install
- Конфиг проверяется командой xray -test перед перезапуском сервиса

### Требования для запуска
- ОС: Ubuntu / Debian / CentOS (с systemd)
- Доступ: root или пользователь с sudo
- Сеть: открытые порты 443/tcp и 443/udp
- Время: синхронизация через NTP (скрипт пытается включить автоматически)

### Если что-то пошло не так
- Проверьте логи: 
```bash
tail -50 /var/log/xray-setup.log
```
- Проверьте статус Xray: 
```bash
systemctl status xray --no-pager -l
```
- При необходимости восстановите бэкап:
```bash
sudo cp /usr/local/etc/xray/.backups/config.json.* /usr/local/etc/xray/config.json && sudo systemctl restart xray
```