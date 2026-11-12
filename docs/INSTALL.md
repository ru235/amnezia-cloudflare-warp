# Полная инструкция по установке

От чистого VPS до работающей связки «AmneziaWG → Cloudflare WARP» с мониторингом и (опционально) Telegram. Инструкция рассчитана на Ubuntu 22.04/24.04 и root-доступ по SSH.

- [0. Что понадобится](#0-что-понадобится)
- [1. Подготовка сервера](#1-подготовка-сервера)
- [2. Установка AmneziaWG](#2-установка-amneziawg)
- [3. Установка Cloudflare WARP](#3-установка-cloudflare-warp)
- [4. Установка проекта](#4-установка-проекта)
- [5. Проверка](#5-проверка)
- [6. Два сервера](#6-два-сервера)
- [7. Telegram (опция)](#7-telegram-опция)
- [8. Расписание](#8-расписание)
- [9. Обновление](#9-обновление)
- [10. Удаление](#10-удаление)

---

## 0. Что понадобится

**Обязательно:**

- VPS с Ubuntu 22.04 или 24.04, root.
- Доступ к веб-консоли провайдера (KVM/VNC) — страховка на случай ошибки в правилах.
- Домен не нужен.

**Опционально:**

- Второй VPS для парного мониторинга и резервного бота.
- Telegram-бот (токен от [@BotFather](https://t.me/BotFather)).

**Что должно быть установлено до проекта:**

1. AmneziaWG (контейнер Amnezia) — раздел 2.
2. Cloudflare WARP (`warp-cli`) — раздел 3.

> **Где взять VPS.** Оба сервера, на которых обкатывался проект, работают на [HostVDS](https://hostvds.com/?affiliate_uuid=59ca71b7-ebf7-485c-81ac-ec6da6a5d168) и [Aeza](https://aeza.net/?ref=827670): проверенные площадки, минимальные цены, оплата в рублях. У HostVDS тарифы от 1.5 € в месяц и бесплатная смена IP. Ссылки партнёрские — цена для вас не меняется.

**Схема после установки:**

```
клиент AmneziaWG
      │  UDP 44059 (прямо, без WARP)
      ▼
   VPS: amn0 → контейнер amnezia-awg
      │  расшифрованный трафик
      ▼
   FORWARD → CloudflareWARP (таблица 65743)
      │
      ▼
   интернет глазами Cloudflare
```

SSH, Caddy 80/443 и UDP-транспорт Amnezia помечаются `fwmark` и уходят через физический интерфейс (`eth0`/`enp0s3`) мимо WARP.

---

## 1. Подготовка сервера

Обновите пакеты и поставьте зависимости:

```bash
apt update && apt upgrade -y
apt install -y curl iptables python3 python3-matplotlib openssh-client ca-certificates gnupg lsb-release
```

Проверьте, что виден физический интерфейс и шлюз:

```bash
ip route show default
# default via 203.0.113.1 dev eth0 ...   (у разных провайдеров eth0/enp0s3/ens3)
```

Запомните имя интерфейса — оно может пригодиться при диагностике. Проект определяет его автоматически.

> **Важно:** не включайте ufw/firewalld «поверх» WARP. WARP ставит собственные правила nftables с `policy drop`; проект добавляет в них разрешения для SSH и ICMP. Если у вас уже настроен файрвол, сначала убедитесь, что SSH-порт открыт.

---

## 2. Установка AmneziaWG

Проект рассчитан на контейнер, который создаёт приложение **Amnezia** (протокол **AmneziaWG**). В результате на сервере появляются:

- контейнер с именем `amnezia-awg*` (например, `amnezia-awg2`);
- host-интерфейс `amn0`;
- опубликованный UDP-порт (обычно `44059`, но бывает и другой — установщик определяет его сам).

### Вариант А — приложение Amnezia (рекомендуется)

1. Установите [Amnezia](https://amnezia.org/) на компьютер или телефон.
2. Добавьте сервер: IP, root, SSH-ключ или пароль.
3. Выберите протокол **AmneziaWG**, установите.
4. Создайте хотя бы одного клиента и подключитесь — так вы убедитесь, что VPN работает **до** включения WARP.

### Вариант Б — скрипт AmneziaWG

Можно использовать `amneziawg-install.sh` из репозитория Amnezia. Проект ожидает, что трафик клиентов приходит на host-интерфейс `amn0`; если у вас другое имя, укажите его в конфиге (`AWG_IFACE`).

### Проверка

```bash
docker ps --format '{{.Names}}' | grep amnezia-awg
ip -brief addr show amn0
docker exec amnezia-awg2 awg show all dump | head -2
```

Последняя команда печатает строку интерфейса (в 4-м поле — UDP-порт) и строки пиров. Если команда работает — всё готово.

> Если контейнер называется иначе и не начинается с `amnezia-awg`, задайте порт вручную: `--awg-port 44059` при установке или `AWG_PORT` в конфиге.

---

## 3. Установка Cloudflare WARP

Официальный репозиторий Cloudflare:

```bash
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
  | tee /etc/apt/sources.list.d/cloudflare-client.list

apt update && apt install -y cloudflare-warp
```

> На Ubuntu 24.04 репозиторий Cloudflare может ещё не содержать `noble`. Если `apt update` ругается на отсутствующий Release, замените `$(lsb_release -cs)` на `jammy` — пакет совместим.

Регистрация и подключение:

```bash
warp-cli --accept-tos registration new
warp-cli --accept-tos connect
warp-cli --accept-tos status          # Status update: Connected
```

Проверьте, что трафик действительно идёт через WARP:

```bash
curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp)='
# ip=104.28.x.x
# warp=on
```

Интерфейс должен называться `CloudflareWARP`:

```bash
ip -brief addr show CloudflareWARP
```

> **Не включайте пока маршрутизацию клиентов вручную.** Проект сделает это сам и не сломает SSH.

---

## 4. Установка проекта

### 4.1. Клонирование

```bash
apt install -y git
git clone https://github.com/ru235/amnezia-cloudflare-warp.git
cd amnezia-cloudflare-warp
```

### 4.2. Один сервер

```bash
sudo ./install.sh
```

Скрипт:

1. проверит зависимости;
2. определит внешний IPv4, интерфейс WARP, контейнер и UDP-порт;
3. запишет `/etc/warp-monitor.conf`;
4. установит скрипты в `/usr/local/sbin` и юниты systemd;
5. применит правила маршрутизации;
6. включит таймеры монитора, отчёта и ротации;
7. выполнит первую проверку.

Если не хватает пакетов:

```bash
sudo ./install.sh --install-deps
```

Посмотреть план, ничего не меняя:

```bash
sudo ./install.sh --dry-run
```

### 4.3. Два сервера

На каждом сервере — свой запуск. Порядок не важен.

**Сервер 1 (например, Helsinki):**

```bash
sudo ./install.sh \
  --self-name Helsinki \
  --self-ip 203.0.113.10 \
  --peer-name Aeza \
  --peer-ip 203.0.113.20
```

**Сервер 2 (например, Aeza):**

```bash
sudo ./install.sh \
  --self-name Aeza \
  --self-ip 203.0.113.20 \
  --peer-name Helsinki \
  --peer-ip 203.0.113.10
```

`--self-ip` можно не указывать — определится автоматически.

### 4.4. Ключ для мониторинга пира

Чтобы отчёт и бот показывали данные второго сервера, первому нужен SSH-доступ ко второму. Установщик создаёт ключ `/root/.ssh/id_ed25519_monitor` и печатает публичную часть. Добавьте её на пира **с того сервера, где создан ключ**:

```bash
ssh root@203.0.113.20 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys" \
  < /root/.ssh/id_ed25519_monitor.pub
```

Проверка:

```bash
ssh -i /root/.ssh/id_ed25519_monitor -o BatchMode=yes root@203.0.113.20 'hostname'
```

Если серверов два, выполните обмен в обе стороны (на каждом сервере свой ключ и свой `authorized_keys`), либо разрешите мониторинг только в одну сторону — этого достаточно для отчёта на одном из них.

---

## 5. Проверка

### 5.1. Маршрутизация

```bash
# трафик с меткой должен уходить напрямую
ip route get 1.1.1.1 mark 0x100cf
# 1.1.1.1 via 203.0.113.1 dev eth0 ...   ← НЕ CloudflareWARP

# без метки — в туннель
ip route get 1.1.1.1
# 1.1.1.1 dev CloudflareWARP table 65743 ...

ip rule show
# 10: from all fwmark 0x100cf lookup main
# 99: not from all fwmark 0x100cf lookup 65743
```

### 5.2. Сервисы

```bash
systemctl status warp-amnezia-routing.service --no-pager
systemctl list-timers 'peer-monitor*' 'warp-*' --no-pager
```

### 5.3. Монитор

```bash
sudo /usr/local/sbin/peer-monitor.sh
tail -3 /var/lib/warp-monitor/history.csv
```

Заголовок и пример строки:

```
ts,peer_ok,peer_ms,warp_ok,awg_ok,disk,peers,total,warp4
1762920000,1,19,1,1,22,3,7,104.28.254.35
```

`peers` — активные клиенты (рукопожатие за последние 3 минуты), `total` — все пиры.

### 5.4. Клиент Amnezia

Подключите клиента и проверьте:

```bash
docker exec amnezia-awg2 awg show all dump | awk 'NF==9 {print $5, $6}'
```

Через 1–2 минуты в `history.csv` появится `peers > 0`. Сайт `https://www.cloudflare.com/cdn-cgi/trace` у клиента должен показывать `warp=on` и IP из диапазона Cloudflare.

### 5.5. Отчёт

```bash
sudo /usr/local/sbin/warp-daily-report.py
ls -lh /var/lib/warp-monitor/report-*.png
```

Без Telegram скрипт напечатает путь к PNG. С Telegram — отправит картинку в чат.

---

## 6. Два сервера

Парный режим даёт:

- вторая карточка в отчёте (WARP, IPv6, онлайн, диск, uptime);
- график задержки до пира;
- алерт «сервер недоступен > 5 минут» и уведомление о восстановлении;
- смены IPv4 на обоих серверах;
- резервного бота: `--bot-role passive` поднимает бота на втором сервере, если первый недоступен.

Что нужно:

1. На обоих серверах выполнена установка (раздел 4.3).
2. На каждом указан `--peer-ip` другого.
3. Публичные ключи мониторинга добавлены в `authorized_keys` (раздел 4.4).
4. TCP/22 доступен между серверами.

Проверка, что отчёт видит пира:

```bash
sudo /usr/local/sbin/peer-monitor.sh
grep PEER_FAIL /var/lib/warp-monitor/state.env
```

`PEER_FAIL=0` — пир доступен.

---

## 7. Telegram (опция)

Telegram полностью опционален. Без него работают маршрутизация, ротация, монитор и PNG-отчёты.

Включение в интерактивном режиме:

```bash
sudo ./install.sh --telegram
```

Или одной командой:

```bash
sudo ./install.sh --telegram --token '123456789:AAH...' --chat 123456789 --bot-role active
```

Что произойдёт:

- создастся `/etc/warp-telegram.env` с правами `600`;
- монитор начнёт отправлять алерты;
- отчёт будет уходить картинкой;
- запустится бот (`warp-bot.service`);
- на втором сервере с `--bot-role passive` включится `bot-guard.timer`.

Полная инструкция по получению токена и chat id, командам бота и резервному режиму: [TELEGRAM.md](TELEGRAM.md).

Отключить бота, оставив алерты и отчёты:

```bash
sudo ./install.sh --telegram --no-bot
```

Полностью убрать Telegram: удалите `/etc/warp-telegram.env` и выполните `systemctl disable --now warp-bot.service bot-guard.timer`.

---

## 8. Расписание

По умолчанию (UTC):

| Задача | Время | Юнит |
|---|---|---|
| Мониторинг | каждую минуту | `peer-monitor.timer` |
| Отчёт | 05:00 | `warp-daily-report.timer` |
| Ротация WARP | 04:45 | `warp-rotate.timer` |
| Проверка резервного бота | каждую минуту | `bot-guard.timer` |

Изменить время:

```bash
sudo ./install.sh --report-utc 05:00 --rotate-utc 04:45 --report-label "08:00 MSK"
```

Или отредактировать `OnCalendar` в `/etc/systemd/system/warp-*.timer` и выполнить:

```bash
sudo systemctl daemon-reload
sudo systemctl restart warp-daily-report.timer warp-rotate.timer
```

> Время в таймерах — **UTC**. `REPORT_TIME` в конфиге — только подпись в шапке отчёта, на расписание не влияет.

Ротация — это `disconnect → rotate-keys → connect`. IPv6 меняется почти всегда, IPv4 — только при переключении на другой PoP Cloudflare. Это нормально: журнал `ipv4.log` фиксирует реальные смены, а не попытки.

---

## 9. Обновление

```bash
cd amnezia-cloudflare-warp
git pull
sudo ./install.sh
```

Установщик идемпотентен: он сохранит прежние значения конфига как значения по умолчанию, сделает резервную копию `/etc/warp-monitor.conf.bak` и перезапустит сервисы. Данные мониторинга не удаляются.

После обновления скриптов вручную (без установщика) не забудьте:

```bash
sudo systemctl restart warp-bot.service    # если бот включён
sudo systemctl daemon-reload
```

---

## 10. Удаление

```bash
sudo ./uninstall.sh
```

Убирает юниты и скрипты, данные и конфиги оставляет.

```bash
sudo ./uninstall.sh --purge
```

Удаляет также `/var/lib/warp-monitor`, `/etc/warp-monitor.conf`, `/etc/warp-telegram.env`, лог ротации и снимает правила маршрутизации.

Только снять правила, оставив сервисы:

```bash
sudo ./uninstall.sh --flush-routing
```

> WARP и AmneziaWG удаляются отдельно (`apt remove cloudflare-warp`, удаление контейнера в приложении Amnezia). Правила nftables, добавленные в таблицу `inet cloudflare-warp`, исчезнут при перезапуске WARP или перезагрузке.

---

## Что дальше

- [ARCHITECTURE.md](ARCHITECTURE.md) — почему правила именно такие.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — если что-то не работает.
- [TELEGRAM.md](TELEGRAM.md) — бот и уведомления.
