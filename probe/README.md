# Проверка ТСПУ с российской точки

`tspu-check.pl` показывает, гибнут ли пакеты к вашим серверам на российском DPI.
Увидеть это может только сеть, которая стоит за ТСПУ: зарубежный VPS физически
не видит российский DPI.

Поэтому проверка вынесена на отдельный хост в РФ — например, на офисный сервер
за NAT. Он не принимает входящие соединения: сам раз в 4 часа заходит на
мониторинговый сервер по SSH и отдаёт результат.

```
[хост в РФ за NAT]                              [сервер мониторинга]
tspu-check.pl → JSON → исходящий SSH:22 → tspu-ingest.sh → tspu-remote.json
   ↑ systemd timer, 4 часа                                  ↑ отчёт и бот читают его
```

## Что нужно на хосте в РФ

- Linux и root (upstream-скрипту нужен raw ICMP-сокет);
- Perl (ставится установщиком);
- исходящий SSH до сервера мониторинга;
- сам хост должен быть в российской сети — тогда проверка настоящая.

Ubuntu 22.04 проверена.

## Установка

Скопируйте репозиторий на хост в РФ и запустите:

```bash
sudo ./probe/install-probe.sh root@5.144.179.124
```

Установщик поставит `tspu-check.pl`, сам пробник, systemd-таймер, создаст
SSH-ключ и напечатает строку, которую нужно добавить в
`/root/.ssh/authorized_keys` на сервере мониторинга:

```
restrict,command="/usr/local/sbin/tspu-ingest.sh" ssh-ed25519 AAAA... tspu-probe@host
```

`restrict` и `command=` означают, что этим ключом нельзя открыть shell, пробросить
порт или запустить что-то ещё — только `targets` и `push`.

Затем включите приём на сервере мониторинга в `/etc/warp-monitor.conf`:

```bash
TSPU_REMOTE="1"
TSPU_REMOTE_MAX_AGE="21600"   # 6 часов
```

## Как менять IP серверов

Ничего не нужно: пробник при каждом запуске спрашивает у сервера мониторинга
актуальный список адресов (`ssh <server> targets`), а тот берёт его из
`SELF_IP`, `PEER_IP`, `SERVER1_IP`, `SERVER2_IP` в `/etc/warp-monitor.conf`.

Поменяли IP на серверах — следующий запуск уже проверяет новые адреса.

Если сервер мониторинга недоступен, можно зафиксировать список вручную в
`/etc/tspu-probe.conf` на хосте в РФ:

```bash
PROBE_TARGETS="5.144.179.124,213.21.246.122"
```

Пустое значение (по умолчанию) — автоматический режим.

## Проверка

```bash
systemctl start tspu-probe.service
journalctl -u tspu-probe -n 20 --no-pager
```

На сервере мониторинга:

```bash
cat /var/lib/warp-monitor/tspu-remote.txt
/usr/local/sbin/tspu-check.sh --fresh
```

В отчёте и боте появится строка вида:

```
🛡 ТСПУ (Москва)
Helsinki: ✅ не заблокирован — ttl=5: ICMP Time Exceeded …
Aeza: ✅ не заблокирован — ttl=4: ICMP Time Exceeded …
```

## Настройки пробника

`/etc/tspu-probe.conf`:

| Параметр | Значение |
|---|---|
| `PROBE_SERVER` | `root@5.144.179.124` |
| `PROBE_PORT` | порт SSH, по умолчанию 22 |
| `PROBE_KEY` | `/root/.ssh/id_ed25519_tspu` |
| `PROBE_LABEL` | подпись в отчёте, например `ТСПУ (Москва)` |
| `PROBE_TARGETS` | пусто = брать список с сервера |
| `PROBE_TIMEOUT` | предел одной проверки, секунды |

## Удаление

```bash
sudo systemctl disable --now tspu-probe.timer
sudo rm -f /usr/local/sbin/tspu-probe.sh /usr/local/sbin/tspu-check.pl \
           /etc/systemd/system/tspu-probe.{service,timer}
sudo rm -f /etc/tspu-probe.conf /root/.ssh/id_ed25519_tspu*
```

И удалите строку с ключом из `authorized_keys` на сервере мониторинга.
