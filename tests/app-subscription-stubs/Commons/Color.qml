// Shape only: just what HerdrModel binds, so it can load outside the shell.
pragma Singleton
import QtQuick

QtObject {
  readonly property color accent: "#33aaaa"
  readonly property color urgent: "#aa3333"
  readonly property color foreground: "#cccccc"
  function pick(key, fallback) { return fallback }
  function flatColor(value, fallback) { return fallback }
}
