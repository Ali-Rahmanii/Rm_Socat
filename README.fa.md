# rm-socat

**English docs: [README.md](README.md)**

یک ابزار ساده و خودکفا برای فوروارد TCP/UDP روی سرورهای لینوکسی که ترافیک
را به چند سرور بک‌اند ریلی می‌کنند — جایگزین یک ست‌آپ قدیمی‌تر مبتنی بر
`crontab @reboot` + `screen` + `socat` که زیر فشار، بی‌سروصدا پورت‌هایش
بسته می‌شد (وقتی `socat` می‌مرد، چیزی دوباره بالاش نمی‌آورد). این‌جا هر
فوروارد یک سرویس واقعی `systemd` با `Restart=always` است، پس اگر `socat`
کشته شود حدود ۱ ثانیه بعد خودش برمی‌گردد — نه اینکه تا ریبوت بعدی خاموش
بماند.

## چرا نه فقط `screen` + کرون؟

`@reboot screen -AmdS ... socat ...` فقط یک‌بار موقع بوت اجرا می‌شود. اگر
آن پروسه بعداً بمیرد — OOM kill، رسیدن به سقف fd/پروسس زیر یک موج
کانکشن، یک خطای موقت شبکه — سشن `screen`ای که توش بوده هم می‌بندد، و آن
پورت تا وقتی کسی دستی ریبوت یا کرون‌تب را دوباره اجرا نکند برنمی‌گردد.
هیچ نظارتی روی آن نیست. rm-socat این را با یک یونیت `systemd` به‌ازای هر
فوروارد جایگزین می‌کند، با `Restart=always` + `StartLimitIntervalSec=0`
(هیچ‌وقت از تلاش دوباره دست نمی‌کشد)، و سقف‌های کرنل هم از قبل بالا برده
شده‌اند تا همان سقفی که پورت‌ها را می‌کشت خیلی عقب‌تر برود.

## معماری

```
  کاربر ──▶  این سرور (local_port)  ══ socat ══▶  remote_host:remote_port
             rm-socat@<name>-tcp/udp.service
```

هر قانون در `ports.conf` یک یا دو نمونه (instance) از یونیت الگو
(`rm-socat@<name>-tcp`, `rm-socat@<name>-udp`) می‌سازد که همه یک فایل
یونیت مشترک دارند (`systemd/rm-socat@.service`) و `ExecStart` آن
`bin/rm-socat-run.sh <instance>` را صدا می‌زند — یک هلپر کوچک که قانون
مربوطه را در `ports.conf` پیدا می‌کند و دستور `socat` متناظرش را
`exec` می‌کند، پس PIDای که `systemd` نظارت می‌کند خودِ `socat` است.

**یک سوکت هم IPv4 و هم IPv6 را همزمان جواب می‌دهد** (پیش‌فرض `ip = dual`
— `TCP-LISTEN`/`UDP-LISTEN` ساده، بدون پسوند `4`/`6`)، به‌جای اجرای یک
لیسنر جدا برای هر خانواده‌ی آدرس. این نیاز به `net.ipv6.bindv6only=0`
دارد که `install.sh` خودش تنظیمش می‌کند. اگر لازم شد یک قانون را مجبور
به یک خانواده‌ی خاص کنید، `ip = 4` یا `ip = 6` بگذارید.

بدون لاگ‌گیری: همه‌ی یونیت‌ها با `StandardOutput=null` /
`StandardError=null` اجرا می‌شوند — در حالت عادی هیچ چیز به journal یا
دیسک نوشته نمی‌شود، پس زیر ترافیک سنگین هیچ فشار I/O اضافه‌ای هم از این
بابت نیست.

## فرمت `ports.conf`

```
name , local_port , remote_host , remote_port , proto , ip
```

| فیلد          | معنی                                              | مقادیر                  |
|---------------|-----------------------------------------------------|--------------------------|
| `name`        | شناسه‌ی یکتا → اسم نمونه‌ی systemd می‌شود           | `[A-Za-z0-9_-]+`        |
| `local_port`  | پورتی که این سرور روی آن گوش می‌دهد                 | `1-65535`                |
| `remote_host` | دامنه یا آی‌پی مقصد                                 | هرچیزی                   |
| `remote_port` | پورت روی `remote_host`                              | `1-65535`                |
| `proto`       | چه سوکت‌هایی باز شود                                 | `tcp` \| `udp` \| `both` |
| `ip`          | خانواده‌ی آدرس                                       | `dual` (پیش‌فرض) \| `4` \| `6` |

