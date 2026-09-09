# rm-socat

**مستندات فارسی: [README.fa.md](README.fa.md)**

A small, self-contained TCP/UDP port-forwarder for Linux boxes that relay
traffic to a set of backend servers — built to replace a `crontab @reboot`
+ `screen` + `socat` setup that silently dropped ports under load (once
`socat` died, nothing ever brought it back). Forwards run under `systemd`
with `Restart=always`, grouped into a handful of batches instead of one
unit per port, and managed through a single colored CLI/menu (`rmsocat`)
that can add, remove, test, stress-test, and fully uninstall everything it
creates.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Ali-Rahmanii/Rm_Socat/main/install.sh | sudo bash
```

That clones the repo to `/opt/rm-socat`, runs its own installer, installs
a global `rmsocat` command, and drops you straight into the interactive
menu. (Already cloned it yourself? `cd` into it and run `sudo
./install.sh` directly — same script, safe to re-run either way.) It
installs `socat`, installs the `systemd` template unit, creates
`ports.conf`/`batches.conf` on first run, and raises kernel/`ulimit`
ceilings for high connection counts (`net.ipv6.bindv6only=0`, `somaxconn`,
`tcp_max_syn_backlog`, `fs.file-max`, `nofile`/`nproc`, plus
`LimitNOFILE=1048576` on every unit).

From then on, just run `rmsocat` from anywhere (any terminal, any
directory) to reopen the menu — it's a tiny wrapper the installer puts at
`/usr/local/bin/rmsocat`. Every time it opens, it does a 2-second,
non-blocking check against GitHub and prints a notice if a newer version
is out. Edit `ports.conf` and:

```bash
sudo rmsocat apply
```

## Architecture

```
  user ──▶  this box (local_port)  ══ socat ══▶  remote_host:remote_port
            supervised by rm-socat-batch@<batch_id>.service
```

Every rule in `ports.conf` is hashed by name into one of a fixed number of
**batches** (`batches.conf`, default `10`). Each batch is a single
`systemd` unit (`rm-socat-batch@<id>`) running `bin/rm-socat-batch-run.sh`,
which launches every forward that batch owns as a background `socat`
child, throttled to at most one respawn per second per child, and
respawns *just that one* if it dies — so dozens of forwards share a
handful of units instead of getting one each.

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
tighter/looser grouping, change the count with `rmsocat batches`.

**One socket serves both IPv4 and IPv6** by default (`ip = dual`). For TCP
that's a plain `TCP-LISTEN` with no `4`/`6` suffix; for UDP it's explicitly
`UDP6-LISTEN` — some socat builds crash on a family-unspecified
`UDP-LISTEN` (`unknown address family 0`), so UDP always states its family,
relying on `net.ipv6.bindv6only=0` (which `install.sh` sets) to still
accept IPv4 clients. Use `ip = 4` or `ip = 6` on a rule to force one family
on both protocols.

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

See [`ports.conf.example`](ports.conf.example). **`ports.conf` and
`batches.conf` are git-ignored** — your real domains/IPs (and your chosen
batch count) never get committed or fought over by `git pull`, only the
placeholder example does.

Only forwards that actually need UDP should set `proto=both` — an SSH
tunnel or a TCP/WS-based V2ray config doesn't, and every unnecessary UDP
socket is one more thing that can fail for no reason.

## Usage

```bash
rmsocat                     # interactive colored menu
rmsocat add                 # add a rule (prompts, or pass args positionally)
rmsocat remove <name>       # drop a rule, restart its batch
rmsocat apply               # reconcile all batches with the current ports.conf
rmsocat status              # live table: batch state + actual socket state per rule
rmsocat restart             # restart every batch
rmsocat test                # confirm every configured port is actually LISTENing
rmsocat stress <port> [tcp|udp] [step] [settle] [max] [hold] [host]
                             # holds connections open concurrently until it finds the ceiling
rmsocat batches              # change how many systemd units share the load
rmsocat update               # git pull (auto-stashing local drift) + re-apply
rmsocat purge                 # full uninstall (see below)
```

Adding/removing ports works from the menu, the CLI (`rmsocat add name
lport host rport tcp dual`), or by hand — edit `ports.conf` (menu option 8)
and run `rmsocat apply`.

## Updating

```bash
sudo rmsocat update
```

Stashes any local drift, pulls the latest commit (fast-forward only),
restores that drift, re-chmods the scripts, reinstalls the `systemd`
template (in case it changed), and re-applies `ports.conf` across all
batches. Requires the install to be a git checkout — the one-line
`curl | sudo bash` installer above already sets that up.

## Testing

- `rmsocat test` — is every configured port actually `LISTEN`ing right
  now? Colorized ✅/❌, no files written.
- `rmsocat stress <port> [tcp|udp] [step] [settle] [max] [hold] [host]` —
  pure-bash (`/dev/tcp`/`/dev/udp`, no extra tools), holds every opened
  connection open *concurrently* (not stagger-and-close) while ramping up
  in steps of `step` every `settle` seconds, up to `max` attempts, so the
  reported count is real concurrency, not cumulative attempts. Raises its
  own `ulimit -n`/`-u` first — your login shell's default is usually the
  actual bottleneck, not the port. **This exercises the full forward chain
  up to the real remote server**, not just the local socket —
  confirmation required.

## Uninstall

```bash
sudo rmsocat purge      # or: sudo ./uninstall.sh
```

Stops/disables every batch unit (falling back to removing unit
files/enablement symlinks directly if `disable` fails, plus
`systemctl reset-failed` and a `pkill -x socat` as a last resort), removes
the `systemd` template, the sysctl/limits drop-ins, and the `rmsocat`
command, then asks a separate "type YES" confirmation before deleting the
whole directory — nothing is left behind.

## License

MIT — see [LICENSE](LICENSE).
