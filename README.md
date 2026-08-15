# omarchy-sysstats

CPU, memory and storage for the [Omarchy](https://omarchy.org/) shell bar — two
quiet meters on the bar, the detail in a panel.

![The sysstats panel](preview.png)

Omarchy 4 ships no first-party system-stats widget. `omarchy.monitor` is
brightness and display controls, despite the name, so this fills the gap the
old Waybar `cpu` and `memory` modules used to.

## On the bar

Two level meters — CPU on the left, memory on the right — and no text. Numbers
on a 26px bar end up competing with the clock and rarely match the size of
anything around them, so the figures live in the panel instead. Hover for a
one-line summary.

The fill uses a gamma curve rather than a linear one. Idle machines sit in the
bottom fifth of the scale, where a 13px track cannot separate 10% from 25% —
both land on the same couple of pixels. The curve spends more of the track on
the range the values actually occupy while still topping out at 100%. It is a
glanceable indicator, not a linear readout; the panel carries exact numbers.

## In the panel

- Current load, CPU model, and a rolling average-CPU graph of the last 48 samples
- Per-core activity, with load average on the same line
- Memory: used, free and swap
- Storage: usage for a chosen mount, plus live read/write throughput
- A button through to `btop`

The core grid wraps past eight and balances rather than filling rows, so 12
cores go 6+6 rather than 8+4 and 24 go 8+8+8; blocks shorten once it wraps so a
large machine does not push the panel off screen.

On hybrid Intel chips the cores are labelled `P0`/`E4` instead of by bare index,
read from `/sys/devices/cpu_core/cpus` and `/sys/devices/cpu_atom/cpus` — the
separate-PMU interface Alder Lake and later expose. Uniform CPUs and AMD have
neither path and keep plain numbering.

Click the bar widget to open it. It registers as a normal bar panel, so
`SUPER + CTRL + <n>` opens it by position and Tab moves between it and the
neighbouring panels.

Meters, graph, cores and both usage bars tint together: base foreground below
`warnAt`, ramping to the theme's urgent colour by `criticalAt`. A ramp rather
than discrete steps, so a value resting on a threshold does not strobe.

## Install

```bash
omarchy plugin add https://github.com/RohitKaushal7/omarchy-sysstats.git --enable
```

Then place it wherever you like on the bar:

```bash
omarchy bar move dev.reuk.sysstats --section right --before omarchy.power
```

Plugins run as unsandboxed code inside `omarchy-shell`. Read `Panel.qml` before
enabling it — it is a single file and deliberately short on cleverness.

## Settings

Set on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "dev.reuk.sysstats", "mount": "/home", "interval": 2, "warnAt": 60, "criticalAt": 85 }
```

| Key | Default | Meaning |
|-----|---------|---------|
| `interval` | `2` | Seconds between samples |
| `mount` | `"/"` | Mount point reported in the storage column |
| `warnAt` | `60` | Percent at which meters start tinting |
| `criticalAt` | `85` | Percent at which meters reach the urgent colour |

## What it reads, and what it does not

No privileges, no network, no services, no installers, no build step. Nothing is
written anywhere.

Every few seconds it runs one short-lived `sh` that reads `/proc/stat`,
`/proc/meminfo`, `/proc/loadavg`, `/proc/cpuinfo`, `/proc/diskstats`, and `df`
for the configured mount. Only `coreutils`, `awk` and `grep` are used, all of
which are part of a base Arch install. `btop` is needed only if you press the
button.

`/proc` is read through a subprocess rather than a `FileView` because procfs
reports `st_size` 0, which size-based readers mishandle. CPU and I/O deltas are
computed in QML, so no sampling sleep is needed. Throughput divides by the delta
of `/proc/uptime` rather than by the timer interval, so a late or coalesced tick
reports the rate over the time that actually elapsed. Disk throughput sums whole
block devices only (`nvme*`, `sd*`, `mmcblk*`, `vd*`), so partition counters are
not added on top of the disk they belong to.

Memory and storage are reported in GiB, labelled GB — the same convention
`free -h` and `btop` use. A 32 GB machine reads about 30.8.

## License

MIT — see [LICENSE](LICENSE).
