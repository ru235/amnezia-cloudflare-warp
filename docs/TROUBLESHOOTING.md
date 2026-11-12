# Диагностика

Симптомы собраны по реальным случаям. Начинайте с быстрой проверки, затем переходите к разделу.

## Быстрая проверка

```bash
# 1. WARP подключён?
warp-cli --accept-tos status

# 2. Правила на месте?
ip rule show
ip route get 1.1.1.1 mark 0x100cf

# 3. Трафик клиентов идёт в WARP?
ip route get 1.1.1.1

# 4. Контейнер жив?
docker ps --format '{{.Names}}' | grep amnezia-awg

# 5. Монитор пишет?
tail -3 /var/lib/warp-monitor/history.csv

# 6. Сервисы
systemctl status warp-amnezia-routing.service --no-pager
systemctl list-timers 'peer-monitor*' 'warp-*' --no-pager
```

---

## Потерян SSH после установки

**Симптом:** сессия зависла, новый SSH не подключается, но VPN у клиентов работает. Сервер отвечает на ping или нет.

**Причина:** ответы SSH уходят в WARP (или их режет nftables с `policy drop`).

**Что делать:** зайдите через веб-консоль провайдера и выполните:

```bash
ip rule show | grep 0x100cf
# если правила нет:
ip rule add priority 10 fwmark 0x100cf lookup main

# проверка: должно быть dev eth0/enp0s3
ip route get 1.1.1.1 mark 0x100cf

# разрешить SSH/ICMP в nftables WARP
nft insert rule inet cloudflare-warp input  tcp dport 22 accept
nft insert rule inet cloudflare-warp output tcp sport 22 accept
nft insert rule inet cloudflare-warp output ip protocol icmp accept

# переприменить всё
/usr/local/sbin/warp-amnezia-routing.sh
```

Если SSH не отвечает даже с консоли — временно отключите WARP: `warp-cli --accept-tos disconnect`, войдите, затем разбирайтесь с правилами.

---

## Amnezia подключается, но интернета нет

**Симптом:** клиент показывает «подключено», но сайты не открываются; в логах WARP `Dropping martian, tun should not have seen this`.

**Причина:** ответы AWG-транспорта или DNAT уходят в туннель.

**Проверка:**

```bash
ip route get 1.1.1.1 mark 0x100cf
ip rule show
iptables -t mangle -S PREROUTING
iptables -t mangle -S OUTPUT
```

**Решение:**

```bash
/usr/local/sbin/warp-amnezia-routing.sh
systemctl restart warp-amnezia-routing.service
```

Убедитесь, что:

- `BYPASS_MARK` в `/etc/warp-monitor.conf` совпадает с меткой в правилах (`0x100cf`);
- `BYPASS_PRIO=10` (меньше, чем у правила WARP);
- UDP-порт Amnezia в правилах реальный:

```bash
docker port amnezia-awg2
# или
docker exec amnezia-awg2 awg show all dump | head -1 | awk '{print $4}'
```

Если порт другой — задайте `AWG_PORT` в конфиге и перезапустите `warp-amnezia-routing.service`.

---

## Сайты открываются частично, «тяжёлые» страницы зависают

**Причина:** MTU WARP меньше MTU AmneziaWG, PMTU не доходит.

**Решение:** проверить кламп MSS:

```bash
iptables -t mangle -S FORWARD | grep TCPMSS
```

Если правила нет:

```bash
iptables -t mangle -A FORWARD -o CloudflareWARP -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

Проект добавляет его автоматически; отсутствие правила означает, что `warp-amnezia-routing.sh` не выполнялся.

---

## Не работает ping до сервера

**Причина:** nftables WARP дропает ICMP.

```bash
nft list chain inet cloudflare-warp input | grep -i icmp
nft insert rule inet cloudflare-warp input ip protocol icmp accept
nft insert rule inet cloudflare-warp output ip protocol icmp accept
```

---

## `ip route get 1.1.1.1 mark 0x100cf` показывает CloudflareWARP

Это значит, что правило обхода стоит **ниже** правила WARP и не срабатывает.

```bash
ip rule show
# плохо: 99: not from all fwmark 0x100cf lookup 65743
#        10-го правила нет

