# rm-socat

**مستندات فارسی: [README.fa.md](README.fa.md)**

A small, self-contained TCP/UDP port-forwarder for Linux boxes that relay
traffic to a set of backend servers — built to replace a `crontab @reboot`
+ `screen` + `socat` setup that silently dropped ports under load (once
`socat` died, nothing ever brought it back). Forwards run under `systemd`
with `Restart=always`, so a killed `socat` comes back in ~1 second instead
of staying dead until the next reboot.

## Architecture

```
  user ──▶  this box (local_port)  ══ socat ══▶  remote_host:remote_port
            supervised by rm-socat-batch@<batch_id>.service
```

Every rule in `ports.conf` is hashed by name into one of a fixed number of
**batches** (`batches.conf`, default `10`). Each batch is a single
`systemd` unit (`rm-socat-batch@<id>`) running `bin/rm-socat-batch-run.sh`,
which launches every forward that batch owns as a background `socat`
child and respawns *just that one* if it dies — so dozens of forwards
share a handful of units instead of getting one each.

This exists because the first version *did* give every port its own
`systemd` unit, `Restart=always`. That fixed the original problem (ports
staying closed after a crash) but on a box running 40+ forwards it traded
it for a new one: `systemd` itself (PID 1) burned real CPU just supervising
that many units/cgroups. Batching keeps the "a dead port restarts itself"
guarantee while keeping the unit count small — 10 units instead of 90.

Since batch membership is a hash of the rule's name, adding or removing one
rule never reshuffles anyone else's batch — only *that* rule's batch
restarts (briefly affecting whatever else shares it). Batches won't come
out perfectly even (hashing ~45 names into 10 buckets typically lands
somewhere between 2 and 9 per bucket, not exactly 4 or 5) — if you want
tighter/looser grouping, change the count with `./manage.sh batches`.

**One socket serves both IPv4 and IPv6** by default (`ip = dual` — plain
`TCP-LISTEN`/`UDP-LISTEN`, no `4`/`6` suffix). Needs `net.ipv6.bindv6only=0`,
which `install.sh` sets for you. Use `ip = 4` or `ip = 6` on a rule to force
one family.

No logging: every unit runs with `StandardOutput=null` / `StandardError=null`
— nothing hits the journal or disk during normal operation.

## `ports.conf` format

```
name , local_port , remote_host , remote_port , proto , ip
```

| field         | meaning                          | values                          |
|---------------|-----------------------------------|----------------------------------|
| `name`        | unique id, hashed into a batch    | `[A-Za-z0-9_-]+`                 |
| `local_port`  | port this box listens on          | `1-65535`                        |
| `remote_host` | domain or IP to forward to        | any                               |
| `remote_port` | port on `remote_host`             | `1-65535`                        |
| `proto`       | which socket(s) to open           | `tcp` \| `udp` \| `both`         |
| `ip`          | address family                    | `dual` (default) \| `4` \| `6`   |

See [`ports.conf.example`](ports.conf.example). **`ports.conf` is
git-ignored** — your real domains/IPs never get committed, only the
placeholder example does.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Ali-Rahmanii/Rm_Socat/main/install.sh | sudo bash
```

That clones the repo to `/opt/rm-socat` and runs its own installer. (Already
cloned it yourself? `cd` into it and run `sudo ./install.sh` directly —
same script, safe to re-run either way.) It installs `socat`, installs the
`systemd` template unit, creates `ports.conf`/`batches.conf` on first run,
and raises kernel/`ulimit` ceilings for high connection counts
(`net.ipv6.bindv6only=0`, `somaxconn`, `tcp_max_syn_backlog`, `fs.file-max`,
`nofile`/`nproc`, plus `LimitNOFILE=1048576` on every unit).

Then edit `ports.conf` and:

```bash
sudo /opt/rm-socat/manage.sh apply
```

## Usage

```bash
./manage.sh                 # interactive colored menu
./manage.sh add             # add a rule (prompts, or pass args positionally)
./manage.sh remove <name>   # drop a rule, restart its batch
./manage.sh apply           # reconcile all batches with the current ports.conf
./manage.sh status          # live table: batch state + actual socket state per rule
./manage.sh restart         # restart every batch
./manage.sh test            # confirm every configured port is actually LISTENing
./manage.sh stress <port> [tcp|udp] [step] [hold] [max]
                             # ramps concurrent connections until it finds the ceiling
./manage.sh batches         # change how many systemd units share the load
./manage.sh update          # git pull + reinstall the unit + re-apply
./manage.sh purge           # full uninstall (see below)
```

Adding/removing ports works from the menu, the CLI (`./manage.sh add name
lport host rport tcp dual`), or by hand — edit `ports.conf` (menu option 8)
and run `./manage.sh apply`.

## Updating

```bash
sudo ./manage.sh update
```

Pulls the latest commit, re-chmods the scripts, reinstalls the `systemd`
template (in case it changed), and re-applies `ports.conf` across all
batches. Requires the install to be a git checkout — the one-line
`curl | sudo bash` installer above already sets that up.

## Testing

- `./manage.sh test` — is every configured port actually `LISTEN`ing right
  now? Colorized ✅/❌, no files written.
- `./manage.sh stress <port> [tcp|udp] [step] [hold] [max]` — pure-bash
  (`/dev/tcp`/`/dev/udp`, no extra tools) connection ramp that finds the
  real ceiling. **This exercises the full forward chain up to the real
  remote server**, not just the local socket — confirmation required.

## Uninstall

```bash
sudo ./manage.sh purge      # or: sudo ./uninstall.sh
```

Stops/disables every batch unit, removes the `systemd` template and the
sysctl/limits drop-ins, then asks a separate "type YES" confirmation before
deleting the whole directory — nothing is left behind.

## License

MIT — see [LICENSE](LICENSE).
