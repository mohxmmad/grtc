<div align="center">

# GRTC — Godot Realtime Collaboration

### Live addon for Godot 3.x

[![Godot](https://img.shields.io/badge/Godot-3.6-478CBF?style=flat&logo=godotengine)](https://godotengine.org)
[![RTC Server](https://img.shields.io/badge/RTC-Server-00ADD8?style=flat)](https://github.com/mohxmmad/rtc-server)
[![Live Sync](https://img.shields.io/badge/Live-WebSocket-010101?style=flat&logo=socketdotio)](https://github.com/mohxmmad/rtc-server)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)

**Clone the same repo. Login with GitHub. Edit together — live.**

*Session-authenticated rooms • File sync • Live Cube transforms • No save needed*

</div>

---

### 🎬 Live Demo

https://github.com/user-attachments/assets/39aa1a47-c7b4-43c0-8137-291a3cf76a1c

> Two Godot instances in the same `project:<hash>` room. Moving the **Cube** in `GRTC.tscn` on one instance streams instantly to the other.

---

## What it is

**GRTC** is a Godot editor addon that connects your project to **[RTC Server](https://github.com/mohxmmad/rtc-server)**.

*   **One room per repo** — the room ID is `project:<md5>` of the normalized git remote URL (`https://github.com/user/repo` without `.git`). Every clone joins the same room automatically, even with different GitHub accounts
*   **Live transforms** — moving a `Spatial` (like `Cube`) streams `live_node` `T|x,y,z|R|x,y,z|S|x,y,z` over WebSocket and applies directly to the edited scene in memory on the other editor
*   **File sync** — `file_created` / `file_updated` / `file_deleted` as base64, auto-applied with filesystem scan
*   **Unified log** — single ordered view `[hh:mm:ss] OUT/IN  event  path  scene→obj` for everything you sent and received
*   **Git in-editor** — `Push Changes` / `Pull Changes` via the stored GitHub token, no terminal

Godot 3.6 • GLES2 • `WebSocketClient` • `HTTPRequest` for OAuth

## Features

| Area | Details |
|------|---------|
| **Auth** | GitHub OAuth via RTC Server, session restore with `X-Session-ID`, `user://grtc_panel.cfg` |
| **Realtime** | `ws://server:8000/ws?session_id=...&room=project:<hash>&client=godot` — `auth`, `join`, `publish`, `sync_request`, `ping` |
| **Live** | Per-frame poll of `get_edited_scene_root()` transforms; no Save needed for moves. File poll 1000 ms for everything else |
| **UI** | Dock `DOCK_SLOT_RIGHT_UL` + toolbar `GRTC Sync` toggle, `ScrollContainer` + `GridContainer(2)`, unified live log with `Clear` / `Copy` |
| **Git** | `grtc_git_helper.gd` wraps `git -C` — init, remote, checkout `main`, add, commit, push/pull with `x-access-token` |

## Installation

1.  Copy `addons/grtc/` into your Godot 3 project `res://addons/grtc/`
2.  `Project → Project Settings → Plugins → GRTC → Enable`
3.  Dock appears on the right. Toolbar button **GRTC Sync** toggles it

**Requirements:** Godot 3.6+, Git installed, RTC Server running (`go run .` on `rtc-server`).

## Quick Start

```text
1. Start RTC Server
   go run .  # in rtc-server, PORT=8000, DATABASE_URL, GITHUB_* in .env
   curl http://localhost:8000/health # OK

2. In Godot (two instances, two clones of same repo)
   • Set Your Email
   • Login with GitHub → browser opens → approve → "Login synced"
   • Connect Collaboration → "Collaboration connected to project:<hash>"
   • Move Cube in GRTC.tscn on Instance A
   • Instance B: unified log shows  IN  live_node  GRTC.tscn:Cube  and Cube moves live
   • Edit a script or save a file → OUT file_updated → IN file_updated on the other

3. Git
   Push Changes / Pull Changes when you want to persist to GitHub (live is in-memory until then)
```

**Room:** No manual ID. Both clones share the same remote → same `project:<hash>` → same room. Check `Collab Room` field to verify.

## How it works

```
Godot A (Cube moved) → poll_live_scene() every frame → publish live_node {path, node_path, state}
        ↓ WebSocket room project:<hash> (RTC Server broadcasts)
Godot B → handle_remote_event → apply_live_node() → node.translation / rotation / scale → inspector updates → unified log IN
File save → scan_directory_recursive → publish file_updated base64 → other writes file + scan() + scan_sources()
```

## Project Structure

```
grtc/
├── addons/grtc/
│   ├── plugin.cfg          # GRTC 1.0
│   ├── plugin.gd           # EditorPlugin → dock + toolbar
│   ├── grtc_dock.gd        # ~1100 lines: UI, OAuth, WebSocket, live + file sync, unified log
│   └── grtc_git_helper.gd  # git -C wrapper
├── project.godot
├── GRTC.tscn               # demo scene with Cube
├── icon.png
└── default_env.tres
```

## UI

*   **Server URL / Your Email / Session ID / User ID / GitHub Username / Project Path / Repository URL / Collab Room** (read-only)
*   **Live Changes** — `0001 [23:44:22] OUT  live_node  GRTC.tscn:Cube  scene:GRTC.tscn  obj:Cube` in order
*   **Actions:** `Login with GitHub` `Connect` `Disconnect` `Refresh Files` `Open Repository` `Push Changes` `Pull Changes`

## Protocol

Shared with `rtc-server` and Unity client:

```json
{ "type": "publish", "room": "project:abc", "event": "live_node", "data": { "path": "GRTC.tscn", "node_path": "Cube", "state": "T:0,2,0|R:0,0,0|S:1,1,1" } }
{ "type": "publish", "room": "project:abc", "event": "file_updated", "data": { "path": "GRTC.tscn", "file_content": "base64..." } }
```

Presence: `GET /ws/online-users`, `GET /ws/user-status?user_id=`

## License

MIT — see `rtc-server/LICENSE` • **github.com/mohxmmad** • 2025-2026
