pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
  id: root
  // One entry per registered HerdrModel: {token, remote, alive, action, kill}.
  property var owners: []
  property int nextToken: 0
  property var unclaimed: ({ menu: { action: null, kill: null } })
  signal finished(var owner, string kind, var meta, var result)

  Component {
    id: processSlot
    Process {
      id: proc
      property string owner: ""
      property string kind: ""
      property var meta: ({})
      property bool open: false
      property string out: ""
      property int code: 0
      property bool gotOut: false
      property bool gotExit: false
      stdout: StdioCollector {
        onStreamFinished: root.storeResult(proc, "out", text)
      }
      onExited: function (exitCode) { root.storeResult(proc, "exit", exitCode) }
      // Quickshell may clear running after both signals arrived, so an
      // orphaned pair is released here as well as in finishRun.
      onRunningChanged: if (!running) { root.startFailed(proc); root.releaseOwner(proc.owner) }
    }
  }

  function entry(owner) {
    for (var i = 0; i < owners.length; i++)
      if (owners[i].token === owner) return owners[i]
    return null
  }

  // Tokens are strings: a JS object passed through a var signal argument
  // is not guaranteed to keep its identity.
  function register(remote) {
    var owner = "owner-" + (++nextToken)
    var pair = { token: owner, remote: remote === true, alive: true,
      action: processSlot.createObject(root, { owner: owner, kind: "action" }),
      kill: processSlot.createObject(root, { owner: owner, kind: "kill" }) }
    owners.push(pair)
    return owner
  }

  function release(pair) {
    if (owners.indexOf(pair) < 0) return
    if (pair.alive || pair.action.running || pair.action.open || pair.kill.running || pair.kill.open) return
    pair.action.destroy()
    pair.kill.destroy()
    owners.splice(owners.indexOf(pair), 1)
  }

  function releaseOwner(owner) {
    var pair = entry(owner)
    if (pair) release(pair)
  }

  function unregister(owner) {
    var pair = entry(owner)
    if (!pair) return
    pair.alive = false
    release(pair)
  }

  function slot(owner, kind) {
    var pair = entry(owner)
    return pair ? pair[kind] : null
  }

  function start(owner, kind, command, meta) {
    var proc = slot(owner, kind)
    if (!proc || proc.running || proc.open) return false
    proc.meta = meta
    proc.gotOut = false
    proc.gotExit = false
    proc.open = true
    proc.command = command
    proc.running = true
    return true
  }

  function storeResult(proc, which, value) {
    if (which === "out") { proc.out = value; proc.gotOut = true }
    else { proc.code = value; proc.gotExit = true }
    if (!proc.gotOut || !proc.gotExit) return
    finishRun(proc, proc.out, proc.code)
  }

  function startFailed(proc) {
    if (!proc.open) return
    finishRun(proc, JSON.stringify({ ok: false, error: "could not start herdr-sessions" }), -1)
  }

  function parseResult(kind, out, code, meta) {
    var data = null
    try { data = JSON.parse(out) } catch (e) { data = null }
    var ok = data !== null && data.ok === true && code === 0
    var action = kind === "kill" ? "kill" : meta.actionName
    return {
      ok: ok,
      note: ok && data.note ? String(data.note) : "",
      error: ok ? "" : data && data.error ? String(data.error)
        : code !== 0 ? "herdr-sessions exited with code " + code
        : data ? action + " failed" : "unexpected output from herdr-sessions",
      changed: data && data.changed === true,
      cascade: data && data.cascade || [],
      cascadeKey: data && String(data.cascadeKey || "") || "",
      code: code
    }
  }

  function finishRun(proc, out, code) {
    if (!proc.open) return
    proc.open = false
    proc.gotOut = false
    proc.gotExit = false
    var meta = proc.meta
    var result = parseResult(proc.kind, out, code, meta)
    proc.meta = ({})
    var pair = entry(proc.owner)
    if (pair && pair.alive) finished(proc.owner, proc.kind, meta, result)
    else if (pair && pair.remote) {
      var menu = { action: unclaimed.menu.action, kill: unclaimed.menu.kill }
      menu[proc.kind] = { meta: meta, result: result }
      unclaimed = { menu: menu }
    }
    if (pair) release(pair)
  }

  function claimMenu() {
    var taken = unclaimed.menu
    // Reassigning when empty would fire unclaimedChanged, which claims again.
    if (!taken.action && !taken.kill) return taken
    unclaimed = { menu: { action: null, kill: null } }
    return taken
  }
}
