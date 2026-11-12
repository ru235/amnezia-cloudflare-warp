# Архитектура

Документ объясняет, как устроена связка и почему правила выглядят именно так. Если вы собираетесь что-то менять в маршрутизации — начните отсюда.

## Компоненты

```
┌──────────────────────────── VPS ────────────────────────────┐
│                                                             │
│  клиенты ──UDP/44059──► amn0 ──► [amnezia-awg container]    │
│                                      │ расшифровка          │
│                                      ▼                      │
│                              FORWARD (netfilter)            │
│                                      │                      │
│                                      ▼                      │
│                            CloudflareWARP (table 65743)     │
│                                      │                      │
│  SSH / Caddy / AWG ──fwmark──────────┼──► eth0/enp0s3 ──► Internet
│                                      │                      │
│  peer-monitor ──► history.csv / ipv4.log / state.env        │
│  warp-daily-report ──► PNG ──► Telegram (опция)             │
│  warp-bot ◄── long polling ──► Telegram (опция)             │
└─────────────────────────────────────────────────────────────┘
```

| Компонент | Роль |
|---|---|
| `warp-amnezia-routing.sh` | policy routing, netfilter, nftables; идемпотентен |
| `peer-monitor.sh` | минутная проверка, сбор метрик, алерты, самовосстановление |
| `warp-rotate.sh` | ежедневное переподключение WARP с новыми ключами |
| `warp-daily-report.py` | PNG-дашборд, сводка по двум серверам, отправка |
| `warp-bot.py` | интерактивный Telegram-бот |
| `bot-guard.sh` | поднимает/останавливает бота в зависимости от доступности пира |

## Путь пакета

### От клиента в интернет

1. Клиент Amnezia отправляет зашифрованный UDP на `VPS:44059`.
2. Пакет приходит на физический интерфейс и через DNAT попадает в контейнер.
3. Контейнер расшифровывает трафик; на хосте он появляется на `amn0` с адресом из `172.x`/`10.x`.
4. `filter/FORWARD` разрешает `amn0 → CloudflareWARP`.
5. `nat/POSTROUTING` делает MASQUERADE в `172.16.0.0/12`.
6. WARP шифрует и отправляет трафик в Cloudflare.

### Обратный трафик

Ответы из WARP приходят на `CloudflareWARP` и по `conntrack ESTABLISHED` уходят обратно в `amn0`. Здесь ничего помечать не нужно: маршрут выбирается по таблице `main` и соединению.

### Служебный трафик

Проблема: WARP перехватывает **весь** исходящий трафик, включая ответы SSH, Caddy и UDP-транспорта Amnezia. Если ответ SSH уйдёт в туннель, он выйдет с IP Cloudflare и будет отброшен как «martian» — сервер «пропадёт» из сети.

Решение — пометить такие пакеты и завернуть их в `main` **до** правила WARP:

| Что | Где помечается |
|---|---|
| UDP-ответы AWG-транспорта (`--sport 44059`) | `mangle PREROUTING -i amn0` |
| Ответы на DNAT (Caddy 80/443, AWG) | `mangle PREROUTING --ctstate DNAT` |
| SSH-ответы (`--sport 22`) | `mangle OUTPUT` |
| Caddy (`--sport 80/443`, UDP 443) | `mangle OUTPUT` |
| ICMP echo-reply | `mangle OUTPUT` |

Далее политика маршрутизации:

```
10:   from all fwmark 0x100cf lookup main      ← наше правило
99:   not from all fwmark 0x100cf lookup 65743 ← правило WARP
32766: from all lookup main
```

`0x100cf` — метка, которую WARP сам исключает из своего туннеля. Мы используем её как основную, но всё равно добавляем явное правило с приоритетом 10: оно работает даже если WARP поменяет метку или приоритет. На разных версиях WARP его правило оказывается на приоритете 99 или 32765 — поэтому «выше» означает именно меньший номер.

Проверка:

```bash
ip route get 1.1.1.1 mark 0x100cf   # dev eth0
ip route get 1.1.1.1                # dev CloudflareWARP table 65743
```

## netfilter

### mangle

```
PREROUTING -i amn0 -p udp --sport $AWG_PORT        MARK 0x100cf
PREROUTING -m conntrack --ctstate DNAT             MARK 0x100cf
OUTPUT -p tcp --sport 22                            MARK 0x100cf
OUTPUT -p tcp --sport 80                            MARK 0x100cf
OUTPUT -p tcp --sport 443                           MARK 0x100cf
OUTPUT -p udp --sport 443                           MARK 0x100cf
OUTPUT -p icmp --icmp-type echo-reply               MARK 0x100cf
FORWARD -o CloudflareWARP -p tcp --syn              TCPMSS --clamp-mss-to-pmtu
```

### filter

```
FORWARD -i amn0      -o CloudflareWARP  ACCEPT
FORWARD -i docker0   -o CloudflareWARP  ACCEPT
FORWARD -i br-+      -o CloudflareWARP  ACCEPT
FORWARD -i CloudflareWARP -o amn0/docker0/br-+  ESTABLISHED,RELATED ACCEPT
```

### nat

```
POSTROUTING -s 172.16.0.0/12 -o CloudflareWARP  MASQUERADE
```

`TCPMSS --clamp-mss-to-pmtu` обязателен: MTU WARP меньше MTU AmneziaWG, без клампа крупные пакеты зависают (сайты открываются, но «тяжёлые» страницы — нет).

## nftables

