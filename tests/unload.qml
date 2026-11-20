// Session actions across a model being destroyed, run headless by
// tests/unload.sh (one case per run, CASE=1..7) with a stub herdr-sessions.
// Exits 0 on success, 1 on the first failed assert. Every wait is bounded.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: shell

  property string dir: Quickshell.env("TEST_DIR")
  property string which: Quickshell.env("CASE")
  property real mark: Date.now()
  property int step: 0
  property var steps: []
  property var m: null      // the model under test
  property var m2: null
  property var b1: null
  property var b2: null
  property string tok: ""

  Component {
    id: hostC
    QtObject {
      property bool opened: false
      property bool pinned: false
      property var activeCard: null
      property color foreground: "#cccccc"
      property color accent: "#33aaaa"
      property color urgent: "#aa3333"
      property string fontFamily: "monospace"
      function close() { opened = false }
    }
  }
  Component { id: modelC; HerdrModel { } }

  FileView { id: probe; blockLoading: true; printErrors: false }

  function exists(name) {
    probe.path = dir + "/" + name
    try { probe.reload(); return probe.text().length > 0 } catch (e) { return false }
  }
  function spawn(remote, opened) {
    var h = hostC.createObject(shell, { opened: opened })
    return modelC.createObject(shell, { remote: remote, host: h })
  }
  function unload(model) { tok = model.ownerToken; model.destroy() }
  function gone() { return HerdrActions.entry(tok) === null || HerdrActions.entry(tok).alive === false }
  function pending(kind) { return HerdrActions.unclaimed.menu[kind] }

  function fail(message) {
    console.error("FAIL case " + which + ": " + message + " (step " + step + ")")
    Qt.exit(1)
  }
  function check(cond, message) { if (!cond) { fail(message); return false } return true }

  // A step waits for `ready`, then runs `then`; each wait is bounded.
  function add(label, ready, then) { steps.push({ label: label, ready: ready, then: then }) }

  function tick() {
    if (step >= steps.length) return
    var s = steps[step]
    if (!s.ready()) {
      if (Date.now() - mark > 8000) fail("timed out waiting for " + s.label)
      return
    }
    if (s.then && s.then() === false) return
    step++
    mark = Date.now()
    if (step >= steps.length) { console.log("PASS: case " + which); Qt.exit(0) }
  }

  function always() { return true }
  function started(n) { return function () { return exists("started-" + n) } }
  function marker(n) { return function () { return exists("marker-" + n) } }
  function hasPending(kind) { return function () { return pending(kind) !== null } }

  Component.onCompleted: {
    var c = which
    if (c === "1") {
      add("model", always, function () { m = spawn(true, false); m.launch("focus", "", "s1", "", false) })
      add("run to start", started("focus-s1"), function () { unload(m) })
      add("unload", gone, null)
      add("the marker", marker("focus-s1"), null)
      add("the stored result", hasPending("action"), function () {
        var item = pending("action")
        return check(item.meta.actionName === "focus" && item.result.error === "focus boom",
          "unclaimed.menu.action holds the parsed result, got " + JSON.stringify(item))
      })
      add("slots released", function () { return HerdrActions.entry(tok) === null }, null)
    } else if (c === "2") {
      add("model", always, function () { m = spawn(true, false); m.launch("focus", "", "s1", "", false) })
      add("run to start", started("focus-s1"), function () { unload(m) })
      add("the stored result", hasPending("action"), function () {
        m2 = spawn(true, false)
        m2.host.opened = true
      })
      add("claim on open", function () { return m2.actionError !== "" }, function () {
        return check(m2.actionError === "focus boom" && pending("action") === null, "open must claim, got '" + m2.actionError + "'")
      })
    } else if (c === "3") {
      add("model", always, function () { m = spawn(true, false); m.launch("focus", "", "s1", "", false) })
      add("run to start", started("focus-s1"), function () {
        unload(m)
        m2 = spawn(true, true)
      })
      add("claim on unclaimedChanged", function () { return m2.actionError !== "" }, function () {
        return check(m2.actionError === "focus boom" && pending("action") === null, "got '" + m2.actionError + "'")
      })
    } else if (c === "4") {
      add("model", always, function () {
        m = spawn(true, false)
        m.launch("kill", "", "s1", "", false)
        m.launch("focus", "", "s1", "", false)
      })
      add("both to start", function () { return exists("started-kill-s1") && exists("started-focus-s1") }, function () { unload(m) })
      add("both stored", function () { return pending("action") !== null && pending("kill") !== null }, function () {
        m2 = spawn(true, false)
        m2.host.opened = true
      })
      add("claim", function () { return m2.actionError !== "" }, function () {
        return check(m2.actionError === "kill went wrong", "the kill error must survive, got '" + m2.actionError + "'")
      })
    } else if (c === "5") {
      add("model", always, function () {
        m = spawn(true, false)
        m.appLaunch(["app-kill", "p1", "k1"], "kill", false, "k", true, { session: { name: "s" }, agent: { pane: "p1" } })
      })
      add("run to start", started("app-kill-p1"), function () { unload(m) })
      add("stored", hasPending("kill"), function () {
        m2 = spawn(true, false)
        m2.host.opened = true
      })
      add("claim", function () { return m2.actionError !== "" }, function () {
        return check(m2.actionError === "the agents to end changed; press the key again" && !m2.confirmOpen,
          "got '" + m2.actionError + "' confirmOpen=" + m2.confirmOpen)
      })
    } else if (c === "6") {
      add("model", always, function () {
        m = spawn(true, false)
        HerdrActions.start(m.ownerToken, "action", ["/nonexistent/herdr-sessions"],
          { pendingKey: "k", actionName: "new", actionDismiss: false })
        // Unregister in the same tick, before the failed start is reported;
        // destroy() alone is deferred and could lose that race.
        HerdrActions.unregister(m.ownerToken)
        unload(m)
      })
      add("stored", hasPending("action"), function () {
        var item = pending("action")
        if (!check(!item.result.ok && item.result.error === "could not start herdr-sessions", "got " + JSON.stringify(item))) return false
        m2 = spawn(true, false)
        m2.host.opened = true
      })
      add("claim", function () { return m2.actionError !== "" }, function () {
        return check(m2.actionError === "could not start herdr-sessions", "got '" + m2.actionError + "'")
      })
    } else if (c === "7") {
      // An orphaned menu run stays unclaimed while open bar models finish theirs.
      add("orphan", always, function () { m = spawn(true, false); m.launch("focus", "", "o", "", false) })
      add("orphan to start", started("focus-o"), function () {
        unload(m)
        b1 = spawn(false, true)
        b2 = spawn(false, true)
        m2 = spawn(true, false)
        b1.launch("focus", "", "x1", "", false)
        b2.launch("focus", "", "x2", "", false)
        m2.launch("focus", "", "x3", "", false)
        if (b1.launch("focus", "", "y", "", false)) return fail("a second start in a busy slot must be refused")
        if (!check(b1.actionError === "busy: focus is still running", "busy message, got '" + b1.actionError + "'")) return false
        return check(b1.pendingKey === b1.sessionKey({ host: "", name: "x1" }), "pending key while running, got '" + b1.pendingKey + "'")
      })
      add("all runs done", function () {
        return exists("marker-focus-o") && exists("marker-focus-x1") && exists("marker-focus-x2") && exists("marker-focus-x3")
          && !HerdrActions.slot(b1.ownerToken, "action").open && !HerdrActions.slot(b2.ownerToken, "action").open
          && !HerdrActions.slot(m2.ownerToken, "action").open && pending("action") !== null
      }, function () {
        return check(b1.actionError === "note-x1" && b2.actionError === "note-x2" && m2.actionError === "note-x3",
            "each result must reach its own model: '" + b1.actionError + "' '" + b2.actionError + "' '" + m2.actionError + "'")
          && check(pending("action").result.error === "orphan err", "bars must not claim the menu result")
          && check(b1.pendingKey === "", "pending key cleared after the run, got '" + b1.pendingKey + "'")
      })
    }
  }

  Timer { interval: 25; running: true; repeat: true; onTriggered: shell.tick() }
}
