# amux

An agent-first terminal multiplexer. Built with Zig and GTK4 on top of [Ghostty](https://ghostty.org)'s embedded terminal runtime.

amux gives AI coding agents what they've never had: **persistent terminal sessions they can observe and interact with asynchronously**. Instead of firing a command and waiting for stdout, an agent can send a command to a terminal pane, go do other work, come back and read the screen, respond to prompts, handle TUI dialogs, and monitor long-running processes — the way a human developer actually works.

## Why this exists

When an AI agent runs `ssh myserver` or `sudo apt upgrade` through a standard tool like Claude Code's Bash, it's stuck — blocked waiting for a process that needs interactive input. The command times out and the agent is helpless.

With amux, the agent sends the command to a terminal pane and reads the screen independently:

```bash
amux-cli send --enter "ssh myserver"        # fire and forget
amux-cli surface read-text                   # what's on screen?
amux-cli send --enter "yes"                  # respond to host key prompt
amux-cli surface read-text                   # connected!
amux-cli send --enter "sudo apt upgrade -y"  # start the upgrade
# ... go do other work in another pane ...
amux-cli surface read-text                   # check back later
```

This is the async observe-and-react model. The agent is never blocked.

## Features

- **42 socket API methods** — JSON-RPC over Unix socket (`/tmp/amux.sock`)
- **CLI tool** (`amux-cli`) — standalone binary, no runtime dependencies beyond libc
- **Split panes** — horizontal/vertical splits, resize, swap, navigate
- **Workspaces** — create, switch, rename, pin, color-code, close
- **Session persistence** — layout, titles, working directories survive restarts
- **Sidebar** — git branch, status metadata, progress bars, log entries
- **Command palette** — fuzzy search, keyboard shortcuts
- **Terminal search** — integrated with Ghostty's search engine
- **Shell integration** — bash/zsh scripts report git status to the sidebar
- **Claude Code integration** — automatic session tracking and sidebar status
- **Desktop notifications** — via libnotify
- **Synchronous dispatch** — all mutating operations return real success/error responses
- **Bash routing hook** — Claude Code `PreToolUse` hook that redirects interactive commands through amux

## Protocol compatibility

amux speaks the [cmux](https://cmux.dev) V2 socket protocol (newline-delimited JSON-RPC). The CLI commands, method names, and response formats are designed to stay compatible. If you have tools that work with cmux's socket API, they should work with amux.

## Quick start

### Prerequisites

- Linux (X11 or Wayland)
- Zig 0.14+
- GTK4 development files (`sudo apt install libgtk-4-dev`)
- libnotify development files (`sudo apt install libnotify-dev`)

### Build

```bash
git clone --recursive https://github.com/mattmorganpdx/amux.git
cd amux
./setup.sh      # builds the Ghostty library (takes a few minutes first time)
zig build        # produces zig-out/bin/amux and zig-out/bin/amux-cli
```

### Install

```bash
./install.sh     # copies amux and amux-cli to /usr/local/bin
```

### Run

```bash
amux             # launch the terminal
amux-cli ping    # verify the socket is up (from another terminal)
```

## CLI reference

```
amux-cli ping                              # check server is alive
amux-cli identify                          # show focused workspace/pane
amux-cli tree                              # full window/workspace/pane hierarchy

amux-cli send --enter "command"            # send text + Enter to focused pane
amux-cli send --surface 3 --enter "ls"     # target a specific pane
amux-cli surface read-text                 # read the terminal screen
amux-cli surface read-text --scrollback    # include scrollback buffer
amux-cli surface send-key ctrl-c           # send a keystroke
amux-cli surface split right               # create a split pane
amux-cli surface close                     # close focused pane

amux-cli workspace create "build"          # create a named workspace
amux-cli workspace list                    # list all workspaces
amux-cli workspace select <id>             # switch workspace
amux-cli workspace rename [<id>] <title>   # rename a workspace

amux-cli workspace set-progress <id> 0.5 "Building..."
amux-cli workspace set-status <id> task "compiling"
amux-cli workspace add-log <id> "Build succeeded"
amux-cli workspace report-git <id> main --dirty

amux-cli pane list                         # list all panes
amux-cli pane resize <id> right 0.2        # resize a split
amux-cli pane swap <a> <b>                 # swap two panes
amux-cli pane break <id>                   # detach pane to new workspace
amux-cli pane join <id> <workspace_id>     # move pane to workspace

amux-cli palette list                      # list command palette actions
amux-cli palette execute <action>          # execute an action

amux-cli notification create "Title" "Body"
amux-cli notification list
amux-cli notification clear
```

## Environment variables

Each terminal pane automatically gets:
- `AMUX_SURFACE_ID` — this pane's surface ID
- `AMUX_WORKSPACE_ID` — this pane's workspace ID
- `AMUX_SOCKET_PATH` — path to the amux socket

Socket path resolution: `AMUX_SOCKET` > `AMUX_SOCKET_PATH` > `/tmp/amux.sock`

## Architecture

- **Language:** Zig 0.14, `@cImport` for GTK4 and Ghostty C headers
- **UI:** GTK4 (GtkApplication, GtkGLArea, GtkPaned, GtkListBox, GtkStack)
- **Terminal:** Ghostty embedded apprt via `libghostty.so`
- **Ghostty fork:** [`mattmorganpdx/ghostty`](https://github.com/mattmorganpdx/ghostty) branch `matt/linux-embedded-apprt`
- **Socket:** Unix domain socket, newline-delimited JSON-RPC, thread-per-client
- **Build:** `zig build` produces `amux` (GUI) and `amux-cli` (socket client)

## Origin

amux started as a Linux port of [cmux](https://cmux.dev), a macOS terminal multiplexer by [manaflow-ai](https://github.com/manaflow-ai). During the port, we realized the socket API was exactly what AI coding agents need — persistent sessions, async interaction, observable terminal state. The project pivoted from "cmux on Linux" to "agent-first terminal multiplexer that speaks the cmux protocol."

Built by Matt Morgan and Claude.

## License

TBD
