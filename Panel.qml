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

import QtQuick
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
  property real swapUsedGb: 0
  property real swapTotalGb: 0

  property string loadAverage: ""
  property string cpuModel: ""

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

  function parse(text) {
    var lines = String(text).split("\n")
    var memTotalKb = -1
    var memAvailableKb = -1
    var swapTotalKb = -1
    var swapFreeKb = -1

    var nextCoreBusy = {}
    var nextCoreTotal = {}
    var cores = []

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
      }
    }

    root.prevCoreBusy = nextCoreBusy
    root.prevCoreTotal = nextCoreTotal
    // Only publish once there is a previous sample to diff against, so the
    // grid does not flash a row of zeroes on the first tick.
    if (cores.length > 0 && (root.coreLoads.length > 0 || root.prevTotal >= 0)) root.coreLoads = cores

    if (memTotalKb > 0 && memAvailableKb >= 0) {
      root.memTotalGb = gb(memTotalKb)
      root.memAvailableGb = gb(memAvailableKb)
      root.memUsedGb = gb(memTotalKb - memAvailableKb)
      root.memFraction = Math.max(0, Math.min(1, (memTotalKb - memAvailableKb) / memTotalKb))
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
      "grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo; " +
      "echo \"loadavg $(cat /proc/loadavg)\"; " +
      "echo \"uptime $(cut -d' ' -f1 /proc/uptime)\"; " +
      "echo \"disk $(df -B1 --output=size,used " + Util.shellQuote(root.diskMount) + " | tail -1)\"; " +
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
    fixedWidth: vertical ? -1 : root.meterWidth * 2 + root.meterGap + Style.space(14)
    fixedHeight: vertical ? root.meterWidth * 2 + root.meterGap + Style.space(14) : -1
    onPressed: root.toggle()

    Grid {
      anchors.centerIn: parent
      columns: button.vertical ? 1 : 2
      rows: button.vertical ? 2 : 1
      columnSpacing: root.meterGap
      rowSpacing: root.meterGap

      Meter { fraction: root.cpuLoad; settleMs: 180 }
      Meter { fraction: root.memFraction; settleMs: 320 }
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
        spacing: Style.space(14)

        PanelHero {
          title: "Processor"
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
        Canvas {
          id: sparkline
          width: parent.width
          height: Style.space(46)

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
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

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
            readonly property real blockHeight: root.coreRows > 1 ? Style.space(20) : Style.space(30)

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

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Memory ----------
        // Headline percentage on the header line, the bar full width beneath
        // it, and the supporting figures spread across the row rather than
        // stacked as a label/value table — three short facts do not need
        // three lines, and the table left most of the width empty.
        Column {
          width: parent.width
          spacing: Style.space(9)

          SectionHead {
            title: "MEMORY"
            value: Math.round(root.memFraction * 100) + "%"
            valueColor: root.loadColor(root.memFraction)
          }

          UsageBar { fraction: root.memFraction }

          StatRow {
            Stat { label: "USED"; value: root.memUsedGb.toFixed(1) + " / " + root.memTotalGb.toFixed(1) + " GB" }
            Stat { label: "FREE"; value: root.memAvailableGb.toFixed(1) + " GB" }
            Stat {
              label: "SWAP"
              value: root.swapTotalGb > 0 ? root.swapUsedGb.toFixed(1) + " GB" : "none"
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Storage ----------
        Column {
          width: parent.width
          spacing: Style.space(9)

          SectionHead {
            title: "STORAGE"
            value: Math.round(root.diskFraction * 100) + "%"
            valueColor: root.loadColor(root.diskFraction)
          }

          UsageBar { fraction: root.diskFraction }

          StatRow {
            Stat {
              label: root.diskMount.toUpperCase()
              value: root.diskUsedGb.toFixed(0) + " / " + root.diskTotalGb.toFixed(0) + " GB"
            }
            Stat { label: "READ";  value: "↓ " + root.rateText(root.readBytesPerSec) }
            Stat { label: "WRITE"; value: "↑ " + root.rateText(root.writeBytesPerSec) }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Button {
          width: parent.width
          iconText: ""
          iconSize: Style.font.title
          text: "Open btop"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          onClicked: root.openBtop()
        }
      }
    }
  }

  // Horizontal fill bar shared by the memory and storage columns.
  component UsageBar: Item {
    property real fraction: 0

    width: parent ? parent.width : 0
    implicitHeight: Style.space(8)

    Rectangle {
      id: track
      anchors.fill: parent
      radius: height / 2
      color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
    }

    Rectangle {
      anchors.left: track.left
      anchors.verticalCenter: track.verticalCenter
      height: track.height
      width: Math.max(height, track.width * Math.max(0, Math.min(1, parent.fraction)))
      radius: height / 2
      color: root.loadColor(parent.fraction)

      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  // Section header with a headline figure on the trailing edge. Reuses
  // PanelSectionHeader for the label so the small-caps treatment matches
  // every other panel in the shell.
  component SectionHead: Item {
    property string title: ""
    property string value: ""
    property color valueColor: root.bar.foreground

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

  // Equal-width cells across the full panel width. Reading down a column of
  // labels beats reading across a sparse two-column table, and it fills the
  // space a right-aligned value list wasted.
  // An Item rather than a Row: the cells are placed by hand so they divide
  // the panel evenly, and Row derives implicitHeight from its children,
  // making it read-only.
  component StatRow: Item {
    width: parent ? parent.width : 0
    implicitHeight: childrenRect.height

    onWidthChanged: layoutCells()
    onChildrenChanged: layoutCells()
    Component.onCompleted: layoutCells()

    function layoutCells() {
      var cells = children
      if (cells.length === 0 || width <= 0) return
      var cellWidth = width / cells.length
      for (var i = 0; i < cells.length; i++) {
        cells[i].x = i * cellWidth
        cells[i].y = 0
        cells[i].width = cellWidth
      }
    }
  }

  // One figure: a dim small-caps label over its value.
  component Stat: Column {
    property string label: ""
    property string value: ""

    spacing: Style.space(3)

    Text {
      text: parent.label
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      elide: Text.ElideRight
      width: parent.width
    }

    Text {
      text: parent.value
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: parent.width
    }
  }
}