توضیح کامل فرمت و مثال‌ها داخل [`ports.conf.example`](ports.conf.example)
هست. **خودِ `ports.conf` در `.gitignore` است** — دامنه/آی‌پی واقعی شما
هیچ‌وقت به این ریپو کامیت نمی‌شود، فقط نمونه‌اش (`ports.conf.example`)
کامیت شده.

## نصب

```bash
git clone https://github.com/Ali-Rahmanii/Rm_Socat.git /opt/rm-socat
cd /opt/rm-socat
sudo ./install.sh
```

کاری که `install.sh` می‌کند:
- اگر `socat` نصب نبود، نصبش می‌کند (apt/dnf/yum/apk)
- یونیت الگوی `systemd` را نصب می‌کند
- بار اول `ports.conf.example` را به `ports.conf` کپی می‌کند
- سقف‌های کرنل/`ulimit` را برای کانکشن بالا بالا می‌برد:
  `net.ipv6.bindv6only=0`، `net.core.somaxconn`، `tcp_max_syn_backlog`،
  `fs.file-max`، و `nofile`/`nproc` — به‌علاوه‌ی `LimitNOFILE=1048576` و
  `TasksMax=infinity` روی خودِ هر یونیت.

بعد `ports.conf` را ویرایش کن و:

```bash
sudo ./manage.sh apply
```

## استفاده

```bash
./manage.sh                 # منوی رنگی تعاملی
./manage.sh add             # افزودن قانون (پرامپت می‌گیرد، یا آرگومان مستقیم بده)
./manage.sh remove <name>   # توقف، غیرفعال‌سازی و حذف یک قانون
./manage.sh apply           # هماهنگ‌سازی systemd با ports.conf فعلی
./manage.sh status          # جدول زنده: وضعیت systemd + وضعیت واقعی سوکت هر قانون
./manage.sh restart         # ری‌استارت همه‌ی فورواردها
./manage.sh test            # تأیید اینکه همه‌ی پورت‌های کانفیگ‌شده واقعاً LISTEN هستند
./manage.sh stress <port> [tcp|udp] [step] [hold] [max]
                             # کانکشن همزمان را پله‌پله بالا می‌برد تا سقف را پیدا کند
./manage.sh purge           # پاکسازی کامل (پایین را ببین)
```

افزودن/حذف پورت هم از منو، هم از CLI (`./manage.sh add name lport host
rport tcp dual`)، و هم دستی (ویرایش مستقیم `ports.conf` — گزینه ۸ در منو
یا هر ادیتوری — و بعد `./manage.sh apply`) کار می‌کند.

## تست‌ها

- `./manage.sh test` — تست سلامت: همین الان همه‌ی پورت‌های کانفیگ‌شده
  واقعاً `LISTEN` هستند؟ خروجی رنگی ✅/❌، بدون نوشتن هیچ فایلی.
- `./manage.sh stress <port> [tcp|udp] [step] [hold] [max]` — با bash خالص
  (`/dev/tcp` / `/dev/udp`، بدون هیچ ابزار اضافه) پله‌پله کانکشن همزمان
  باز می‌کند تا اولین شکست‌ها را ببیند و سقف واقعی را گزارش کند. **این
  تست کل زنجیره‌ی فوروارد تا سرور مقصد واقعی را زیر فشار می‌گذارد**، نه
  فقط سوکت لوکال — منو قبل از اجرا هشدار می‌دهد و تأیید می‌گیرد.

## پاکسازی کامل

```bash
sudo ./manage.sh purge
# یا:
sudo ./uninstall.sh
```

همه‌ی نمونه‌های `rm-socat@*` را متوقف/غیرفعال می‌کند، یونیت الگوی
`systemd` و drop-inهای sysctl/limits که نصب کرده بود را پاک می‌کند، و در
آخر با یک تأییدیه‌ی جدا و صریح («بنویس YES») می‌پرسد که آیا کل این پوشه
(شامل `ports.conf` و همه‌ی اسکریپت‌ها) هم حذف شود — چیزی باقی نمی‌ماند.

## لایسنس

MIT — فایل [LICENSE](LICENSE) را ببین.
