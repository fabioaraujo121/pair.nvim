# pair.nvim

The Neovim side of [pair](https://pairwithagent.com): a coding agent that
narrates before it edits, points at the line in Neovim, draws the change
inside the real file, asks and waits for your spoken answer.

The `pair` binary drives this plugin over msgpack-rpc, one
`nvim_exec_lua` call per event:

| Call | Does |
| --- | --- |
| `require('pair').show(file, start, end)` | open the file in the editor window, jump, highlight the lines (`PairPointer`) |
| `require('pair').diff(file, marks)` | draw a change in place: added lines highlighted with `+` in the sign column, removed lines as virtual lines where they were |
| `require('pair').reload()` | `:checktime` without the "[O]K, (L)oad File" dialog |
| `require('pair').layout()` | the pairing layout: project tree on the left, one file on the right |

Everything that touches editor state lives here, in Lua.

## You probably do not need to install it

`pair` installs this plugin itself under `~/.pair/nvim` and puts it on the
runtime path of the Neovim it starts, so it always matches the binary.
Your own configuration still loads; when you have none, pair sets
sensible defaults and the `retrobox` colour scheme.

Install it from this repository when you want the keymaps in a Neovim
started outside pair, or to read the code:

```lua
-- lazy.nvim
{ 'fabioaraujo121/pair.nvim', opts = {} }
```

```lua
require('pair').setup({
  ttl = 20,          -- seconds before a pointer highlight clears (0 = never)
  diff_ttl = 120,    -- seconds a drawn change stays (0 = until the next one)
  hl = 'PairPointer',
  keymaps = true,    -- false: define no keymaps
  bin = 'pair',      -- the pair binary
})
```

## Keys and commands

| Key | Command | Does |
| --- | --- | --- |
| `<leader>pt` | `:PairListen` | push-to-talk: record until you pause, transcribe, send to the agent |
| `<leader>pi` | `:PairInterrupt` | interrupt the agent, then listen |
| `<leader>pp` (normal or visual) | `:PairPoint` | point the agent at these lines, with an optional note |
| `<leader>ps` | `:PairScratch` | show the scratchpad `.pair/PAIRING.md`, or go back |
| | `:PairClear` | clear the pointer highlight |

The keys run the `pair` binary; they do something only while a pair
session is running in the repository.

## Highlights

`PairPointer` (links to `Visual`), `PairAdd` (`DiffAdd`), `PairAddSign`
(`Added`), `PairDelete` (`DiffDelete`). All are defined with `default`, so
a colour scheme or your configuration can override them.

## How it stays out of your way

- Nothing on screen moves while you are typing, selecting or answering a
  prompt; the agent is told the engineer is busy.
- The pointer disappears as soon as you edit the pointed buffer.
- A file changed on disk is reloaded when the buffer is clean; a dirty
  buffer is kept, with a one-line notice. No modal dialogs, ever: a
  dialog would block the RPC and with it the whole session.

## Development

This repository is a mirror of the `nvim/` directory of
[fabioaraujo121/pair](https://github.com/fabioaraujo121/pair), published
on every change there. Open issues and pull requests in that repository.

MIT, see LICENSE.