WARP создаёт таблицу `inet cloudflare-warp` с `policy drop` на `input` и `output`. Без разрешений сервер выглядит полностью офлайн: SSH не отвечает, ping не работает, при этом VPN продолжает работать. Скрипт добавляет:

```
nft insert rule inet cloudflare-warp input  tcp dport 22 accept
nft insert rule inet cloudflare-warp output tcp sport 22 accept
nft insert rule inet cloudflare-warp output ip protocol icmp accept
```

Вставка идемпотентна: перед добавлением проверяется наличие правила.

## Anti-leak guard

На время ротации (`disconnect → rotate-keys → connect`) WARP недоступен. Если в этот момент клиентский трафик пойдёт через физический интерфейс, он «утечёт» с реальным IP сервера. `warp-rotate.sh` создаёт временную цепочку:

```
FORWARD -m conntrack --ctstate DNAT                    ACCEPT   # ответы Caddy/AWG
FORWARD -i amn0 -o <uplink> -p udp --sport $AWG_PORT   ACCEPT   # рукопожатия
FORWARD -i amn0 -o <uplink>                            DROP
FORWARD -i docker0 -o <uplink>                         DROP
FORWARD -i br-+ -o <uplink>                            DROP
```

Цепочка удаляется по завершении и по сигналам `EXIT/INT/TERM`.

## Мониторинг

`peer-monitor.timer` запускает `peer-monitor.sh` раз в минуту. Одна итерация:

1. Проверка пира по TCP/22 (если задан `PEER_IP`), замер времени.
2. `warp-cli status`, наличие контейнера `amnezia-awg*`, заполнение диска.
3. Внешний IPv4 WARP через `cdn-cgi/trace`; при смене — запись в `ipv4.log`.
4. `awg show all dump` внутри контейнера:
   - `peers` — пиры с рукопожатием моложе 180 секунд;
   - `total` — все пиры;
   - `last_hs`, `LAST_HS_PEER` — самое свежее рукопожатие.
5. Строка в `history.csv`.
6. Алерты (только если настроен Telegram).
7. Повторное применение правил маршрутизации (WARP сбрасывает их при переподключении).
8. Проверка bypass-маршрута: если `ip route get 1.1.1.1 mark $BYPASS_MARK` вдруг указывает на `CloudflareWARP`, правило переставляется на приоритет 10, при неудаче — алерт.

### Файлы состояния

| Файл | Содержимое |
|---|---|
| `history.csv` | `ts,peer_ok,peer_ms,warp_ok,awg_ok,disk,peers,total,warp4` |
| `ipv4.log` | `epoch ISO8601 ipv4` при каждой смене |
| `last_warp4` | последний известный IPv4 |
| `state.env` | счётчики и флаги алертов, `LAST_HS`, `LAST_HS_PEER` |
| `bot-guard.state` | счётчик недоступности пира для резервного бота |

Старые `history.csv` без колонок `peers,total,warp4` мигрируют автоматически при первом запуске.

### Определение активных клиентов

`awg show all dump` печатает 9 полей на пира:

```
iface  pubkey  psk  endpoint  allowed_ips  latest_handshake  rx  tx  keepalive
```

Активный — `latest_handshake > 0` и `now - latest_handshake < 180`. Порог 180 секунд покрывает штатный keepalive AmneziaWG и не зависит от того, сколько данных передаёт клиент.

### Смены IPv4

`ipv4.log` получает запись только при реальной смене адреса. Первая запись — это начальное состояние, а не смена, поэтому в отчёте показывается `N - 1`.

## Отчёт

`warp-daily-report.py`:

1. Собирает локальные метрики.
2. Если задан `PEER_IP` — идёт по SSH с ключом `/root/.ssh/id_ed25519_monitor` и выполняет тот же набор команд на пире.
3. Читает последние 1440 строк `history.csv` (24 часа).
4. Рисует дашборд в matplotlib (Agg, без дисплея) и сохраняет PNG в `/var/lib/warp-monitor`.
5. Отправляет фото в Telegram, если настроен токен; иначе просто печатает путь.
6. Хранит 7 последних PNG.

Доступность в карточке — доля успешных проверок пира за 24 часа. Если пира нет, карточка одна, а график пользователей занимает всю ширину.

## Бот

`warp-bot.py` работает на long polling (`getUpdates`), без вебхука и открытых портов. Кэш статусов — 30 секунд, чтобы кнопки не тормозили. Команды и кнопки описаны в [TELEGRAM.md](TELEGRAM.md).

`bot-guard.sh` запускается раз в минуту **только** при `BOT_ROLE=passive`. Логика:

- пир отвечает по TCP/22 → бот на этом сервере остановлен;
- пир не отвечает 5 минут подряд → бот запускается.

Так на двух серверах одновременно активен ровно один бот, и он переживает падение основного.

## Безопасность

- Токен Telegram лежит в `/etc/warp-telegram.env` с правами `600`.
- Бот принимает команды только из `TG_CHAT`; чужие сообщения игнорируются.
- SSH-ключ мониторинга — отдельный (`id_ed25519_monitor`), без пароля, только для чтения метрик. При желании ограничьте его в `authorized_keys` через `command=`.
- Проект не открывает новых портов: AWG и Caddy работают как раньше.

## Ограничения

- IPv4 WARP на бесплатном тарифе привязан к PoP Cloudflare и меняется только при переподключении к другому PoP. Ежедневная ротация меняет IPv6.
- WARP не гарантирует скорость и доступность; при недоступности WARP клиентский трафик блокируется anti-leak guard'ом до восстановления.
- Мониторинг пира требует SSH-доступа между серверами.
