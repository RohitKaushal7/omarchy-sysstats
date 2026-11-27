// CPU + memory widget with a detail panel.
//
// Replaces the `cpu` and `memory` modules from the Omarchy 3 waybar config;
// Omarchy 4 ships no first-party system-stats widget (omarchy.monitor is
// brightness and display controls, despite the name).
//
// Built on Ui/Panel rather than as a bar/modules/*.qml custom module: only a
// real plugin can use the shared panel chrome, and only a widget exposing
// open()/close()/opened joins the bar's panel navigation, which is what makes
// SUPER + CTRL + <n> and Tab-between-panels work here the way they do for
// audio, network and power.
//
// On the bar it is two level meters and no text. Numbers there competed with
// the clock and never matched anything else's size; the panel is where the
// figures belong.
//
// /proc is read through a short-lived `sh` rather than a FileView: procfs
// reports st_size 0, which size-based readers mishandle. CPU deltas are kept
// here in QML so no sampling sleep is needed.
//
// GPUs, NPUs and the CPU's temperature sensors are read by a second `sh`
// of their own (deviceProbe), with the `read` builtin so it starts nothing
// further. These are driver reads rather than kernel bookkeeping, and one
// that stalls must not hold back the CPU and memory figures. GPU load is
// the share of the tick the GT spent out of RC6 (xe gtidle, i915
// rc6_residency) — "awake", which tracks real load closely without the
// CAP_PERFMON the engine PMU needs or the /proc/*/fdinfo walk per-client
// accounting costs. amdgpu reports gpu_busy_percent directly.
// A runtime-suspended device is never read: on a dGPU that read would wake
// it out of D3 and cost more power than the widget is worth.

