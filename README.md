# setup-xray-reality

Автоматическая настройка VPS под Xray (Reality + VLESS) с генерацией ссылок для клиентских приложений на устройствах

Скрипт:
- Установит/обновит Xray до последней стабильной версии
- Сгенерирует ключи Reality (если их ещё нет)
- Добавит первое устройство в параметр shortId(sid) в виде HEX (шестнадцатеричная строка, вроде "a1b45cdF")
- Выведет готовую ссылку `vless://...` для импорта в клиентское приложение на новом устройстве

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
- Добавит новое устройство в параметр shortId(sid) в конфиг сервера
- Выдаст новую ссылку `vless://...` для импорта в клиентское приложение на новом устройстве

### Проверка состояния конфига
```bash
# Чтобы проверить, что новое устройство появилось в списке можно выполнить команду:
sudo jq '.inbounds[] | select(.protocol=="vless" and .port==443) | .streamSettings.realitySettings.shortIds' /usr/local/etc/xray/config.json
# Посмотреть количество учётных записей с текущим UUID (должно быть 1)
sudo jq '.inbounds[] | select(.protocol=="vless" and .port==443) | .settings.clients | length' /usr/local/etc/xray/config.json
```

### Автообновление
Чтобы добавить автообновление Xray в крон (каждый понедельник в 04:00):
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/AleksandrHavok/setup-xray-reality/main/xray-auto-update.sh)
```

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
- Сеть: открытые порты 443/tcp  (UDP не требуется для Reality)
- Время: синхронизация через NTP (скрипт пытается включить автоматически)

### Если что-то пошло не так
Проверьте логи: 
```bash
tail -50 /var/log/xray-setup.log
```
Проверьте статус Xray: 
```bash
systemctl status xray --no-pager -l
```
При необходимости восстановите бэкап:
- Останавливаем Xray (чтобы файл не был занят)
```bash
sudo systemctl stop xray
```
-  Смотрим доступные бэкапы (отсортированы по дате, свежий сверху)
- Имя файла имеет формат: config.json.bak.YYYYMMDDHHMMSS
- Например: config.json.bak.20260416051824 = 2026 год, 04 месяц, 16 день, 05:18:24
```bash
ls -lt /usr/local/etc/xray/config.json.bak.*
```
- Выбираем нужный бэкап ПО ВРЕМЕНИ (до проблемного запуска) и восстанавливаем
- ВМЕСТО 20260416051824 подставьте время из вывода выше
```bash
sudo cp /usr/local/etc/xray/config.json.bak.20260416051824 /usr/local/etc/xray/config.json
```
- Проверяем, что конфиг валиден. Должно вывести: "Configuration OK."
```bash
sudo /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json
```
- Запускаем Xray
```bash
sudo systemctl start xray
```

Если в ссылке `vless://...` указан `pbk=__ВАШ_PUBLIC_KEY__`:
- Это значит, что скрипт не нашёл файл с публичным ключом `/usr/local/etc/xray/.reality_pubkey`.
- Если это первый запуск — ключ должен был создаться автоматически. Проверьте права на файл.
- Если вы переносили конфиг вручную — скопируйте ваш `PublicKey` в этот файл, заменив "ВАШ_PUBLIC_KEY" в команде:
   ```bash
   echo "ВАШ_PUBLIC_KEY" | sudo tee /usr/local/etc/xray/.reality_pubkey
   sudo chmod 600 /usr/local/etc/xray/.reality_pubkey
   ```
- После этого запустите скрипт снова — ссылка будет с реальным ключом.