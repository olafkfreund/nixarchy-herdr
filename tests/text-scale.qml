// Text size across two models sharing one size file, run headless by
// tests/text-scale.sh with a fake hc. Exits 0 on success, 1 on the first
// failed assert. Every wait is bounded by an assertion.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: shell

  property string dir: Quickshell.env("TEST_DIR")
  property bool withDir: Quickshell.env("CASE") === "dir"
  property string file: dir + "/cache/omarchy-herdr/text-scale"
  property real mark: Date.now()
  property int phase: 0

  HerdrModel { id: a; remote: false }
  HerdrModel { id: b; remote: false }

  Process { id: shellCmd; running: false }

  function run(cmd) { shellCmd.command = ["bash", "-c", cmd]; shellCmd.running = true }
  function fail(message) {
    console.error("FAIL: " + message + " (a=" + a.textScale + " b=" + b.textScale + ")")
    Qt.exit(1)
  }
  function next() { phase++; mark = Date.now() }
  function waited() { return Date.now() - mark }

  function tick() {
    if (phase === 0) {
      if (waited() < 500) return
      a.textBigger()
      next()
    } else if (phase === 1) {
      if (waited() < 800) return
      if (a.textScale !== 1.1) return fail("a step must hold the size for the session")
      if (!withDir) {
        // The path is blocked: nothing is written and the other model does not change.
        if (b.textScale !== 1.0) return fail("with an unwritable path, the other model must not change")
        console.log("PASS: size file: an unwritable path keeps the size for this session only")
        Qt.exit(0)
        return
      }
      next()
    } else if (phase === 2) {
      a.textBigger()
      next()
    } else if (phase === 3) {
      // With the directory, a step in one model reaches the other.
      if (b.textScale === 1.2) { next(); return }
      if (waited() > 3000) fail("a step did not reach the other model")
    } else if (phase === 4) {
      shell.run("printf banana > '" + file + "'")
      next()
    } else if (phase === 5) {
      // Garbage is ignored by both.
      if (waited() < 800) return
      if (a.textScale !== 1.2 || b.textScale !== 1.2) return fail("a garbage file must be ignored")
      a.textReset()
      next()
    } else if (phase === 6) {
      if (b.textScale === 1.0) { next(); return }
      if (waited() > 3000) fail("reset did not reach the other model")
    } else if (phase === 7) {
      for (var i = 0; i < 5; i++) a.textBigger()
      next()
    } else if (phase === 8) {
      // Five rapid presses converge on both, with none lost.
      if (a.textScale !== 1.5) return fail("five rapid steps lost one in the pressing model")
      if (b.textScale === 1.5 && waited() > 500) {
        console.log("PASS: size file: shared via the file, garbage ignored, rapid steps converge")
        Qt.exit(0)
      }
      if (waited() > 3000) fail("rapid steps did not converge on the other model")
    }
  }

  Timer { interval: 25; running: true; repeat: true; onTriggered: shell.tick() }
}
