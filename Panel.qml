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
// GPUs and NPUs ride on the same `sh`, read with the `read` builtin so they
// add no processes. GPU load is the share of the tick the GT spent out of
// RC6 (xe gtidle, i915 rc6_residency) — "awake", which tracks real load
// closely without the CAP_PERFMON the engine PMU needs or the /proc/*/fdinfo
// walk per-client accounting costs. amdgpu reports gpu_busy_percent directly.
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
  property bool gpuAlert: false
  property bool npuAlert: false
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

  // Per-core CPU: parallel arrays of previous samples plus current load.
  property var prevCoreBusy: ({})
  property var prevCoreTotal: ({})
  property var coreLoads: []

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

  function coreLabel(index) {
    if (root.pCoreSet[index]) return "P" + index
    if (root.eCoreSet[index]) return "E" + index
    return String(index)
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
  readonly property string cpuTempText: cpuTempC >= 0 ? Math.round(cpuTempC) + "°C" : ""
  readonly property string throttleText: throttleShare >= throttleFloor
    ? "· throttled " + Math.round(throttleShare * 100) + "%" : ""

  // Storage. Usage is for one mount (configurable); throughput is summed
  // across whole block devices, ignoring partitions so their I/O is not
  // counted twice alongside the disk they sit on.
  readonly property string diskMount: setting("mount", "/")
  property real diskTotalGb: 0
  property real diskUsedGb: 0
  property real diskFraction: 0
  property real prevUptime: -1
  property real prevSectorsRead: -1
  property real prevSectorsWritten: -1
  property real readBytesPerSec: 0
  property real writeBytesPerSec: 0

  readonly property string cpuPercentText: Math.round(cpuLoad * 100) + "%"

  // Accelerators, keyed by sysfs node (card0, accel0). accelIds only
  // changes when a device appears or goes, so the Repeaters keep their
  // delegates — and their animations — across ticks; per-tick figures live
  // in accelState and reach the delegates through bindings.
  property var accelIds: []
  property var accelState: ({})
  property var accelHistory: ({})
  property var accelNames: ({})
  property var prevAccel: ({})

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
    if (!s || s.asleep || s.busy < 0) return "—"
    return Math.round(s.busy * 100) + "%"
  }

  // Two label/value pairs for a device's cell beside its gauge.
  function accelFacts(id) {
    var s = root.accelState[id]
    if (!s) return []
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
        s = state[id] = { kind: r[0], asleep: false, busy: -1, media: -1, clock: -1, clockMhz: 0, memBytes: -1 }
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

    root.gpuAlert = root.overLimit(ids, state, "gpu", root.gpuAlertAt)
    root.npuAlert = root.overLimit(ids, state, "npu", root.npuAlertAt)
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
    var lines = String(text).split("\n")
    var memTotalKb = -1
    var memAvailableKb = -1
    var memFreeKb = -1
    var swapTotalKb = -1
    var swapFreeKb = -1

    var nextCoreBusy = {}
    var nextCoreTotal = {}
    var cores = []

    var nextUptime = -1
    var nextSectorsRead = -1
    var nextSectorsWritten = -1
    var accelRecords = []
    var throttleMs = -1

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
      } else if (line.indexOf("disk ") === 0) {
        var d = line.split(/\s+/)
        var totalBytes = parseFloat(d[1])
        var usedBytes = parseFloat(d[2])
        if (totalBytes > 0 && usedBytes >= 0) {
          root.diskTotalGb = bytesToGb(totalBytes)
          root.diskUsedGb = bytesToGb(usedBytes)
          root.diskFraction = Math.max(0, Math.min(1, usedBytes / totalBytes))
        }
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
      } else if (line.indexOf("gpu ") === 0 || line.indexOf("npu ") === 0) {
        accelRecords.push(line.split(/\s+/))
      } else if (line.indexOf("ctemp ") === 0) {
        var milli = parseFloat(line.substr(6))
        if (!isNaN(milli)) root.cpuTempC = milli / 1000
      } else if (line.indexOf("throttle ") === 0) {
        throttleMs = parseFloat(line.substr(9))
      }
    }

    if (nextUptime >= 0 && throttleMs >= 0) root.updateThrottle(nextUptime, throttleMs)

    root.prevCoreBusy = nextCoreBusy
    root.prevCoreTotal = nextCoreTotal
    // Only publish once there is a previous sample to diff against, so the
    // grid does not flash a row of zeroes on the first tick.
    if (cores.length > 0 && (root.coreLoads.length > 0 || root.prevTotal >= 0)) root.coreLoads = cores

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
    }
    if (swapTotalKb >= 0 && swapFreeKb >= 0) {
      root.swapTotalGb = gb(swapTotalKb)
      root.swapUsedGb = gb(swapTotalKb - swapFreeKb)
    }

    // Before the storage block below moves prevUptime on.
    var tickSeconds = nextUptime >= 0 && root.prevUptime >= 0 ? nextUptime - root.prevUptime : -1
    root.updateAccelerators(accelRecords, tickSeconds)

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
  }

  function openBtop() {
    if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onCpuHistoryChanged: sparkline.requestPaint()
  onInkChanged: sparkline.requestPaint()
  onOpenedChanged: if (opened) { sampler.running = true; sparkline.requestPaint() }

  Process {
    id: sampler
    command: ["sh", "-c",
      "grep '^cpu' /proc/stat; " +
      "grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo; " +
      "echo \"loadavg $(cat /proc/loadavg)\"; " +
      "echo \"uptime $(cut -d' ' -f1 /proc/uptime)\"; " +
      "echo \"disk $(df -B1 --output=size,used " + Util.shellQuote(root.diskMount) + " | tail -1)\"; " +
      "awk '$3 ~ /^(nvme[0-9]+n[0-9]+|sd[a-z]+|mmcblk[0-9]+|vd[a-z]+)$/ {r+=$6; w+=$10} END {print \"dio\", r+0, w+0}' /proc/diskstats; " +
      "echo \"model $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)\"; " +
      "echo \"pcores $(cat /sys/devices/cpu_core/cpus 2>/dev/null)\"; " +
      "echo \"ecores $(cat /sys/devices/cpu_atom/cpus 2>/dev/null)\"; " +
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
        "&& echo \"throttle $t\""]
    stdout: StdioCollector {
      id: collector
      waitForEnd: true
      // Referenced through the id on purpose: a bare `text` here would
      // resolve to whatever `text` is in scope, not the collector's own.
      onStreamFinished: root.parse(collector.text)
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
    onTriggered: if (!sampler.running) sampler.running = true
  }

  // ---------- Bar button: two level meters, no text ----------

  // Idle machines live in the bottom fifth of the scale, where a 13px track
  // cannot separate 10% from 25% — both round to the same couple of pixels.
  // A gamma curve spends more of the track on the range the values actually
  // occupy while still topping out at 100%. The panel carries exact figures.
  component Meter: Item {
    property real fraction: 0
    property int settleMs: 240

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

      Behavior on height { NumberAnimation { duration: settleMs; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  WidgetButton {
    id: button
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: "CPU " + root.cpuPercentText + "   ·   RAM " + root.memUsedGb.toFixed(1) + " / " + root.memTotalGb.toFixed(1) + " GB"
      + root.accelIds.map(function(id) {
          var kind = root.accelKind(id)
          var over = kind === "gpu" ? root.gpuAlert : root.npuAlert
          var limit = kind === "gpu" ? root.gpuAlertAt : root.npuAlertAt
          var work = Math.round(Math.max(0, root.accelWork(root.accelState[id])))
          return "   ·   " + root.accelLabel(id) + " " + root.accelPercentText(id)
            + (over ? " (work " + work + "% > " + limit + "%)" : "")
        }).join("")
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

      Meter { fraction: root.cpuLoad; settleMs: 180 }
      Meter { fraction: root.memFraction; settleMs: 320 }
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

  // GPU mark in the GPU trace colour, NPU mark in the NPU's. One alone
  // spans the whole meter pair; both split it, GPU first, one segment
  // over each meter.
  component AlertBaseline: Item {
    id: baseline

    property bool vertical: false
    property real length: 0
    readonly property real thickness: 2
    readonly property bool both: root.gpuAlert && root.npuAlert
    readonly property real half: (length - root.meterGap) / 2

    width: vertical ? thickness : length
    height: vertical ? length : thickness

    AlertSegment {
      vertical: baseline.vertical
      thickness: baseline.thickness
      on: root.gpuAlert
      color: root.gpuTint
      start: 0
      span: baseline.both ? baseline.half : baseline.length
    }

    AlertSegment {
      vertical: baseline.vertical
      thickness: baseline.thickness
      on: root.npuAlert
      color: root.npuTint
      start: baseline.both ? baseline.length - baseline.half : 0
      span: baseline.both ? baseline.half : baseline.length
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

          iconComponent: Text {
            text: ""
            color: root.loadColor(root.cpuLoad)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            Behavior on color { ColorAnimation { duration: 240 } }
          }

          trailingControl: Text {
            text: root.cpuPercentText
            color: root.loadColor(root.cpuLoad)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            Behavior on color { ColorAnimation { duration: 240 } }
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

            LegendItem { kind: "cpu"; tint: root.loadColor(root.cpuLoad); label: "CPU " + root.cpuPercentText }

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
            value: root.loadAverage !== "" ? "LOAD  " + root.loadAverage : ""
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
                    height: Math.max(2, parent.height * Math.max(0, Math.min(1, modelData)))
                    radius: Style.cornerRadius
                    color: root.loadColor(modelData)

                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 240 } }
                  }
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.coreLabel(index)
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

          SectionHead { title: "ACCELERATORS" }

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
              fraction: root.memFraction
              softFraction: root.memCacheFraction
              usedText: root.memUsedGb.toFixed(1)
              totalText: root.memTotalGb.toFixed(1) + " GB"
              detail: "cache " + root.memCacheGb.toFixed(1) + " · "
                + (root.swapTotalGb > 0 ? "swap " + root.swapUsedGb.toFixed(1) : "no swap")
            }

            Rectangle {
              width: 1
              height: capacityRow.height
              color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
            }

            CapacityCell {
              width: capacityRow.cellWidth
              label: "DISK " + root.diskMount
              fraction: root.diskFraction
              usedText: root.diskUsedGb.toFixed(0)
              totalText: root.diskTotalGb.toFixed(0) + " GB"
              detail: "↓ " + root.rateText(root.readBytesPerSec) + " · ↑ " + root.rateText(root.writeBytesPerSec)
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // Footer: btop is a secondary action that Enter already triggers, so
        // a quiet link rather than a full-width bordered button.
        Item {
          width: parent.width
          implicitHeight: Math.max(refreshNote.implicitHeight, btopLink.implicitHeight)

          Text {
            id: refreshNote
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "updated every " + Math.round(root.refreshMs / 1000) + "s"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: btopLink
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "↵ Open btop"
            color: btopArea.containsMouse ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.15)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: btopArea.containsMouse

            MouseArea {
              id: btopArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openBtop()
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

    Text {
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
    Behavior on busyShown { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
    Behavior on clockShown { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

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

    Text {
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

    spacing: Style.space(12)
    opacity: asleep ? 0.55 : 1
    Behavior on opacity { NumberAnimation { duration: 240 } }

    Gauge {
      id: cellGauge
      anchors.verticalCenter: parent.verticalCenter
      busy: cell.info.busy !== undefined ? cell.info.busy : 0
      clock: cell.info.clock !== undefined ? cell.info.clock : -1
      asleep: cell.asleep
      tint: root.accelTint(cell.deviceId)
      centerText: root.accelPercentText(cell.deviceId)
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, cell.width - cellGauge.width - cell.spacing)
      spacing: Style.space(2)

      // The label's colour already ties it to its trace in the graph; the
      // dash pattern lives only in the legend.
      Text {
        text: root.accelLabel(cell.deviceId)
        color: root.accelTint(cell.deviceId)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        font.letterSpacing: 1.2
      }

      Text {
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

    Text {
      width: Style.space(40)
      text: pair[0]
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }

    Text {
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
      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
    }

    Rectangle {
      height: parent.height
      width: Math.max(height, parent.width * splitBar.hard)
      radius: height / 2
      color: root.loadColor(splitBar.fraction)
      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  // Label and used / total on one line, the bar, then one dim detail line.
  component CapacityCell: Column {
    id: capacityCell

    property string label: ""
    property real fraction: 0
    property real softFraction: 0
    property string usedText: ""
    property string totalText: ""
    property string detail: ""

    spacing: Style.space(7)

    Item {
      width: capacityCell.width
      height: Math.max(cellLabel.implicitHeight, cellFigure.implicitHeight)

      Text {
        id: cellLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - cellFigure.implicitWidth - Style.space(8))
        text: capacityCell.label.toUpperCase()
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        font.letterSpacing: 1.2
        elide: Text.ElideRight
      }

      Row {
        id: cellFigure
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: capacityCell.usedText
          color: root.loadColor(capacityCell.fraction)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          Behavior on color { ColorAnimation { duration: 240 } }
        }

        Text {
          text: " / " + capacityCell.totalText
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

    Text {
      width: capacityCell.width
      text: capacityCell.detail
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
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

    Behavior on opacity { NumberAnimation { duration: 200 } }
    Behavior on start { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    Behavior on span { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
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

      Text {
        text: parent.parent.note
        visible: text !== ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        text: parent.parent.alert
        visible: text !== ""
        color: root.bar.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    Text {
      id: headValue
      text: parent.value
      visible: text !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      color: parent.valueColor
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true

      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }
}
