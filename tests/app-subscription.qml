// The model's subscription wiring, run headless by tests/app-subscription.sh
// with a fake `hc` and a stub script. Exits 0 on success, 1 on the first
// failed assert.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: shell

  property string dir: Quickshell.env("TEST_DIR")
  property real t0: Date.now()
  property int phase: 0
  property real firstListAt: 0
  property int lastStarts: 0
  property var startAt: ({})
  property bool sawStale: false

  HerdrModel {
    id: m
    remote: false
    appCoalesceMs: 100
    appWatchdogMs: 1500
    appBackoffMs: 200
  }

  FileView { id: runLog; path: shell.dir + "/app-list-runs"; blockLoading: true; printErrors: false }
  FileView { id: startLog; path: shell.dir + "/hc-starts"; blockLoading: true; printErrors: false }

  function count(view) {
    try { view.reload(); return view.text().split("\n").filter(function (l) { return l !== "" }).length }
    catch (e) { return 0 }
  }

  function fail(message) {
    console.error("FAIL: " + message + " (runs=" + count(runLog) + " starts=" + count(startLog)
                  + " stale=" + m.appStale + " hcAvailable=" + m.hcAvailable + ")")
    Qt.exit(1)
  }

  function tick() {
    var elapsed = Date.now() - t0
    var runs = count(runLog), starts = count(startLog)
    if (starts !== lastStarts) { startAt[starts] = Date.now(); lastStarts = starts }
    if (firstListAt === 0 && m.appSessions.length > 0) firstListAt = elapsed
    if (phase === 0) {
      // 1. One burst, one app-list, well within 500 ms of it.
      if (elapsed < 1000) return
      if (starts !== 1) return fail("the subscription did not start exactly once")
      if (runs !== 1) return fail("a burst must give exactly one app-list run")
      if (m.appStale || !m.hcAvailable) return fail("a live subscription must not be stale")
      if (firstListAt === 0 || firstListAt > 500)
        return fail("the first app-list must complete within 500 ms (took " + firstListAt + ")")
      phase = 1
    } else if (phase === 1) {
      // 2. Silence: the watchdog marks it stale and the fake is started again.
      if (m.appStale) phase = 2
      else if (elapsed > 4000) fail("the watchdog never fired")
    } else if (phase === 2) {
      if (starts >= 2) phase = 3
      else if (elapsed > 4000) fail("the subscription was not restarted")
    } else if (phase === 3) {
      // 3. The restart's snapshot and one app-list clear it.
      if (runs >= 2 && !m.appStale) phase = 4
      else if (elapsed > 6000) fail("a good app-list after the restart did not clear stale")
    } else if (phase === 4) {
      // 4. The fake then exits normally: hc is still available, and it restarts.
      // This also proves onExited is handled before runningChanged.
      if (m.appStale) sawStale = true
      if (starts >= 3) {
        if (!m.hcAvailable) return fail("a normal exit must not read as no hc")
        if (!sawStale) return fail("an exited subscription must read as stale")
        // The fake exits 0.8 s in. The watchdog (1500 ms) would restart no sooner than 1700 ms.
        var gap = startAt[3] - startAt[2]
        if (gap > 1400) return fail("the restart came from the watchdog, not the exit (" + gap + " ms)")
        console.log("PASS: coalescing, watchdog, restart, stale cleared, exit restarts")
        Qt.exit(0)
      } else if (elapsed > 9000) fail("a clean exit did not restart the subscription")
    }
  }

  Timer { interval: 25; running: true; repeat: true; onTriggered: shell.tick() }
}