ip rule add priority 10 fwmark 0x100cf lookup main
ip route get 1.1.1.1 mark 0x100cf
```

Монитор проверяет это каждую минуту и исправляет сам. Если исправление не помогает — проверьте, что `BYPASS_MARK` в конфиге не пустой и совпадает с меткой в iptables.

---

## WARP не подключается

```bash
warp-cli --accept-tos status
journalctl -u warp-svc -n 100 --no-pager
```

Типичные причины:

- нет регистрации: `warp-cli --accept-tos registration new`;
- исчерпан лимит устройств в аккаунте Cloudflare — перерегистрируйте или отвяжите устройство;
- провайдер блокирует WARP — попробуйте `warp-cli --accept-tos mode warp` (протокол WireGuard) или `doh`;
- интерфейс не появился: `ip link show CloudflareWARP`.

Если WARP долго не поднимается, клиентский трафик блокируется anti-leak guard'ом — это ожидаемо и защищает от утечки.

---

## Контейнер Amnezia не найден

```bash
docker ps -a --format '{{.Names}} {{.Status}}' | grep -i amnezia
```

- Контейнер остановлен → запустите его в приложении Amnezia или `docker start <name>`.
- Имя не начинается с `amnezia-awg` → укажите порт вручную (`AWG_PORT`) и поправьте проверки, либо пересоздайте сервер в Amnezia.
- Нет интерфейса `amn0` → контейнер не поднял туннель; смотрите `docker logs <name>`.

---

## Отчёт не строится

```bash
sudo /usr/local/sbin/warp-daily-report.py
```

| Ошибка | Решение |
|---|---|
| `ModuleNotFoundError: matplotlib` | `apt install -y python3-matplotlib` |
| `No such file or directory: history.csv` | монитор ещё не запускался: `sudo /usr/local/sbin/peer-monitor.sh` |
| Пустой график | данных меньше суток — это нормально |
| `Font family not found` | `apt install -y fonts-dejavu-core` |
| Долго выполняется | SSH к пиру по таймауту 40 с — проверьте ключ и доступность |

Без Telegram отчёт просто сохраняется в `/var/lib/warp-monitor/report-*.png`.

---

## В отчёте «—» вместо онлайна

Нет данных `peers/total`. Причины:

1. Старый `history.csv` — миграция выполняется автоматически при первом запуске новой версии монитора.
2. Контейнер не найден — см. выше.
3. `awg show all dump` не отдаёт строки: проверьте вручную:

```bash
docker exec amnezia-awg2 awg show all dump
```

Активным считается пир с рукопожатием моложе 180 секунд.

---

## Смены IPv4 = 0

Это нормально, если WARP не переподключался к другому PoP. На бесплатном тарифе IPv4 привязан к PoP, поэтому ежедневная ротация меняет IPv6, а IPv4 — только при смене PoP.

Проверьте журнал:

```bash
cat /var/lib/warp-monitor/ipv4.log
curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='
```

Если адрес в журнале совпадает с текущим и запись одна — смен не было. Формула в отчёте вычитает начальную запись, поэтому «0 смен» — корректный результат.

---

## Таймеры не срабатывают

```bash
systemctl list-timers --all | grep -E 'peer-monitor|warp-|bot-guard'
systemctl status peer-monitor.timer --no-pager
```

- Время в юнитах — **UTC**. `05:00` в таймере — это `08:00` по Москве.
- После правки юнитов нужен `systemctl daemon-reload`.
- `Persistent=true` догоняет пропущенный запуск после выключения сервера.
- Проверить конкретный запуск: `systemctl start warp-daily-report.service` и `journalctl -u warp-daily-report -n 50`.

---

## Бот молчит

1. `systemctl status warp-bot.service` — запущен?
2. `journalctl -u warp-bot.service -n 50` — есть `409 Conflict`? Значит, работает второй экземпляр: остановите бота на другом сервере или проверьте `bot-guard`.
3. `curl .../getMe` — токен жив?
4. chat id в `/etc/warp-telegram.env` совпадает с чатом, откуда пишете?
5. `sudo /usr/local/sbin/warp-bot.py --test` — тексты собираются?

`409 Conflict` — самая частая причина на двух серверах. Убедитесь, что `BOT_ROLE=active` только на одном.

---

## Второй сервер «недоступен», хотя работает

```bash
ssh -i /root/.ssh/id_ed25519_monitor -o BatchMode=yes root@203.0.113.20 'hostname'
```

- `Permission denied` → публичный ключ не добавлен в `authorized_keys` пира.
- `Host key verification failed` → удалите устаревший ключ: `ssh-keygen -R 203.0.113.20`.
- Таймаут → закрыт TCP/22 между серверами.
- Работает, но в отчёте «—» → на пире не установлен проект или не совпадает `SELF_IP`.

---

## Кончилось место на диске

WARP-отчёты и логи занимают немного, но на маленьком диске это заметно.

```bash
du -sh /var/lib/warp-monitor /var/log/warp-rotate.log
```

Проект хранит 7 последних PNG и обрезает `ipv4.log` до 1000 строк. Если диск всё равно полон:

```bash
journalctl --vacuum-size=100M
apt clean
find /var/lib/warp-monitor -name 'report-*.png' -mtime +7 -delete
```

Монитор присылает алерт при 90% и снимает его ниже 85%.

---

## После перезагрузки пропали правила

```bash
systemctl status warp-amnezia-routing.service --no-pager
```

Юнит включён в `multi-user.target`, выполняется после `warp-svc.service` и `docker.service`. Если контейнер Amnezia стартует позже и пересоздаёт `amn0`, подождите минуту — монитор переприменит правила. Принудительно:

```bash
systemctl restart warp-amnezia-routing.service
```

---

## Ubuntu 24.04: apt не видит пакет WARP

```
E: The repository 'https://pkg.cloudflareclient.com noble Release' does not have a Release file.
```

Замените кодовое имя на `jammy`:

```bash
sed -i 's/noble/jammy/' /etc/apt/sources.list.d/cloudflare-client.list
apt update && apt install -y cloudflare-warp
```

---

## Сбор диагностики для issue

```bash
{
  echo "### uname"; uname -a
  echo "### warp"; warp-cli --accept-tos status
  echo "### ip rule"; ip rule show
  echo "### ip route"; ip route show
  echo "### route mark"; ip route get 1.1.1.1 mark 0x100cf
  echo "### iptables mangle"; iptables -t mangle -S
  echo "### iptables filter"; iptables -S FORWARD
  echo "### nft"; nft list table inet cloudflare-warp
  echo "### docker"; docker ps --format '{{.Names}} {{.Image}}'
  echo "### awg"; docker exec amnezia-awg2 awg show all dump | head -3
  echo "### timers"; systemctl list-timers 'peer-monitor*' 'warp-*'
  echo "### history"; tail -5 /var/lib/warp-monitor/history.csv
} > /tmp/diag.txt
```

Перед публикацией удалите из файла IP-адреса и ключи, если они для вас чувствительны.
