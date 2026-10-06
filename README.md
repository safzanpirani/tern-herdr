# tern-herdr

Herdr inside Tern, drawn by Tern itself. Herdr keeps the agents and terminals running; Tern shows them as native tabs, splits and a sidebar, and answers Herdr's prefix keys.

## Two views

**Tabs mirror** (`cmd+shift+m`, "Herdr: Toggle Tabs Mirror"). Every Herdr tab becomes a Tern tab and every Herdr pane a Tern split in it. Tabs are named after their space (`api`, `web · 2`) and colored by agent state: red is blocked, yellow is working, green is done. New Herdr tabs and panes appear within two seconds, and closed ones disappear. Closing a Tern tab only hides it; Herdr keeps the pane. Turning the mirror off closes the Tern tabs and leaves Herdr running.

**Sidebar** (`cmd+shift+h`, "Herdr: Open Sidebar"). A `herdr` tab with a native rail on the left (spaces with git branches, then agents by priority) and one terminal on the right that follows the agent you click.

## Herdr keys

The plugin reads `[keys]` from `~/.config/herdr/config.toml` over Herdr's defaults, and binds each `prefix+…` key as a Tern sequence: with prefix `ctrl+x`, `prefix+c` becomes `ctrl+x c`. The keys work only while a Herdr pane (mirrored or sidebar) has focus. Pressing the prefix twice sends the prefix to the program.

| Herdr action | Does |
|---|---|
| `new_tab`, `new_workspace` | `herdr tab create` / `herdr workspace create` in the current pane's space and directory, then focuses it |
| `split_vertical`, `split_horizontal` | `herdr pane split` right / down; the new pane appears as a Tern split on that side |
| `close_pane`, `close_tab`, `close_workspace` | closes it in Herdr; the mirror follows |
| `next_tab`, `previous_tab`, `switch_tab 1..9` | moves between the current space's tabs |
| `next_workspace`, `previous_workspace`, `switch_workspace 1..9` | moves between spaces |
| `next_agent`, `previous_agent` | cycles agents in space order |
| `focus_pane_left/down/up/right`, `cycle_pane_*`, `last_pane` | moves focus between Tern panes |
| `zoom`, `rename_tab` | Tern's zoom and rename |
| `workspace_picker`, `goto`, `toggle_sidebar` | opens the sidebar |
| `detach` | turns the tabs mirror off |

Herdr settings, help, resize mode, scrollback editing and worktrees aren't mapped.

## Also

- A toast appears when an agent turns blocked, or goes from working to done.
- "Herdr: Jump to Agent Needing Attention" (`cmd+shift+j`) shows the most urgent blocked or done agent.
- With `status_bar` on, the status line shows counts such as `herdr 1 blocked · 2 working`.

## How it works

- Each Tern pane runs `follow.sh`, which runs `herdr terminal attach <terminal_id>` for the terminal named in its target file under the plugin's data directory. To switch terminals, the plugin writes a new target and types `ctrl+b q`, which Herdr's direct attach always takes as detach. A failed attach is retried, because a hidden pane has no size yet and Herdr refuses a zero-sized grid.
- `window.luau` polls `herdr workspace/tab/pane list` every 2 s. It mirrors tabs and panes, registers the key sequences and calls the Herdr CLI for each action.
- `keymap.luau` turns Herdr's key specs into Tern sequences. For example, `prefix+shift+1..9` becomes `ctrl+x>shift+1` and `ctrl+x>!`, because terminals report shifted keys either way.
- `host.luau` is the sidebar block, styled by `sidebar.css`.
- `common.luau` finds the binaries, parses Herdr's JSON and holds the link helpers.

Requires Herdr with `herdr terminal attach` and Tern with plugin support.

## Install

```sh
tern plugin install github.com/safzanpirani/tern-herdr
```

Or clone it and run `tern plugin link .` to use it in place. Run `tern plugin types .` to write `tern.d.luau` for luau-lsp.

The plugin talks to the default Herdr session on this machine.