import QtQuick
import QtQuick.Shapes
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "dev.reuk.sysstats"
  ipcTarget: "dev.reuk.sysstats"

  readonly property int refreshMs: Math.max(1, setting("interval", 2)) * 1000
  readonly property real warnAt: Math.max(0, Math.min(1, setting("warnAt", 60) / 100))
  readonly property real criticalAt: Math.max(0.01, Math.min(1, setting("criticalAt", 85) / 100))

  // Bar alert limits, in percent. A mark shows while a device's work (see
  // accelWork) is above its limit, and nothing else. NPU defaults to 0:
  // any NPU work at all is worth a mark.
  readonly property real gpuAlertAt: Math.max(0, Math.min(100, setting("gpuAlertAt", 50)))
  readonly property real npuAlertAt: Math.max(0, Math.min(100, setting("npuAlertAt", 0)))
  // Over the limit as last read; the marks themselves also need that
  // reading to be fresh.
  property bool gpuOver: false
  property bool npuOver: false
  readonly property bool gpuAlert: gpuOver && !deviceStale
  readonly property bool npuAlert: npuOver && !deviceStale

  // Expiry. Each process's figures count as fresh while it keeps bringing
  // samples; once staleTicks ticks pass without one (a read stuck in a
  // driver, say), they are shown as not responding: an em dash in the
  // panel, empty meters and no GPU or NPU marks on the bar, rather than the
  // last numbers frozen in place. Counted in ticks, not wall time, so a
  // resume from suspend does not read as a stall.
  readonly property int staleTicks: 3
  property int coreAge: 0
  property int deviceAge: 0
  readonly property bool coreStale: coreAge >= staleTicks
  readonly property bool deviceStale: deviceAge >= staleTicks
  // Bumped as a group goes stale. A sample started before then is thrown
  // away when it finally returns: what it read may be minutes old, and it
  // would make a bogus delta against the next. The first sample after it
  // only sets the base the next one is diffed against.
  property int coreEpoch: 0
  property int coreRunEpoch: 0
  property int deviceEpoch: 0
  property int deviceRunEpoch: 0
  readonly property int historyLength: 48

  readonly property color ink: bar ? bar.foreground : Color.foreground

  // Bar meter geometry.
  readonly property real meterWidth: 5
  readonly property real meterHeight: 13
  readonly property real meterGap: 5

  // Aggregate CPU.
  property real prevBusy: -1
  property real prevTotal: -1
  property real cpuLoad: 0
  property var cpuHistory: []

  // Per-core CPU: previous samples keyed by /proc/stat label, plus current
  // load in list order. coreIds holds the real CPU number for each entry:
  // /proc/stat lists online CPUs only, so with nosmt or a CPU taken offline
  // the position in the list is not the CPU's number.
  property var prevCoreBusy: ({})
  property var prevCoreTotal: ({})
  property var coreLoads: []
  property var coreIds: []

  // Hybrid Intel exposes its two core classes as separate PMUs under
  // /sys/devices/cpu_core and /sys/devices/cpu_atom (Alder Lake and later).
  // Absent on uniform CPUs and on AMD, where every core is just numbered.
  property var pCoreSet: ({})
  property var eCoreSet: ({})
  // Raw sysfs strings, kept so the sets are only rebuilt when they actually
  // change. Assigning a var property always emits its change signal, even
  // for an identical object, which would re-evaluate every core label on
  // every tick for data that never moves.
  property string pCoreSpec: ""
  property string eCoreSpec: ""
  readonly property bool hybridCpu: Object.keys(pCoreSet).length > 0 && Object.keys(eCoreSet).length > 0

  // Wrap past eight, then balance: 12 cores go 6+6 rather than 8+4, and 24
  // go 8+8+8. Keeps the last row from looking like a stub.
  readonly property int coreRows: Math.max(1, Math.ceil(coreLoads.length / 8))
  readonly property int coreColumns: coreLoads.length > 0
    ? Math.ceil(coreLoads.length / coreRows)
    : 1

  // Takes the CPU's real number (the N in cpuN), not its grid position.
  function coreLabel(cpu) {
    if (cpu === undefined) return ""
    if (root.pCoreSet[cpu]) return "P" + cpu
    if (root.eCoreSet[cpu]) return "E" + cpu
    return String(cpu)
  }

  // "0-3", "0-3,8-11" or "2" -> a set of cpu indices.
  function parseCpuList(spec) {
    var out = {}
    var text = String(spec || "").replace(/^\s+|\s+$/g, "")
    if (text === "") return out

    var parts = text.split(",")
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i]
      var dash = part.indexOf("-")
      if (dash > 0) {
        var lo = parseInt(part.substr(0, dash), 10)
        var hi = parseInt(part.substr(dash + 1), 10)
        if (isFinite(lo) && isFinite(hi)) for (var n = lo; n <= hi; n++) out[n] = true
      } else {
        var single = parseInt(part, 10)
        if (isFinite(single)) out[single] = true
      }
    }
    return out
  }

  // Memory.
  property real memFraction: 0
  property real memUsedGb: 0
  property real memTotalGb: 0
  property real memAvailableGb: 0
  // Reclaimable: page cache and the like the kernel will hand back on
  // demand. MemAvailable minus MemFree, so apps + cache + free = total.
  property real memCacheGb: 0
  property real memCacheFraction: 0
  property real swapUsedGb: 0
  property real swapTotalGb: 0

  property string loadAverage: ""
  property string cpuModel: ""

  // CPU package temperature, and the share of the last throttleWindow
  // seconds the package spent slowed for heat. The share, not the
  // temperature, is what says whether heat is costing speed: a hot chip
  // that is not throttling is working as designed. It is shown only past
  // throttleFloor so a lone sub-second burst does not flash the label.
  property real cpuTempC: -1
  readonly property real throttleWindow: 30
  readonly property real throttleFloor: 0.01
  property var throttleSamples: []
  property real throttleShare: 0
  readonly property string cpuTempText: cpuTempC >= 0 && !deviceStale ? Math.round(cpuTempC) + "°C" : ""
  readonly property string throttleText: throttleShare >= throttleFloor && !deviceStale
    ? "· throttled " + Math.round(throttleShare * 100) + "%" : ""

  // Storage. Usage is for one mount (configurable); throughput is summed
  // across whole block devices, ignoring partitions so their I/O is not
  // counted twice alongside the disk they sit on.
  readonly property string diskMount: setting("mount", "/")
  // Only an absolute path is a mount. Anything else is shown as unavailable
  // and never reaches df or the disk-usage tools, where "-o…" would be read
  // as an option.
  readonly property bool diskMountValid: root.diskMount.charAt(0) === "/"
  property real diskTotalGb: 0
  property real diskUsedGb: 0
  // What df says is free, not total minus used: btrfs and ext4 both keep
  // space back that neither column counts, so the difference overstates it.
  property real diskFreeGb: 0
  property real diskFraction: 0
  // "ok" once df has answered for diskMount; "unavailable" when it failed
  // (no such path, no permission), "stalled" when it timed out or is still
  // stuck, as a hung network mount can be. "" until the first answer.
  // The figures above are zero whenever this is not "ok".
  property string diskStatus: ""
  readonly property bool diskKnown: diskStatus === "ok"
  readonly property string diskNote: diskStatus === "stalled" ? "not responding"
    : diskStatus === "unavailable" ? "unavailable" : ""
  // Probes in flight, each its own process tagged with its mount (see
  // diskProbeComponent). A df stuck in uninterruptible I/O cannot be ended,
  // not even by timeout's KILL, so it must not stand in the way of the next
  // mount: choosing another starts a probe for it at once. Only one is in
  // flight per mount, so a mount that stays stuck reads "stalled" rather
  // than gathering a new df every tick, and only diskProbeCap at all, so
  // flipping between hung mounts cannot pile processes up.
  property var diskProbes: []
  readonly property int diskProbeCap: 4
  // When diskMount was last chosen.
  property real diskMountSince: 0
  // Low disk: a mark on the bar while free space is under the smaller of
  // 10 GB and 5% of the disk, so a big drive is not flagged with plenty
  // left and a small one still is. Once on, it holds until free space is
  // a tenth over the floor, so a disk hovering on the line does not blink.
  readonly property real diskFloorGb: 10
  readonly property real diskFloorShare: 0.05
  readonly property real diskFloorHold: 1.1
  readonly property real diskFloor: Math.min(diskFloorGb, diskTotalGb * diskFloorShare)
  property bool diskLow: false
  // Past this a probe is reported stuck even if timeout has not ended it:
  // df's own two seconds, plus the second timeout gives a SIGKILL.
  readonly property int diskStallMs: 3500
  property real prevUptime: -1
  property real prevSectorsRead: -1
  property real prevSectorsWritten: -1
  property real readBytesPerSec: 0
  property real writeBytesPerSec: 0

  readonly property string cpuPercentText: coreStale ? "—" : Math.round(cpuLoad * 100) + "%"
  // CPU and memory as far as colour and fill go: nothing while stale.
  readonly property real cpuShown: coreStale ? 0 : cpuLoad
  readonly property real memShown: coreStale ? 0 : memFraction

  // Accelerators, keyed by sysfs node (card0, accel0). accelIds only
  // changes when a device appears or goes, so the Repeaters keep their
  // delegates — and their animations — across ticks; per-tick figures live
  // in accelState and reach the delegates through bindings.
  property var accelIds: []
  property var accelState: ({})
  property var accelHistory: ({})
  property var accelNames: ({})
  property var prevAccel: ({})
  // deviceProbe's own clock, for its deltas: it runs apart from the sampler.
  property real prevDeviceUptime: -1

  // Trace and gauge colours come from the theme's ANSI cyan/magenta/blue so
  // they follow theme switches; these are the fallbacks for themes without.
  property color gpuTint: "#5dcaa5"
  property color gpuAltTint: "#85b7eb"
  property color npuTint: "#afa9ec"

  function accelKind(id) { return String(id).indexOf("accel") === 0 ? "npu" : "gpu" }

  function accelLabel(id) {
    var kind = root.accelKind(id)
    var same = root.accelIds.filter(function(other) { return root.accelKind(other) === kind })
    var label = kind.toUpperCase()
    return same.length > 1 ? label + String(id).replace(/^\D+/, "") : label
  }

  function accelTint(id) {
    if (root.accelKind(id) === "npu") return root.npuTint
    var gpus = root.accelIds.filter(function(other) { return root.accelKind(other) === "gpu" })
    return gpus.indexOf(id) > 0 ? root.gpuAltTint : root.gpuTint
  }

  function accelPercentText(id) {
    var s = root.accelState[id]
    if (!s || root.deviceStale || s.asleep || s.busy < 0) return "—"
    return Math.round(s.busy * 100) + "%"
  }

  // Two label/value pairs for a device's cell beside its gauge.
  function accelFacts(id) {
    var s = root.accelState[id]
    if (!s) return []
    if (root.deviceStale) return s.kind === "npu"
      ? [["CLOCK", "—"], ["MEM", "—"]]
      : [["MEDIA", "—"], ["CLOCK", "—"]]
    var clock = s.clockMhz > 0 ? Math.round(s.clockMhz) + " MHz" : "—"
    if (s.kind === "npu") {
      return [
        s.asleep ? ["STATE", "asleep"] : ["CLOCK", clock],
        ["MEM", s.memBytes >= 0 ? root.bytesText(s.memBytes) : "—"]
      ]
    }
    if (s.asleep) return [["STATE", "asleep"], ["CLOCK", "—"]]
    return [
      ["MEDIA", s.media >= 0 ? Math.round(s.media * 100) + "%" : "—"],
      ["CLOCK", clock]
    ]
  }

  function bytesText(bytes) {
    var b = Math.max(0, bytes)
    if (b < 1048576) return Math.round(b / 1024) + " KB"
    if (b < 1073741824) return Math.round(b / 1048576) + " MB"
    return (b / 1073741824).toFixed(1) + " GB"
  }

  // Share of the elapsed tick a monotonic counter advanced by, or -1 when
  // there is no earlier sample to diff against (first tick, a device that
  // just woke, a counter that reset).
  function counterShare(prev, next, key, value, unitsPerSecond, elapsed) {
    next[key] = value
    var before = prev[key]
    if (before === undefined || !(elapsed > 0) || !(value >= before)) return -1
    return Math.max(0, Math.min(1, (value - before) / (elapsed * unitsPerSecond)))
  }

  function updateAccelerators(records, elapsed) {
    var prev = root.prevAccel
    var next = {}
    var state = {}
    var ids = []

    for (var i = 0; i < records.length; i++) {
      var r = records[i]
      var id = r[1]
      var s = state[id]
      if (!s) {
        s = state[id] = { kind: r[0], stale: root.deviceStale, asleep: false, busy: -1, media: -1, clock: -1, clockMhz: 0, memBytes: -1 }
        ids.push(id)
      }

      if (r[0] === "npu") {
        // npu <id> <runtime_status> <busy_us> <cur_mhz> <max_mhz> <mem_bytes>
        s.asleep = r[2] === "suspended"
        s.busy = root.counterShare(prev, next, id, parseFloat(r[3]), 1e6, elapsed)
        s.clockMhz = parseFloat(r[4]) || 0
        var npuMax = parseFloat(r[5]) || 0
        s.clock = npuMax > 0 ? Math.min(1, s.clockMhz / npuMax) : -1
        var mem = parseFloat(r[6])
        s.memBytes = isNaN(mem) ? -1 : mem
      } else if (r[2] === "suspended") {
        // Nothing read, so nothing carried into `next`: the counters are
        // diffed afresh once the device wakes rather than across the nap.
        s.asleep = true
      } else if (r[2] === "idle") {
        // gpu <id> idle <gt-name> <idle_ms> <cur_mhz> <max_mhz>
        var idle = root.counterShare(prev, next, id + "/" + r[3], parseFloat(r[4]), 1000, elapsed)
        var awake = idle < 0 ? -1 : 1 - idle
        // xe splits Lunar Lake and later into a render GT (gt0-rc) and a
        // media GT (gt1-mc); i915 reports one render GT.
        if (/-mc$/.test(r[3])) {
          s.media = awake
        } else {
          s.busy = awake
          s.clockMhz = parseFloat(r[5]) || 0
          var gpuMax = parseFloat(r[6]) || 0
          s.clock = gpuMax > 0 ? Math.min(1, s.clockMhz / gpuMax) : -1
        }
      } else if (r[2] === "busy") {
        // gpu <id> busy <percent>
        s.busy = Math.max(0, Math.min(1, (parseFloat(r[3]) || 0) / 100))
      }
    }

    var history = {}
    for (var j = 0; j < ids.length; j++) {
      var key = ids[j]
      var st = state[key]
      if (st.asleep && st.busy < 0) st.busy = 0
      var past = root.accelHistory[key] || []
      if (st.busy >= 0) {
        past = past.slice(Math.max(0, past.length - root.historyLength + 1))
        past.push(st.busy)
      }
      history[key] = past
    }

    root.prevAccel = next
    root.accelState = state
    root.accelHistory = history
    if (ids.join(" ") !== root.accelIds.join(" ")) root.accelIds = ids

    root.gpuOver = root.overLimit(ids, state, "gpu", root.gpuAlertAt)
    root.npuOver = root.overLimit(ids, state, "npu", root.npuAlertAt)
  }

  // True while any device of `kind` works above `limit` percent.
  function overLimit(ids, state, kind, limit) {
    for (var i = 0; i < ids.length; i++) {
      var s = state[ids[i]]
      if (s.kind === kind && root.accelWork(s) > limit) return true
    }
    return false
  }

  // Work: share of a device's peak capacity in use, in percent — the
  // awake share scaled by clock against its maximum. Awake alone cannot
  // tell many tiny jobs at the floor clock (desktop compositing) from real
  // work, which is what makes the firmware raise the clock. Devices that
  // report no clock (amdgpu's busy percent, the NPU when idle) count as
  // plain busy; -1 when there is nothing to judge.
  function accelWork(s) {
    if (!s || s.asleep || !(s.busy >= 0)) return -1
    return s.busy * (s.clock >= 0 ? s.clock : 1) * 100
  }

  // `lspci -mm` line -> short device name: "Arc 130V/140V" rather
  // than "Core Ultra 200V Series Processors Arc Graphics 130V/140V GPU".
  function parseNames(text) {
    var names = {}
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var id = lines[i].split(/\s+/)[0]
      var quoted = lines[i].match(/"[^"]*"/g)
      if (!id || !quoted || quoted.length < 3) continue

      var vendor = quoted[1].replace(/"/g, "")
      var name = quoted[2].replace(/"/g, "")
      var bracket = name.match(/\[([^\]]+)\]/)
      if (bracket) name = bracket[1]
      name = name.replace(/^.*\bProcessors?\s+/, "").replace(/\s+(GPU|Graphics Controller)$/, "")
      // "Arc 130V/140V", "Radeon 780M": the brand already says graphics.
      name = name.replace(/^(Arc|Radeon|Iris Xe|UHD)\s+Graphics\b/, "$1")

      var kind = root.accelKind(id).toUpperCase()
      if (name === "" || name.toUpperCase() === kind) {
        var vendorShort = /^Advanced Micro/.test(vendor) ? "AMD" : vendor.split(/\s+/)[0]
        name = vendorShort + " " + kind
      }
      names[id] = name
    }
    root.accelNames = names
  }

  function loadPalette(raw) {
    var keys = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match) keys[match[1]] = match[2]
    }
    root.gpuTint = keys.cyan || keys.color6 || "#5dcaa5"
    root.npuTint = keys.magenta || keys.color5 || "#afa9ec"
    root.gpuAltTint = keys.blue || keys.color4 || "#85b7eb"
  }

  // Low load stays at the base foreground; past warnAt it ramps toward the
  // theme's urgent colour, reaching it at criticalAt. A ramp rather than
  // discrete steps so a meter hovering on a threshold does not strobe.
  function loadColor(fraction) {
    if (fraction <= root.warnAt) return root.ink
    var span = Math.max(0.0001, root.criticalAt - root.warnAt)
    var t = Math.max(0, Math.min(1, (fraction - root.warnAt) / span))
    var urgent = bar ? bar.urgent : Color.urgent
    return Qt.rgba(
      root.ink.r + (urgent.r - root.ink.r) * t,
      root.ink.g + (urgent.g - root.ink.g) * t,
      root.ink.b + (urgent.b - root.ink.b) * t,
      1)
  }

  function gb(kb) { return kb / 1048576 }
  function bytesToGb(bytes) { return bytes / 1073741824 }

  function rateText(bytesPerSec) {
    var b = Math.max(0, bytesPerSec)
    if (b < 1024) return Math.round(b) + " B/s"
    if (b < 1048576) return Math.round(b / 1024) + " KB/s"
    if (b < 1073741824) return (b / 1048576).toFixed(1) + " MB/s"
    return (b / 1073741824).toFixed(2) + " GB/s"
  }

  function pushHistory(value) {
    var next = root.cpuHistory.slice(Math.max(0, root.cpuHistory.length - root.historyLength + 1))
    next.push(value)
    root.cpuHistory = next
  }

  // One /proc/stat cpu line -> {busy, total}. Fields after the label are
  // user nice system idle iowait irq softirq steal ...; idle and iowait are
  // the two that do not count as work.
  function cpuTimes(fields) {
    var total = 0
    for (var i = 1; i < fields.length; i++) {
      var n = parseFloat(fields[i])
      if (!isNaN(n)) total += n
    }
    var idle = (parseFloat(fields[4]) || 0) + (parseFloat(fields[5]) || 0)
    return { busy: total - idle, total: total }
  }

  // Keeps one sample at or before the window's start, so the share covers
  // the whole window rather than only the samples that fall inside it.
  function updateThrottle(uptime, throttleMs) {
    var samples = root.throttleSamples.slice()
    // A smaller counter or clock means a resume or reload; start over.
    var last = samples.length > 0 ? samples[samples.length - 1] : null
    if (last && (uptime <= last.t || throttleMs < last.ms)) samples = []
    samples.push({ t: uptime, ms: throttleMs })
    while (samples.length > 2 && samples[1].t <= uptime - root.throttleWindow) samples.shift()
    root.throttleSamples = samples

    var first = samples[0]
    var span = uptime - first.t
    root.throttleShare = span > 0
      ? Math.max(0, Math.min(1, (throttleMs - first.ms) / (span * 1000)))
      : 0
  }

  function parse(text) {
    if (root.coreRunEpoch !== root.coreEpoch) return
    var lines = String(text).split("\n")
    var cpuFresh = false
    var memFresh = false
    var memTotalKb = -1
    var memAvailableKb = -1
    var memFreeKb = -1
    var swapTotalKb = -1
    var swapFreeKb = -1

    var nextCoreBusy = {}
    var nextCoreTotal = {}
    var cores = []
    var ids = []

    var nextUptime = -1
    var nextSectorsRead = -1
    var nextSectorsWritten = -1

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]

      if (line.indexOf("cpu") === 0) {
        var fields = line.split(/\s+/)
        var label = fields[0]
        var times = cpuTimes(fields)

        if (label === "cpu") {
          if (root.prevTotal >= 0 && times.total > root.prevTotal) {
            var load = (times.busy - root.prevBusy) / (times.total - root.prevTotal)
            root.cpuLoad = Math.max(0, Math.min(1, load))
            root.pushHistory(root.cpuLoad)
            cpuFresh = true
          }
          root.prevBusy = times.busy
          root.prevTotal = times.total
        } else {
          var prevBusy = root.prevCoreBusy[label]
          var prevTotal = root.prevCoreTotal[label]
          var coreLoad = 0
          if (prevTotal !== undefined && times.total > prevTotal) {
            coreLoad = Math.max(0, Math.min(1, (times.busy - prevBusy) / (times.total - prevTotal)))
          }
          cores.push(coreLoad)
          ids.push(parseInt(label.substr(3), 10))
          nextCoreBusy[label] = times.busy
          nextCoreTotal[label] = times.total
        }
      } else if (line.indexOf("MemTotal:") === 0) {
        memTotalKb = parseFloat(line.replace(/[^0-9]/g, ""))
      } else if (line.indexOf("MemFree:") === 0) {
        memFreeKb = parseFloat(line.replace(/[^0-9]/g, ""))
      } else if (line.indexOf("MemAvailable:") === 0) {
        memAvailableKb = parseFloat(line.replace(/[^0-9]/g, ""))
      } else if (line.indexOf("SwapTotal:") === 0) {
        swapTotalKb = parseFloat(line.replace(/[^0-9]/g, ""))
      } else if (line.indexOf("SwapFree:") === 0) {
        swapFreeKb = parseFloat(line.replace(/[^0-9]/g, ""))
      } else if (line.indexOf("loadavg ") === 0) {
        var la = line.split(/\s+/)
        root.loadAverage = la.length > 3 ? la[1] + "  " + la[2] + "  " + la[3] : ""
      } else if (line.indexOf("model ") === 0) {
        root.cpuModel = line.substr(6).replace(/^\s+|\s+$/g, "")
      } else if (line.indexOf("dio ") === 0) {
        var io = line.split(/\s+/)
        nextSectorsRead = parseFloat(io[1])
        nextSectorsWritten = parseFloat(io[2])
      } else if (line.indexOf("uptime ") === 0) {
        nextUptime = parseFloat(line.split(/\s+/)[1])
      } else if (line.indexOf("pcores ") === 0) {
        var pspec = line.substr(7)
        if (pspec !== root.pCoreSpec) {
          root.pCoreSpec = pspec
          root.pCoreSet = root.parseCpuList(pspec)
        }
      } else if (line.indexOf("ecores ") === 0) {
        var espec = line.substr(7)
        if (espec !== root.eCoreSpec) {
          root.eCoreSpec = espec
          root.eCoreSet = root.parseCpuList(espec)
        }
      }
    }

    root.prevCoreBusy = nextCoreBusy
    root.prevCoreTotal = nextCoreTotal
    // Only publish once there is a previous sample to diff against, so the
    // grid does not flash a row of zeroes on the first tick or after a stall.
    if (cores.length > 0 && cpuFresh) {
      // Only when a CPU goes or comes back, as with accelIds: every
      // assignment would re-evaluate each label.
      if (ids.join(" ") !== root.coreIds.join(" ")) root.coreIds = ids
      root.coreLoads = cores
    }

    if (memTotalKb > 0 && memAvailableKb >= 0) {
      root.memTotalGb = gb(memTotalKb)
      root.memAvailableGb = gb(memAvailableKb)
      if (memFreeKb >= 0) {
        var cacheKb = Math.max(0, memAvailableKb - memFreeKb)
        root.memCacheGb = gb(cacheKb)
        root.memCacheFraction = Math.max(0, Math.min(1, cacheKb / memTotalKb))
      }
      root.memUsedGb = gb(memTotalKb - memAvailableKb)
      root.memFraction = Math.max(0, Math.min(1, (memTotalKb - memAvailableKb) / memTotalKb))
      memFresh = true
    }
    if (swapTotalKb >= 0 && swapFreeKb >= 0) {
      root.swapTotalGb = gb(swapTotalKb)
      root.swapUsedGb = gb(swapTotalKb - swapFreeKb)
    }

    // Throughput comes from /proc/uptime rather than the timer interval, so
    // a late or coalesced tick reports the rate over the time that actually
    // elapsed instead of the time that was scheduled.
    if (nextUptime >= 0 && nextSectorsRead >= 0 && nextSectorsWritten >= 0) {
      var elapsed = nextUptime - root.prevUptime
      if (root.prevUptime >= 0 && elapsed > 0) {
        // diskstats counts 512-byte sectors regardless of hardware sector size.
        root.readBytesPerSec = Math.max(0, (nextSectorsRead - root.prevSectorsRead) * 512 / elapsed)
        root.writeBytesPerSec = Math.max(0, (nextSectorsWritten - root.prevSectorsWritten) * 512 / elapsed)
      }
      root.prevUptime = nextUptime
      root.prevSectorsRead = nextSectorsRead
      root.prevSectorsWritten = nextSectorsWritten
    }

    if (cpuFresh && memFresh) root.coreAge = 0
  }

  // deviceProbe output: "uptime", then gpu/npu records and the CPU sensors.
  function parseDevices(text) {
    if (root.deviceRunEpoch !== root.deviceEpoch) return
    var lines = String(text).split("\n")
    var complete = false
    var uptime = -1
    var records = []
    var throttleMs = -1
    var tempC = -1

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("gpu ") === 0 || line.indexOf("npu ") === 0) {
        records.push(line.split(/\s+/))
      } else if (line.indexOf("uptime ") === 0) {
        uptime = parseFloat(line.substr(7))
      } else if (line.indexOf("ctemp ") === 0) {
        var milli = parseFloat(line.substr(6))
        if (!isNaN(milli)) tempC = milli / 1000
      } else if (line.indexOf("throttle ") === 0) {
        throttleMs = parseFloat(line.substr(9))
      } else if (line === "end") {
        complete = true
      }
    }

    if (tempC >= 0) root.cpuTempC = tempC
    if (uptime >= 0 && throttleMs >= 0) root.updateThrottle(uptime, throttleMs)
    var elapsed = uptime >= 0 && root.prevDeviceUptime >= 0 ? uptime - root.prevDeviceUptime : -1
    // A gap this long (a resume from suspend) is diffed afresh rather than
    // averaged over: the counters do not all run while the machine sleeps.
    if (elapsed > root.staleTicks * root.refreshMs / 1000) elapsed = -1
    // Before the update, which stamps each device with deviceStale.
    if (complete && elapsed > 0) root.deviceAge = 0
    root.updateAccelerators(records, elapsed)
    if (uptime >= 0) root.prevDeviceUptime = uptime
  }

  // Forget the previous samples, so the next delta starts from a fresh base.
  function rebaseCore() {
    root.coreEpoch++
    root.prevBusy = -1
    root.prevTotal = -1
    root.prevCoreBusy = ({})
    root.prevCoreTotal = ({})
    root.prevUptime = -1
    // The core grid empties rather than holding the last loads, and the
    // graph starts over: drawn on, it would join the readings either side
    // of the gap as if they were one stretch.
    root.coreLoads = root.coreLoads.map(function() { return -1 })
    root.cpuHistory = []
  }

  function rebaseDevices() {
    root.deviceEpoch++
    // Marked on each device as well: the cells read only their own state.
    var marked = {}
    for (var id in root.accelState) marked[id] = Object.assign({}, root.accelState[id], { stale: true })
    root.accelState = marked
    root.accelHistory = ({})
    root.prevAccel = ({})
    root.prevDeviceUptime = -1
    root.throttleSamples = []
    root.throttleShare = 0
  }

  onCoreStaleChanged: if (coreStale) rebaseCore()
  onDeviceStaleChanged: if (deviceStale) rebaseDevices()

  function startSampler() {
    if (sampler.running) return
    root.coreRunEpoch = root.coreEpoch
    sampler.running = true
  }

  function startDeviceProbe() {
    if (deviceProbe.running) return
    root.deviceRunEpoch = root.deviceEpoch
    deviceProbe.running = true
  }

  function clearDisk(status) {
    root.diskTotalGb = 0
    root.diskUsedGb = 0
    root.diskFreeGb = 0
    root.diskFraction = 0
    root.diskLow = false
    root.diskStatus = status
  }

  // Probe output: "rc <df exit status>", then "disk <size> <used> <avail>".
  // With one probe per mount in flight, an answer for the current mount is
  // also the newest for it: the next is only started once this one is gone.
  function parseDisk(text, mount) {
    // An answer for a mount the setting has since moved off.
    if (mount !== root.diskMount) return

    var rc = -1
    var d = []
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf("rc ") === 0) rc = parseInt(lines[i].substr(3), 10)
      else if (lines[i].indexOf("disk ") === 0) d = lines[i].split(/\s+/)
    }

    var totalBytes = parseFloat(d[1])
    var usedBytes = parseFloat(d[2])
    var freeBytes = parseFloat(d[3])
    if (rc === 0 && totalBytes > 0 && usedBytes >= 0) {
      root.diskTotalGb = bytesToGb(totalBytes)
      root.diskUsedGb = bytesToGb(usedBytes)
      root.diskFreeGb = freeBytes >= 0 ? bytesToGb(freeBytes) : bytesToGb(totalBytes - usedBytes)
      root.diskFraction = Math.max(0, Math.min(1, usedBytes / totalBytes))
      root.diskLow = root.diskFreeGb < root.diskFloor * (root.diskLow ? root.diskFloorHold : 1)
      root.diskStatus = "ok"
    } else {
      // 124 is timeout's own TERM, 137 the KILL that follows it.
      root.clearDisk(rc === 124 || rc === 137 ? "stalled" : "unavailable")
    }
  }

  function startDiskProbe() {
    if (!root.diskMountValid) {
      if (root.diskStatus !== "unavailable") root.clearDisk("unavailable")
      return
    }
    var mount = root.diskMount
    var pending = null
    for (var i = 0; i < root.diskProbes.length; i++) {
      if (root.diskProbes[i].mount === mount) pending = root.diskProbes[i]
    }
    // Still waiting on this mount: no second df, and past diskStallMs the
    // mount is reported stuck.
    if (pending) {
      if (Date.now() - pending.started > root.diskStallMs && root.diskStatus !== "stalled")
        root.clearDisk("stalled")
      return
    }
    // Every slot is held by probes stuck on other mounts. Nothing can be
    // asked until one of them ends; after as long as a stuck probe is
    // given, say this mount is not answering either.
    if (root.diskProbes.length >= root.diskProbeCap) {
      if (Date.now() - root.diskMountSince > root.diskStallMs && root.diskStatus !== "stalled")
        root.clearDisk("stalled")
      return
    }
    var probe = diskProbeComponent.createObject(root, { mount: mount, started: Date.now() })
    if (!probe) return
    root.diskProbes = root.diskProbes.concat([probe])
    probe.running = true
  }

  // Only once the process has gone: destroying a Process that is still
  // running would kill and then wait on it. Safe to call twice.
  function diskProbeEnded(probe) {
    if (root.diskProbes.indexOf(probe) < 0) return
    root.diskProbes = root.diskProbes.filter(function(p) { return p !== probe })
    probe.destroy()
  }

  // Never show one mount's figures under another's name.
  onDiskMountChanged: {
    clearDisk("")
    diskMountSince = Date.now()
    startDiskProbe()
  }

  function openBtop() {
    if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
    root.close()
  }

  // Browse what fills the storage mount; the mount arrives as $1. disktree,
  // Omarchy's disk treemap, opens straight on it, and a scan of / includes
  // btrfs subvolumes such as /home. Without disktree (an older Omarchy), a
  // floating terminal (TUI.float is the app-id Omarchy floats) runs the TUI
  // script, $2: dua, then gdu or ncdu if one of those is what's installed;
  // with none, offer to install disktree. Not --stay-on-filesystem there:
  // btrfs subvolumes count as other filesystems. dua and gdu skip /proc, /dev,
  // /sys and /run by default.
  readonly property string diskUsageTuiScript:
    "if command -v dua >/dev/null; then exec dua interactive \"$1\"; " +
    "elif command -v gdu >/dev/null; then exec gdu \"$1\"; " +
    "elif command -v ncdu >/dev/null; then exec ncdu --exclude-kernfs \"$1\"; fi; " +
    "read -rp 'No disk usage analyzer found. Install disktree? [y/N] ' a; " +
    "case $a in [yY]*) omarchy-pkg-add disktree-bin && setsid -f uwsm-app -- disktree \"$1\" && exit;; esac; " +
    "read -rsn1 -p 'Press any key to close.'"

  readonly property string diskUsageScript:
    "if command -v disktree >/dev/null; then exec uwsm-app -- disktree \"$1\"; fi; " +
    "exec omarchy-launch-tui --app-id=TUI.float bash -c \"$2\" disk-usage \"$1\""

  function openDiskUsage() {
    if (root.bar && root.diskMountValid) root.bar.run("bash -c " + Util.shellQuote(root.diskUsageScript)
      + " disk-usage " + Util.shellQuote(root.diskMount) + " " + Util.shellQuote(root.diskUsageTuiScript))
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onCpuHistoryChanged: sparkline.requestPaint()
  onInkChanged: sparkline.requestPaint()
  onOpenedChanged: if (opened) { startSampler(); sparkline.requestPaint() }

  Process {
    id: sampler
    command: ["sh", "-c",
      "grep '^cpu' /proc/stat; " +
      "grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo; " +
      "echo \"loadavg $(cat /proc/loadavg)\"; " +
      "echo \"uptime $(cut -d' ' -f1 /proc/uptime)\"; " +
      "awk '$3 ~ /^(nvme[0-9]+n[0-9]+|sd[a-z]+|mmcblk[0-9]+|vd[a-z]+)$/ {r+=$6; w+=$10} END {print \"dio\", r+0, w+0}' /proc/diskstats; " +
      "echo \"model $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)\"; " +
      "echo \"pcores $(cat /sys/devices/cpu_core/cpus 2>/dev/null)\"; " +
      "echo \"ecores $(cat /sys/devices/cpu_atom/cpus 2>/dev/null)\""]
    stdout: StdioCollector {
      id: collector
      waitForEnd: true
      // Referenced through the id on purpose: a bare `text` here would
      // resolve to whatever `text` is in scope, not the collector's own.
      onStreamFinished: root.parse(collector.text)
    }
  }

  // GPU, NPU and CPU sensor reads, apart from the sampler: they go through
  // drivers, and a read that stalls there would otherwise stop the CPU and
  // memory figures with it. Builtins only, so one process per sample; it
  // reads /proc/uptime itself so its deltas use its own clock.
  Process {
    id: deviceProbe
    command: ["sh", "-c",
      "read up _ < /proc/uptime; echo \"uptime $up\"; " +
      // card0-DP-1 and friends are connectors, not devices.
      "for c in /sys/class/drm/card[0-9]*; do " +
        "case ${c##*/} in *-*) continue;; esac; d=$c/device; [ -e \"$d\" ] || continue; " +
        "rs=active; read rs < \"$d/power/runtime_status\"; " +
        "if [ \"$rs\" = suspended ]; then echo \"gpu ${c##*/} suspended\"; continue; fi; " +
        "for g in \"$d\"/tile*/gt*; do [ -r \"$g/gtidle/idle_residency_ms\" ] || continue; " +
          "read n < \"$g/gtidle/name\"; read i < \"$g/gtidle/idle_residency_ms\"; " +
          "read f < \"$g/freq0/cur_freq\"; read m < \"$g/freq0/rp0_freq\"; " +
          "echo \"gpu ${c##*/} idle $n $i $f $m\"; done; " +
        "if [ -r \"$c/gt/gt0/rc6_residency_ms\" ]; then read i < \"$c/gt/gt0/rc6_residency_ms\"; " +
          "read f < \"$c/gt_cur_freq_mhz\"; read m < \"$c/gt_RP0_freq_mhz\"; " +
          "echo \"gpu ${c##*/} idle rc $i $f $m\"; fi; " +
        "if [ -r \"$d/gpu_busy_percent\" ]; then read b < \"$d/gpu_busy_percent\"; echo \"gpu ${c##*/} busy $b\"; fi; " +
      "done 2>/dev/null; " +
      // intel_vpu answers these from driver bookkeeping and reports 0 MHz
      // rather than waking a suspended NPU, so they are safe to read asleep.
      "for a in /sys/class/accel/accel[0-9]*; do d=$a/device; [ -r \"$d/npu_busy_time_us\" ] || continue; " +
        "rs=active; read rs < \"$d/power/runtime_status\"; read b < \"$d/npu_busy_time_us\"; " +
        "read f < \"$d/npu_current_frequency_mhz\"; read m < \"$d/npu_max_frequency_mhz\"; " +
        "read u < \"$d/npu_memory_utilization\"; echo \"npu ${a##*/} $rs $b $f $m $u\"; " +
      "done 2>/dev/null; " +
      // temp1 is the package sensor on coretemp ("Package id 0") and the
      // control temperature on k10temp/zenpower (Tctl). Both are cheap
      // cached reads, unlike the ACPI, EC and NVMe sensors beside them.
      "for h in /sys/class/hwmon/hwmon*; do read n < \"$h/name\"; " +
        "case $n in coretemp|k10temp|zenpower) read t < \"$h/temp1_input\" && echo \"ctemp $t\"; break;; esac; " +
      "done 2>/dev/null; " +
      // Intel only; elsewhere the line is simply absent.
      "read t < /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms 2>/dev/null " +
        "&& echo \"throttle $t\"; " +
      // Only a run that got this far counts as a sample.
      "echo end"]
    stdout: StdioCollector {
      id: deviceCollector
      waitForEnd: true
      onStreamFinished: root.parseDevices(deviceCollector.text)
    }
  }

  // df on its own, under a timeout: a hung network mount stalls df, and on
  // the sampler's shell it would hold back every other figure with it,
  // since a sample only starts once the last one has finished. One process
  // per probe, made by startDiskProbe and destroyed once it exits, so a df
  // that even timeout cannot end holds up only its own mount. The mount
  // arrives as $1 rather than in the script.
  Component {
    id: diskProbeComponent

    Process {
      id: probe
      property string mount: ""
      property real started: 0
      command: ["sh", "-c",
        "out=$(timeout -k 1 2 df -B1 --output=size,used,avail -- \"$1\" 2>/dev/null); " +
        "echo \"rc $?\"; echo \"disk $(printf '%s\\n' \"$out\" | tail -n 1)\"",
        "disk-probe", probe.mount]
      stdout: StdioCollector {
        id: probeOutput
        waitForEnd: true
        onStreamFinished: root.parseDisk(probeOutput.text, probe.mount)
      }
      // On running going false rather than on exited: a launch that fails
      // (no fork, sh not found) never emits exited, and would otherwise
      // hold its mount's slot for good. On a normal exit this comes after
      // the output has been parsed.
      onRunningChanged: if (!running) root.diskProbeEnded(probe)
    }
  }

  // Device names change with hardware, not per tick: probed once, and again
  // only when the set of accelerators does.
  Process {
    id: nameProbe
    command: ["sh", "-c",
      "for c in /sys/class/drm/card[0-9]* /sys/class/accel/accel[0-9]*; do " +
        "case ${c##*/} in *-*) continue;; esac; [ -e \"$c/device\" ] || continue; " +
        "s=$(readlink -f \"$c/device\"); echo \"${c##*/} $(lspci -mm -s \"${s##*/}\" 2>/dev/null)\"; " +
      "done"]
    stdout: StdioCollector {
      id: nameCollector
      waitForEnd: true
      onStreamFinished: root.parseNames(nameCollector.text)
    }
  }

  onAccelIdsChanged: if (accelIds.length > 0 && !nameProbe.running) nameProbe.running = true
  onAccelHistoryChanged: sparkline.requestPaint()

  // Startup read, then again whenever the theme moves the shell's colours.
  FileView {
    id: paletteFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.loadPalette(text())
  }

  Connections {
    target: Color
    function onAccentChanged() { paletteFile.reload() }
    function onForegroundChanged() { paletteFile.reload() }
  }

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      // A process still running from an earlier tick is left to finish
      // and its group ages; see staleTicks.
      root.coreAge = Math.min(root.staleTicks, root.coreAge + 1)
      root.deviceAge = Math.min(root.staleTicks, root.deviceAge + 1)
      root.startSampler()
      root.startDeviceProbe()
      root.startDiskProbe()
    }
  }

  // ---------- Bar button: two level meters, no text ----------

  // Idle machines live in the bottom fifth of the scale, where a 13px track
  // cannot separate 10% from 25% — both round to the same couple of pixels.
  // A gamma curve spends more of the track on the range the values actually
  // occupy while still topping out at 100%. The panel carries exact figures.
  component Meter: Item {
    property real fraction: 0
    property int settleMs: 240
    // No fresh sample: the fill goes, leaving the bare track, rather than
    // holding a reading that may no longer be true.
    property bool stale: false

    readonly property real shown: Math.pow(Math.max(0, Math.min(1, fraction)), 0.6)

    width: root.meterWidth
    height: root.meterHeight

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: root.ink
      opacity: 0.18
    }

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      // A 2px floor keeps a fully idle meter visible on its track without
      // swallowing the difference between low readings.
      height: Math.max(2, parent.height * parent.shown)
      radius: width / 2
      color: root.loadColor(parent.fraction)
      opacity: parent.stale ? 0 : 1

      Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
      Behavior on height { NumberAnimation { duration: Style.duration(settleMs); easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: Style.duration(240) } }
    }
  }

  WidgetButton {
    id: button
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: (root.coreStale ? "CPU and memory not responding"
        : "CPU " + root.cpuPercentText + "   ·   RAM " + root.memUsedGb.toFixed(1) + " / " + root.memTotalGb.toFixed(1) + " GB")
      + root.accelIds.map(function(id) {
          var kind = root.accelKind(id)
          var over = kind === "gpu" ? root.gpuAlert : root.npuAlert
          var limit = kind === "gpu" ? root.gpuAlertAt : root.npuAlertAt
          var work = Math.round(Math.max(0, root.accelWork(root.accelState[id])))
          return "   ·   " + root.accelLabel(id) + " " + root.accelPercentText(id)
            + (over ? " (work " + work + "% > " + limit + "%)" : "")
        }).join("")
      + (root.diskLow
        ? "   ·   Disk " + root.diskMount + " " + root.diskFreeGb.toFixed(1) + " GB free (under "
          + (root.diskFloor >= 10 ? root.diskFloor.toFixed(0) : root.diskFloor.toFixed(1)) + " GB)"
        : "")
    fixedWidth: vertical ? -1 : root.meterWidth * 2 + root.meterGap + Style.space(14)
    fixedHeight: vertical ? root.meterWidth * 2 + root.meterGap + Style.space(14) : -1
    onPressed: root.toggle()

    Grid {
      id: meterGrid
      anchors.centerIn: parent
      columns: button.vertical ? 1 : 2
      rows: button.vertical ? 2 : 1
      columnSpacing: root.meterGap
      rowSpacing: root.meterGap

      Meter { fraction: root.cpuShown; stale: root.coreStale; settleMs: 180 }
      Meter { fraction: root.memShown; stale: root.coreStale; settleMs: 320 }
    }

    // Alert line over the meters (to their left on a vertical bar),
    // anchored to them rather than laid out with them: the meters stay
    // centred in the button whether or not a mark is showing, and the line
    // sits in the bar's spare height.
    AlertBaseline {
      vertical: button.vertical
      length: button.vertical ? meterGrid.height : meterGrid.width
      anchors.bottom: button.vertical ? undefined : meterGrid.top
      anchors.horizontalCenter: button.vertical ? undefined : meterGrid.horizontalCenter
      anchors.right: button.vertical ? meterGrid.left : undefined
      anchors.verticalCenter: button.vertical ? meterGrid.verticalCenter : undefined
      anchors.bottomMargin: Style.space(3)
      anchors.rightMargin: Style.space(3)
    }
  }

  // GPU mark in the GPU trace colour, NPU mark in the NPU's, low disk in
  // the theme's urgent colour. One alone spans the whole meter pair; more
  // split it in that order: two take one segment over each meter, three
  // close the gaps up so each segment stays wide enough to see. A mark
  // that is off waits at full length, so it grows in from there.
  component AlertBaseline: Item {
    id: baseline

    property bool vertical: false
    property real length: 0
    readonly property real thickness: 2
    readonly property var marks: [root.gpuAlert, root.npuAlert, root.diskLow]
    readonly property int count: marks.filter(function(on) { return on }).length
    readonly property real gap: count > 2 ? Style.space(2) : root.meterGap
    readonly property real slot: count > 1 ? (length - gap * (count - 1)) / count : length

    // Where mark `i` starts, counting only the marks before it that are on.
    function startOf(i) {
      var before = 0
      for (var j = 0; j < i; j++) if (marks[j]) before++
      return before * (slot + gap)
    }

    width: vertical ? thickness : length
    height: vertical ? length : thickness

    AlertSegment {
      vertical: baseline.vertical
      thickness: baseline.thickness
      on: baseline.marks[0]
      color: root.gpuTint
      start: on ? baseline.startOf(0) : 0
      span: on ? baseline.slot : baseline.length
    }

    AlertSegment {
      vertical: baseline.vertical
      thickness: baseline.thickness
      on: baseline.marks[1]
      color: root.npuTint
      start: on ? baseline.startOf(1) : 0
      span: on ? baseline.slot : baseline.length
    }

    AlertSegment {
      vertical: baseline.vertical
      thickness: baseline.thickness
      on: baseline.marks[2]
      color: root.bar ? root.bar.urgent : Color.urgent
      start: on ? baseline.startOf(2) : 0
      span: on ? baseline.slot : baseline.length
    }
  }

  // ---------- Panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.openBtop()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        // Sections are split by a SectionGap rather than a rule: the gap
        // takes spacing on both sides, so sections sit twice as far apart
        // as the rows inside them, and the headers do the dividing.
        spacing: Style.space(12)

        PanelHero {
          title: "System"
          meta: root.cpuModel !== "" ? root.cpuModel : "CPU"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily

          iconComponent: PlainText {
            text: ""
            color: root.loadColor(root.cpuShown)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            Behavior on color { ColorAnimation { duration: Style.duration(240) } }
          }

          trailingControl: PlainText {
            text: root.cpuPercentText
            color: root.loadColor(root.cpuShown)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            Behavior on color { ColorAnimation { duration: Style.duration(240) } }
          }
        }

        // ---------- Average CPU over time ----------
        // Graph and its legend as one block, so they keep their own spacing.
        Column {
          width: parent.width
          spacing: Style.space(14)

          Canvas {
            id: sparkline
            width: parent.width
            height: Style.space(69)

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()

              var w = width
              var h = height
              var points = root.cpuHistory

              // Quarter gridlines, so a trace has something to be read against.
              ctx.strokeStyle = root.ink
              ctx.lineWidth = 1
              for (var g = 1; g <= 4; g++) {
                var gy = Math.round(h - (h * g / 4)) + 0.5
                ctx.globalAlpha = g === 4 ? 0.16 : 0.08
                ctx.beginPath()
                ctx.moveTo(0, gy)
                ctx.lineTo(w, gy)
                ctx.stroke()
              }

              ctx.globalAlpha = 0.16
              ctx.beginPath()
              ctx.moveTo(0, h - 0.5)
              ctx.lineTo(w, h - 0.5)
              ctx.stroke()

              if (points.length < 2) return

              // Right-aligned: history fills in from the newest edge, so a
              // freshly started widget does not stretch three samples across
              // the full width and imply history it does not have.
              var step = w / (root.historyLength - 1)
              var offset = w - (points.length - 1) * step
              var yFor = function(v) { return h - Math.max(1, v * (h - 2)) }

              ctx.globalAlpha = 0.22
              ctx.beginPath()
              ctx.moveTo(offset, h)
              for (var i = 0; i < points.length; i++) ctx.lineTo(offset + i * step, yFor(points[i]))
              ctx.lineTo(offset + (points.length - 1) * step, h)
              ctx.closePath()
              ctx.fillStyle = root.ink
              ctx.fill()

              ctx.globalAlpha = 1.0
              ctx.strokeStyle = root.loadColor(points[points.length - 1])
              ctx.lineWidth = 1.5
              ctx.beginPath()
              for (var k = 0; k < points.length; k++) {
                var x = offset + k * step
                var y = yFor(points[k])
                if (k === 0) ctx.moveTo(x, y)
                else ctx.lineTo(x, y)
              }
              ctx.stroke()

              // Accelerators as unfilled traces over the CPU's area, dashed for
              // GPUs and dotted for NPUs. A device that has sat at zero for the
              // whole window draws nothing rather than a line along the floor.
              for (var a = 0; a < root.accelIds.length; a++) {
                var id = root.accelIds[a]
                var trace = root.accelHistory[id] || []
                if (trace.length < 2 || !trace.some(function(v) { return v > 0.01 })) continue

                var traceOffset = w - (trace.length - 1) * step
                ctx.strokeStyle = root.accelTint(id)
                root.applyLineStyle(ctx, root.accelKind(id))
                ctx.beginPath()
                for (var t = 0; t < trace.length; t++) {
                  var tx = traceOffset + t * step
                  var ty = yFor(trace[t])
                  if (t === 0) ctx.moveTo(tx, ty)
                  else ctx.lineTo(tx, ty)
                }
                ctx.stroke()
              }
              root.applyLineStyle(ctx, "cpu")
            }
          }

          // Legend for the traces above; only once there is more than one.
          Flow {
            width: parent.width
            spacing: Style.space(16)
            visible: root.accelIds.length > 0

            LegendItem { kind: "cpu"; tint: root.loadColor(root.cpuShown); label: "CPU " + root.cpuPercentText }

            Repeater {
              model: root.accelIds

              LegendItem {
                required property string modelData
                kind: root.accelKind(modelData)
                tint: root.accelTint(modelData)
                label: root.accelLabel(modelData) + " " + root.accelPercentText(modelData)
              }
            }
          }
        }

        SectionGap {}

        // ---------- Per-core activity ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.coreLoads.length > 0

          // Load average rides on the CORES header rather than sitting among
          // the memory figures: it is a CPU number, and the right half of a
          // section header is otherwise dead space.
          SectionHead {
            title: "CORES"
            note: root.cpuTempText
            alert: root.throttleText
            value: root.coreStale ? "not responding"
              : root.loadAverage !== "" ? "LOAD  " + root.loadAverage : ""
          }

          Grid {
            id: coreGrid
            width: parent.width
            columns: root.coreColumns
            columnSpacing: Style.space(4)
            rowSpacing: Style.space(6)

            readonly property real cellWidth: columns > 0
              ? (width - columnSpacing * (columns - 1)) / columns
              : 0
            // Shorter blocks once the grid wraps, so a 24-core machine does
            // not push the rest of the panel off the bottom of the screen.
            // The graph above carries the trend, so these only need to say
            // which cores are hot; tall idle blocks were mostly empty boxes.
            readonly property real blockHeight: root.coreRows > 1 ? Style.space(14) : Style.space(20)

            Repeater {
              model: root.coreLoads

              Column {
                id: coreCell
                required property var modelData
                required property int index
                width: coreGrid.cellWidth
                spacing: Style.space(4)

                // Full-width blocks rather than slim pills: the wide cells
                // read as a row of gauges you can scan across.
                Item {
                  width: parent.width
                  height: coreGrid.blockHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.10)
                  }

                  Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    // -1 is no reading (see rebaseCore): an empty block.
                    height: Math.max(coreCell.modelData < 0 ? 0 : 2, parent.height * Math.min(1, coreCell.modelData))
                    radius: Style.cornerRadius
                    color: root.loadColor(modelData)

                    Behavior on height { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: Style.duration(240) } }
                  }
                }

                PlainText {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.coreLabel(root.coreIds[index])
                  color: root.bar.foreground
                  opacity: 0.5
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        SectionGap {}

        // ---------- Accelerators ----------
        // One column per GPU/NPU, split by hairlines. Each gauge's outer arc
        // is load and its inner arc is clock against the device's maximum:
        // 30% busy at the floor clock is idling, 30% at full clock is not.
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.accelIds.length > 0

          SectionHead {
            title: "ACCELERATORS"
            value: root.deviceStale ? "not responding" : ""
          }

          Row {
            id: accelRow
            width: parent.width
            spacing: ruleGap

            readonly property real ruleGap: Style.space(14)
            readonly property int count: root.accelIds.length
            readonly property real cellWidth: count > 0
              ? (width - (count - 1) * (ruleGap * 2 + 1)) / count
              : 0

            Repeater {
              model: root.accelIds

              Row {
                required property string modelData
                required property int index
                spacing: accelRow.ruleGap

                Rectangle {
                  visible: index > 0
                  width: 1
                  height: cell.height
                  color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
                }

                AccelCell {
                  id: cell
                  deviceId: modelData
                  width: accelRow.cellWidth
                }
              }
            }
          }
        }

        SectionGap { visible: root.accelIds.length > 0 }

        // ---------- Capacity: memory and storage ----------
        // Things being filled rather than things working, so one compact row
        // of two columns, the same shape as the accelerators above, instead
        // of a full section each.
        Column {
          width: parent.width
          spacing: Style.space(10)

          SectionHead { title: "CAPACITY" }

          Row {
            id: capacityRow
            width: parent.width
            spacing: Style.space(14)

            readonly property real cellWidth: (width - spacing * 2 - 1) / 2

            CapacityCell {
              width: capacityRow.cellWidth
              label: "RAM"
              fraction: root.memShown
              softFraction: root.coreStale ? 0 : root.memCacheFraction
              figureText: root.coreStale ? "—" : root.memUsedGb.toFixed(1)
              figureSuffix: root.coreStale ? "" : " / " + root.memTotalGb.toFixed(1) + " GB"
              detail: root.coreStale ? "not responding"
                : "cache " + root.memCacheGb.toFixed(1) + " · "
                  + (root.swapTotalGb > 0 ? "swap " + root.swapUsedGb.toFixed(1) : "no swap")
            }

            Rectangle {
              width: 1
              height: capacityRow.height
              color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
            }

            CapacityCell {
              width: capacityRow.cellWidth
              label: "DISK"
              labelDetail: root.diskMount
              fraction: root.diskFraction
              // Free leads here: on a disk the question is how much room is left.
              figureText: root.diskKnown ? root.diskFreeGb.toFixed(0) : "—"
              figureSuffix: root.diskKnown ? " GB free" : ""
              // Used bright, total dim, so the pair reads as used of total
              // without the words; arrows hug their rates to fit the column.
              // Throughput comes from /proc/diskstats, not df, so it carries
              // on while the mount is unavailable or stuck, and goes with the
              // CPU and memory figures when the sampler stalls instead.
              detailLead: root.diskKnown ? root.diskUsedGb.toFixed(0) : ""
              detail: [
                root.diskKnown ? "/" + root.diskTotalGb.toFixed(0) : root.diskNote,
                root.coreStale ? "" : "↓" + root.rateText(root.readBytesPerSec)
                  + " ↑" + root.rateText(root.writeBytesPerSec)
              ].filter(function(part) { return part !== "" }).join(" · ")
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // Footer: btop and the disk browser are secondary actions (Enter
        // already opens btop), so quiet links rather than bordered buttons.
        Item {
          width: parent.width
          implicitHeight: Math.max(refreshNote.implicitHeight, footerLinks.implicitHeight)

          PlainText {
            id: refreshNote
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "updated every " + Math.round(root.refreshMs / 1000) + "s"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            id: footerLinks
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(18)

            FooterLink {
              text: "Disk usage"
              onActivated: root.openDiskUsage()
            }

            FooterLink {
              text: "↵ Open btop"
              onActivated: root.openBtop()
            }
          }
        }
      }
    }
  }

  // Dash pattern per trace kind, shared by the sparkline and its legend so
  // a swatch always matches the line it names. Qt's Canvas measures dashes
  // in multiples of the line width, as QPen does, not in pixels.
  function applyLineStyle(ctx, kind) {
    ctx.lineWidth = 1.5
    if (kind === "gpu") {
      ctx.lineCap = "butt"
      ctx.setLineDash([3, 2])
    } else if (kind === "npu") {
      ctx.lineCap = "round"
      ctx.setLineDash([0.01, 2.2])
    } else {
      ctx.lineCap = "butt"
      ctx.setLineDash([])
    }
  }

  component LineSwatch: Canvas {
    property string kind: "cpu"
    property color tint: root.ink

    width: Style.space(14)
    height: Style.space(8)

    onTintChanged: requestPaint()
    onKindChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.strokeStyle = tint
      root.applyLineStyle(ctx, kind)
      ctx.beginPath()
      ctx.moveTo(1, height / 2)
      ctx.lineTo(width - 1, height / 2)
      ctx.stroke()
    }
  }

  component LegendItem: Row {
    property string kind: "cpu"
    property color tint: root.ink
    property string label: ""

    spacing: Style.space(6)

    LineSwatch {
      anchors.verticalCenter: parent.verticalCenter
      kind: parent.kind
      tint: parent.tint
    }

    PlainText {
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // 270° arc from the bottom-left round to the bottom-right, filled to
  // `fraction`. Round caps leave a dot at zero, so an awake idle device
  // still shows where its arc starts.
  component GaugeArc: ShapePath {
    property real center: 0
    property real radius: 0
    property real fraction: 1

    fillColor: "transparent"
    capStyle: ShapePath.RoundCap

    PathAngleArc {
      centerX: center
      centerY: center
      radiusX: radius
      radiusY: radius
      startAngle: 135
      sweepAngle: 270 * Math.max(0, Math.min(1, fraction))
    }
  }

  component Gauge: Item {
    id: gauge

    property real busy: 0
    property real clock: -1
    property color tint: root.ink
    property bool asleep: false
    property string centerText: ""

    // Animated copies, so the arcs sweep rather than jump between ticks.
    property real busyShown: asleep ? 0 : Math.max(0, busy)
    property real clockShown: asleep ? 0 : Math.max(0, clock)
    Behavior on busyShown { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
    Behavior on clockShown { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }

    readonly property real outerStroke: Style.space(5)
    readonly property real innerStroke: Style.space(3)
    readonly property real outerRadius: width / 2 - outerStroke / 2
    readonly property real innerRadius: outerRadius - Style.space(6)
    readonly property color track: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
    // Brighter than the outer track, which reads at 0.12 only because it is
    // more than twice as wide.
    readonly property color innerTrack: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.28)

    width: Style.space(64)
    height: width

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      GaugeArc {
        center: gauge.width / 2
        radius: gauge.outerRadius
        strokeWidth: gauge.outerStroke
        strokeColor: gauge.track
      }
      GaugeArc {
        center: gauge.width / 2
        radius: gauge.outerRadius
        strokeWidth: gauge.outerStroke
        strokeColor: gauge.asleep ? "transparent" : gauge.tint
        fraction: gauge.busyShown
      }
      GaugeArc {
        center: gauge.width / 2
        radius: gauge.innerRadius
        strokeWidth: gauge.innerStroke
        strokeColor: gauge.innerTrack
      }
      GaugeArc {
        center: gauge.width / 2
        radius: gauge.innerRadius
        strokeWidth: gauge.innerStroke
        strokeColor: gauge.asleep || gauge.clock < 0 ? "transparent" : root.ink
        fraction: gauge.clockShown
      }
    }

    PlainText {
      anchors.centerIn: parent
      text: gauge.centerText
      color: gauge.asleep ? root.bar.foreground : root.loadColor(gauge.busy)
      opacity: gauge.asleep ? 0.5 : 1
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  // Gauge plus name, model and two facts. Dims while the device sleeps
  // rather than vanishing, so the row does not reflow as an NPU naps.
  component AccelCell: Row {
    id: cell

    property string deviceId: ""
    // Not `state`: that is Item's own state-machine property.
    readonly property var info: root.accelState[deviceId] || ({})
    readonly property var facts: root.accelFacts(deviceId)
    readonly property bool asleep: info.asleep === true
    // Asleep or not answering: either way there is no load to show.
    readonly property bool quiet: asleep || info.stale === true

    spacing: Style.space(12)
    opacity: quiet ? 0.55 : 1
    Behavior on opacity { NumberAnimation { duration: Style.duration(240) } }

    Gauge {
      id: cellGauge
      anchors.verticalCenter: parent.verticalCenter
      busy: cell.info.busy !== undefined ? cell.info.busy : 0
      clock: cell.info.clock !== undefined ? cell.info.clock : -1
      asleep: cell.quiet
      tint: root.accelTint(cell.deviceId)
      centerText: root.accelPercentText(cell.deviceId)
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, cell.width - cellGauge.width - cell.spacing)
      spacing: Style.space(2)

      // The label's colour already ties it to its trace in the graph; the
      // dash pattern lives only in the legend.
      PlainText {
        text: root.accelLabel(cell.deviceId)
        color: root.accelTint(cell.deviceId)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        font.letterSpacing: 1.2
      }

      PlainText {
        width: parent.width
        text: root.accelNames[cell.deviceId] || ""
        visible: text !== ""
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // Two fixed rows rather than a Repeater: the facts are rebuilt every
      // tick, and a Repeater would tear its delegates down each time.
      FactRow { pair: cell.facts[0] || ["", ""] }
      FactRow { pair: cell.facts[1] || ["", ""] }
    }
  }

  component FactRow: Row {
    property var pair: ["", ""]
    spacing: Style.space(6)

    PlainText {
      width: Style.space(40)
      text: pair[0]
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }

    PlainText {
      text: pair[1]
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // Fill bar with an optional second, dimmer segment stacked after the
  // hard fill: memory apps hold (solid) then reclaimable cache (dim). The
  // soft bar spans hard + soft and sits under the hard one, so the two
  // read as one bar without a seam to line up.
  component SplitBar: Item {
    id: splitBar

    property real fraction: 0
    property real softFraction: 0

    readonly property real hard: Math.max(0, Math.min(1, fraction))
    readonly property real total: Math.max(hard, Math.min(1, fraction + softFraction))

    implicitHeight: Style.space(6)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
    }

    Rectangle {
      visible: splitBar.total > splitBar.hard
      height: parent.height
      width: Math.max(height, parent.width * splitBar.total)
      radius: height / 2
      color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.35)
      Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
    }

    Rectangle {
      height: parent.height
      width: Math.max(height, parent.width * splitBar.hard)
      radius: height / 2
      color: root.loadColor(splitBar.fraction)
      Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: Style.duration(240) } }
    }
  }

  // Label and its figure on one line, the bar, then one dim detail line.
  component CapacityCell: Column {
    id: capacityCell

    property string label: ""
    // After the label in its own case, not the label's capitals: a mount
    // path such as /home is case-sensitive.
    property string labelDetail: ""
    property real fraction: 0
    property real softFraction: 0
    property string figureText: ""
    property string figureSuffix: ""
    property string detailLead: ""
    property string detail: ""

    spacing: Style.space(7)

    Item {
      width: capacityCell.width
      height: Math.max(cellLabel.implicitHeight, cellFigure.implicitHeight)

      Row {
        id: cellLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - cellFigure.implicitWidth - Style.space(8))
        spacing: Style.space(5)

        PlainText {
          id: cellCaption
          text: capacityCell.label.toUpperCase()
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          font.letterSpacing: 1.2
        }

        // No letter spacing: that is there to open up capitals.
        PlainText {
          width: Math.max(0, cellLabel.width - cellCaption.implicitWidth - cellLabel.spacing)
          text: capacityCell.labelDetail
          visible: text !== ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }
      }

      Row {
        id: cellFigure
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        PlainText {
          text: capacityCell.figureText
          color: root.loadColor(capacityCell.fraction)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          Behavior on color { ColorAnimation { duration: Style.duration(240) } }
        }

        PlainText {
          text: capacityCell.figureSuffix
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    SplitBar {
      width: capacityCell.width
      fraction: capacityCell.fraction
      softFraction: capacityCell.softFraction
    }

    // An optional bright lead, then the dim rest, which elides if it runs long.
    Row {
      width: capacityCell.width

      PlainText {
        id: detailLeadText
        text: capacityCell.detailLead
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }

      PlainText {
        width: Math.max(0, capacityCell.width - detailLeadText.implicitWidth)
        text: capacityCell.detail
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component FooterLink: PlainText {
    id: footerLink

    signal activated()

    color: linkArea.containsMouse ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.15)
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: linkArea.containsMouse

    MouseArea {
      id: linkArea
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: footerLink.activated()
    }
  }

  // Every label here is plain text. Some carry what the plugin does not
  // write itself (the mount setting, the CPU and GPU names, df and sysfs
  // figures), and Text's default AutoText would read markup-shaped input
  // as rich text.
  component PlainText: Text {
    textFormat: Text.PlainText
  }

  // Zero-height on purpose: Column spacing on either side is the gap.
  component SectionGap: Item {
    width: 1
    height: 0
  }

  // One coloured run of the alert baseline, positioned along its axis.
  component AlertSegment: Rectangle {
    property bool vertical: false
    property real thickness: 2
    property bool on: false
    property real start: 0
    property real span: 0

    x: vertical ? 0 : start
    y: vertical ? start : 0
    width: vertical ? thickness : span
    height: vertical ? span : thickness
    radius: thickness / 2
    opacity: on ? 1 : 0

    Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
    Behavior on start { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
    Behavior on span { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
  }

  // Section header with a headline figure on the trailing edge. Reuses
  // PanelSectionHeader for the label so the small-caps treatment matches
  // every other panel in the shell.
  component SectionHead: Item {
    property string title: ""
    property string value: ""
    property color valueColor: root.bar.foreground
    // Optional figures right after the title, the alert half in the
    // theme's urgent colour.
    property string note: ""
    property string alert: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(headLabel.implicitHeight, headValue.implicitHeight)

    PanelSectionHeader {
      id: headLabel
      text: parent.title
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Row {
      anchors.left: headLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      PlainText {
        text: parent.parent.note
        visible: text !== ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      PlainText {
        text: parent.parent.alert
        visible: text !== ""
        color: root.bar.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    PlainText {
      id: headValue
      text: parent.value
      visible: text !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      color: parent.valueColor
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true

      Behavior on color { ColorAnimation { duration: Style.duration(240) } }
    }
  }
}
