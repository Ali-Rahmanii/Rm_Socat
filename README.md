# rm-socat

**مستندات فارسی: [README.fa.md](README.fa.md)**

A small, self-contained TCP/UDP port-forwarder for Linux boxes that relay
traffic to a set of backend servers — built to replace a `crontab @reboot`
+ `screen` + `socat` setup that would silently drop ports under load (once
`socat` died, nothing ever brought it back). Every forward is a real
`systemd` service with `Restart=always`, so a killed `socat` process comes
back in ~1 second instead of staying dead until the next reboot.

## Why not just `screen` + cron?

`@reboot screen -AmdS ... socat ...` runs `socat` once, at boot. If that
process dies later — OOM kill, an fd/process ceiling hit under a burst of
connections, a transient network error — the `screen` session it lived in
exits too, and the port simply never comes back until someone reboots or
re-runs the crontab by hand. There is no supervision. rm-socat replaces
that with one `systemd` unit per forward, `Restart=always` +
`StartLimitIntervalSec=0` (never gives up retrying), and kernel limits
raised up front so the ceiling that was killing ports is pushed way out.

## Architecture

```
  user ──▶  this box (local_port)  ══ socat ══▶  remote_host:remote_port
            rm-socat@<name>-tcp/udp.service
```

Every rule in `ports.conf` becomes one or two `systemd` template-unit
instances (`rm-socat@<name>-tcp`, `rm-socat@<name>-udp`), all sharing a
single template file (`systemd/rm-socat@.service`) whose `ExecStart` calls
`bin/rm-socat-run.sh <instance>` — a tiny helper that looks the rule up in
`ports.conf` and `exec`s the matching `socat` command, so the PID `systemd`
supervises is `socat` itself.

**One socket serves both IPv4 and IPv6** by default (`ip = dual` — plain
`TCP-LISTEN`/`UDP-LISTEN`, no `4`/`6` suffix), instead of running a
separate listener per address family. This needs `net.ipv6.bindv6only=0`,
which `install.sh` sets for you. Set `ip = 4` or `ip = 6` on a rule if you
ever need to force one family.

No logging: every unit runs with `StandardOutput=null` / `StandardError=null`
— nothing hits the journal or disk during normal operation, so there's
nothing there to add I/O load under heavy traffic.

## `ports.conf` format

```
name , local_port , remote_host , remote_port , proto , ip
```

| field         | meaning                                                | values                 |
|---------------|---------------------------------------------------------|------------------------|
| `name`        | unique id → becomes the systemd instance name           | `[A-Za-z0-9_-]+`       |
| `local_port`  | port this box listens on                                 | `1-65535`              |
| `remote_host` | domain or IP this port forwards to                       | any                    |
| `remote_port` | port on `remote_host`                                     | `1-65535`              |
| `proto`       | which socket(s) to open                                   | `tcp` \| `udp` \| `both` |
| `ip`          | address family                                             | `dual` (default) \| `4` \| `6` |

Full format notes and examples live inside [`ports.conf.example`](ports.conf.example).
**`ports.conf` itself is git-ignored** — your real domains/IPs never get
committed to this repo, only the example template does.

## Install

```bash
git clone https://github.com/Ali-Rahmanii/Rm_Socat.git /opt/rm-socat
cd /opt/rm-socat
sudo ./install.sh
```

`install.sh`:
- installs `socat` if missing (apt/dnf/yum/apk)
- installs the `systemd` template unit
- copies `ports.conf.example` → `ports.conf` on first run
- raises kernel/`ulimit` ceilings for high connection counts:
  `net.ipv6.bindv6only=0`, `net.core.somaxconn`, `tcp_max_syn_backlog`,
  `fs.file-max`, and per-process `nofile`/`nproc` limits — plus
  `LimitNOFILE=1048576` / `TasksMax=infinity` on every unit itself.

Then edit `ports.conf` and:

```bash
sudo ./manage.sh apply
```

## Usage

```bash
./manage.sh                 # interactive colored menu
./manage.sh add             # add a rule (prompts, or pass args positionally)
./manage.sh remove <name>   # stop, disable, and drop a rule
./manage.sh apply           # reconcile systemd with the current ports.conf
./manage.sh status          # live table: systemd state + actual socket state per rule
./manage.sh restart         # restart every forward
./manage.sh test            # confirm every configured port is actually LISTENing
./manage.sh stress <port> [tcp|udp] [step] [hold] [max]
                             # ramps concurrent connections until it finds the ceiling
./manage.sh purge           # full uninstall (see below)
```

Adding/removing ports works from the menu, from the CLI (`./manage.sh add
name lport host rport tcp dual`), or by hand — edit `ports.conf` directly
(menu option 8, or any editor) and run `./manage.sh apply` to pick it up.

## Testing

- `./manage.sh test` — health check: is every configured port actually
  `LISTEN`ing right now? Colorized ✅/❌, no files written.
- `./manage.sh stress <port> [tcp|udp] [step] [hold] [max]` — pure-bash
  (`/dev/tcp` / `/dev/udp`, no extra tools) connection ramp that keeps
  opening more concurrent connections in batches until it hits failures,
  and reports the ceiling it found. **This exercises the real remote
  backend through the full forward chain**, not just the local socket —
  the menu warns and asks for confirmation before running it.

## Uninstall

```bash
sudo ./manage.sh purge
# or:
sudo ./uninstall.sh
```

Stops and disables every `rm-socat@*` instance, removes the `systemd`
template unit and the sysctl/limits drop-ins it installed, then asks a
separate, explicit "type YES" confirmation before deleting this entire
directory (`ports.conf` and every script included) — nothing is left
behind.

## License

MIT — see [LICENSE](LICENSE).
