---
status: draft
issue: 21
author: olafkfreund
---

# Intent: bring in upstream's umask and new-shell badge fixes

Closes #21. This is the second of four issues from the 2026-11-16 review. #20
(robustness, PR #24) comes before it, #22 (herdr-core/herdr-app) and #23 (UI
pass) after it.

## Problem

Upstream (jankeesvw/omarchy-herdr) has fixed things since our last sync at
`49fca4a`. #21 named four commits. Checked against current `origin/master`
(`affd985`), two still apply:

- **Terminals we open get a private umask** (`73b6605` upstream).
  - `bin/herdr-sessions` sets `umask 077` (`:39`) for its own files, and the
    terminal it opens for `open`, `focus` and `new` inherits it.
  - If that session's server isn't running, herdr starts it from that
    terminal, so every shell in the session gets 077. Files a git checkout
    creates there are unreadable by anyone else, including a container
    running as another user.
- **The bar count shrinks to a smudge on the new Omarchy shell** (`b00a6ca`
  upstream).
  - The shell now scales whatever a widget hands it as `iconComponent` down
    to one bar icon. `Panel.qml:184` hands it the glyph and the count badge
    together, so the count shrinks with it.
  - This machine runs Omarchy `edge-20261115`, which is past that shell
    change. I haven't confirmed the smudge on screen; the live check does.

**Already covered, so not part of #21:**

- **`4513202` `Commons.Color`:** done on master as #19 (`affd985`). This
  machine runs Qt 6.12.0.
- **`b4dceeb` (snapshots to jq on stdin):**
  - Our script already hands snapshots to jq through files. That's the fork's
    own fix, before upstream's.
  - #20 moves the last large `--arg` (the prompt screen) to stdin.
- **`448fdd1`, `ff66115`, `d0df5ea` (remotes through `herdr --machine`):**
  skipped on purpose. Decided 2026-11-16: keep `herdr.json` + ssh, which lists
  every session on each host.

**Not in #21:** upstream's herdr-app support (`c22668d`, `8634049`,
`83007e3`, merged as upstream PR #18). It is input for #22.

## Proposed outcome

- **A terminal opened by the plugin gets the umask the shell started the
  plugin with.** Files created in its sessions are readable as they would be
  from any other terminal. The script's own files and run directory stay
  private (077).
- **On the current Omarchy shell, the bar shows the server count at its
  normal size,** next to the glyph, with the same colours and badge as now.
- **Upstream's history records the sync.** A `merge -s ours` of upstream at
  `b00a6ca` marks the four commits, and the three skipped remote commits, as
  handled. The herdr-app commits after it stay unmerged until #22.

## Affected users and systems

- **Users:** everyone using the bar widget on the new shell, and anyone whose
  sessions start from a terminal the plugin opened.
- **Files:** `bin/herdr-sessions` (umask, around the launch in
  `show_session`), `Panel.qml` (the bar button), the README if it describes
  the bar, `manifest.json`.
- **Hosts:** p620 and razer, through the nixarchy pin bump.

## Constraints

- **Wait for #20.** PR #24 rewrites the launch in `show_session` (the
  launcher check) and is not merged yet. #21's script change goes on top of
  it, so implementation starts after #24 merges. The intent and spec can go
  ahead now.
- **Keep the badge's look.** The colours, the badge ratios, `barForeground`
  for the glyph, and the "no tint when open" rule all stay as they are.
- **Port, don't redesign.** Visual changes are #23's.
- **Merge with a merge commit.**

## Open questions

1. **Upstream history.** Record the sync with `git merge -s ours` at
   `b00a6ca`, as #11 did? Recommendation: yes, at `b00a6ca` exactly, so the
   herdr-app commits stay visible as unmerged for #22.
