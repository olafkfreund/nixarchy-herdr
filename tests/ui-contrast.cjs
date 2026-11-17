// U3: every dimmed foreground in the QML is a Qt.alpha from the plan's table,
// and each one keeps WCAG contrast on a dark and a light theme.
// Fixtures are copied from the installed Omarchy themes:
//   outpost (dark)  ~/.config/omarchy/themes/outpost/colors.toml
//   haven   (light) ~/.config/omarchy/themes/haven/colors.toml
// The card and menu backgrounds are the theme background (the shell's
// Color.menu.background and popups.background are derived from it).
const fs = require("fs"), path = require("path")
const root = path.join(__dirname, "..")
const files = ["Card.qml", "Menu.qml", "Panel.qml", "HerdrModel.qml"]
// Raised from the first U3 table (.83 .77 .71 .67 .62 .59 .56 .53 .48 .45) so
// the light theme passes; strictly descending, so dimmer stays dimmer.
const table = [0.97, 0.94, 0.91, 0.88, 0.85, 0.82, 0.80, 0.78, 0.68, 0.62]
const strong = 0.78 // the eight brightest steps need 4.5, the two faintest 3
const themes = {
  outpost: { fg: "#e8dfc4", bg: "#14282d", accent: "#d3ae78" },
  haven: { fg: "#263D40", bg: "#EEE8DA", accent: "#795334" },
}

let failed = 0
const fail = (m) => { console.error("FAIL: " + m); failed++ }

const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
const mix = (a, b, t) => a.map((v, i) => v * t + b[i] * (1 - t))
const lum = (c) => {
  const [r, g, b] = c.map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)))
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
const ratio = (x, y) => {
  const [a, b] = [lum(x), lum(y)].sort((p, q) => q - p)
  return (a + 0.05) / (b + 0.05)
}

const used = new Set()
for (const f of files) {
  const src = fs.readFileSync(path.join(root, f), "utf8")
  src.split("\n").forEach((line, i) => {
    if (/Qt\.darker\(/.test(line) && /foreground/.test(line)) fail(`${f}:${i + 1} Qt.darker on a foreground`)
    for (const m of line.matchAll(/Qt\.alpha\([^,]*?foreground[^,]*,\s*([0-9.]+)\s*\)/g)) {
      const a = parseFloat(m[1])
      if (!table.includes(a)) fail(`${f}:${i + 1} alpha ${m[1]} is not in the U3 table`)
      used.add(a)
    }
  })
}
if (used.size === 0) fail("no Qt.alpha(foreground, n) found")

for (const [name, t] of Object.entries(themes)) {
  const fg = rgb(t.fg), bg = rgb(t.bg), acc = rgb(t.accent)
  const backgrounds = {
    card: bg,
    menu: bg,
    "selected-row wash (fg 0.08)": mix(fg, bg, 0.08),
    "accent tint (0.13, a lit row)": mix(acc, bg, 0.13),
  }
  for (const a of used) {
    const need = a >= strong ? 4.5 : 3
    for (const [bn, b] of Object.entries(backgrounds)) {
      const r = ratio(mix(fg, b, a), b)
      if (r < need) fail(`${name} alpha ${a} on ${bn}: ${r.toFixed(2)} < ${need}`)
    }
  }
}

if (failed) process.exit(1)
console.log("PASS: ui-contrast (" + [...used].sort().join(", ") + ")")
