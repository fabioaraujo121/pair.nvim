-- pair.nvim: the Neovim side of `pair`.
--
-- The Go binary drives this module over msgpack-rpc with a single
-- nvim_exec_lua call per event:
--   require('pair').show(file, start_line, end_line)  -- jump + highlight
--   require('pair').reload()                          -- :checktime
-- Everything that touches editor state lives here, in Lua, so the Go side
-- only needs Dial/ExecLua from neovim/go-client.

local M = {}
local api = vim.api
local uv = vim.uv or vim.loop

local ns = api.nvim_create_namespace('pair')
local augroup = api.nvim_create_augroup('pair', { clear = true })

M.opts = {
  -- seconds before a `show` highlight clears on its own (0 = never)
  ttl = tonumber(vim.env.PAIR_HIGHLIGHT_TTL) or 20,
  -- highlight group used for "Claude is pointing here"
  hl = 'PairPointer',
  -- set to false to define no keymaps
  keymaps = true,
  -- the pair binary; `pair start` sets vim.g.pair_bin to its own path
  bin = vim.g.pair_bin or 'pair',
}

local state = { buf = nil, timer = nil }

local function ensure_hl()
  -- `default = true` lets a colorscheme or the user override it.
  api.nvim_set_hl(0, M.opts.hl, { link = 'Visual', default = true })
end

-- Clear the pointer highlight and its TTL timer.
function M.clear()
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then state.timer:close() end
    state.timer = nil
  end
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  end
  state.buf = nil
end

-- Pick the window that shows regular files: not the scratchpad, not a tree
-- or terminal. Falls back to the current window.
local function editor_win()
  local function usable(win)
    if not api.nvim_win_is_valid(win) then return false end
    local buf = api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= '' then return false end
    if api.nvim_buf_get_name(buf):match('PAIRING%.md$') then return false end
    return true
  end
  local cur = api.nvim_get_current_win()
  if usable(cur) then return cur end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  return cur
end

-- Jump to `file` (absolute path) at line `s`, highlight lines s..e, and
-- return what was shown. Never prompts: swapfile ATTENTION is silenced by
-- shortmess+=A in setup().
function M.show(file, s, e)
  s = tonumber(s) or 1
  e = tonumber(e) or s
  if e < s then e = s end

  local win = editor_win()
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if api.nvim_win_get_buf(win) ~= buf then
    api.nvim_win_set_buf(win, buf)
  end
  api.nvim_set_current_win(win)

  local last = api.nvim_buf_line_count(buf)
  if s > last then s = last end
  if e > last then e = last end
  if s < 1 then s = 1 end

  api.nvim_win_set_cursor(win, { s, 0 })
  api.nvim_win_call(win, function() vim.cmd('normal! zz') end)

  M.clear()
  ensure_hl()
  -- One mark per line: line_hl_group is guaranteed to cover exactly these
  -- rows, whatever the multi-line extmark semantics of the running Neovim.
  for row = s - 1, e - 1 do
    api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = M.opts.hl, priority = 200 })
  end
  state.buf = buf

  if M.opts.ttl and M.opts.ttl > 0 then
    state.timer = uv.new_timer()
    state.timer:start(M.opts.ttl * 1000, 0, vim.schedule_wrap(M.clear))
  end
  vim.cmd('redraw')
  return { file = api.nvim_buf_get_name(buf), start = s, ['end'] = e }
end

-- Reload buffers whose file changed on disk. Safe against the modal
-- "[O]K, (L)oad File" dialog thanks to the FileChangedShell autocmd below.
function M.reload()
  vim.cmd('silent! checktime')
  return true
end

-- Run a pair voice command asynchronously and show its result.
local function run_pair(args, label)
  vim.notify('pair: ' .. label, vim.log.levels.INFO)
  local cmd = { M.opts.bin }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
    local out = vim.trim(res.stdout or '')
    if res.code ~= 0 then
      vim.notify('pair: ' .. label .. ' failed: ' .. vim.trim(res.stderr or ''), vim.log.levels.WARN)
    elseif out ~= '' then
      vim.notify('pair: ' .. out, vim.log.levels.INFO)
    end
  end))
end

-- Push-to-talk: record until you pause, transcribe, send to Claude.
function M.listen()
  run_pair({ 'hook', 'listen' }, 'listening… (speak, then pause)')
end

-- Interrupt Claude (Escape), then listen.
function M.interrupt()
  run_pair({ 'hook', 'interrupt' }, 'interrupting… (speak, then pause)')
end

-- Repository root: set by `pair start`, else found from the scratchpad.
local function repo_root()
  if vim.g.pair_root and vim.g.pair_root ~= '' then return vim.g.pair_root end
  local found = vim.fs.find({ 'PAIRING.md', '.git' }, { upward = true, path = vim.fn.getcwd() })[1]
  if found then return vim.fs.dirname(found) end
  return vim.fn.getcwd()
end

-- Point Claude at the visual selection (or the current line): asks for an
-- optional note, then types "Look at file:start-end: note" into the Claude
-- pane. With a note the message is submitted; without one it is left in
-- the input so you can keep typing.
function M.point()
  local mode = vim.fn.mode()
  local s, e
  if mode == 'v' or mode == 'V' or mode == '\22' then
    s, e = vim.fn.line('v'), vim.fn.line('.')
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  else
    s, e = vim.fn.line("'<"), vim.fn.line("'>")
    if s == 0 or e == 0 then s, e = vim.fn.line('.'), vim.fn.line('.') end
  end
  if s > e then s, e = e, s end
  local file = api.nvim_buf_get_name(0)
  if file == '' then
    vim.notify('pair: buffer has no file', vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = 'Note for Claude (empty = just point): ' }, function(note)
    if note == nil then return end
    local args = { 'hook', 'point', '--file', file, '--start', tostring(s), '--end', tostring(e), '--root', repo_root() }
    if note ~= '' then
      vim.list_extend(args, { '--note', note })
    end
    run_pair(args, 'pointing at ' .. vim.fn.fnamemodify(file, ':.') .. ':' .. s .. '-' .. e)
  end)
end

-- Toggle the PAIRING.md split.
function M.scratch()
  local path = repo_root() .. '/PAIRING.md'
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
    if name == path or name:match('PAIRING%.md$') then
      if #api.nvim_tabpage_list_wins(0) > 1 then
        api.nvim_win_close(win, false)
      else
        vim.notify('pair: PAIRING.md is the only window', vim.log.levels.INFO)
      end
      return
    end
  end
  vim.cmd('botright vsplit ' .. vim.fn.fnameescape(path))
  vim.cmd('vertical resize ' .. math.floor(vim.o.columns * 0.4))
end

function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  M.opts.bin = (opts and opts.bin) or vim.g.pair_bin or M.opts.bin
  vim.o.autoread = true
  -- A: no ATTENTION prompt on existing swapfiles (it would block the RPC).
  vim.opt.shortmess:append('A')
  ensure_hl()

  api.nvim_clear_autocmds({ group = augroup })

  -- Decide reloads without a dialog: reload clean buffers, keep dirty ones
  -- and say so in one line. Without this, a buffer with unsaved edits pops a
  -- modal dialog and the post_edit hook blocks until someone presses Enter.
  api.nvim_create_autocmd('FileChangedShell', {
    group = augroup,
    callback = function(ev)
      local reason = vim.v.fcs_reason
      if reason == 'deleted' then
        vim.v.fcs_choice = ''
        return
      end
      if reason == 'conflict' or vim.bo[ev.buf].modified then
        vim.v.fcs_choice = ''
        local name = vim.fn.fnamemodify(api.nvim_buf_get_name(ev.buf), ':.')
        vim.notify('pair: ' .. name .. ' changed on disk but has unsaved edits (:e! to reload)', vim.log.levels.WARN)
      else
        vim.v.fcs_choice = 'reload'
      end
    end,
  })

  -- Poll for external changes on the usual occasions.
  api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold', 'CursorHoldI' }, {
    group = augroup,
    command = 'silent! checktime',
  })

  -- The pointer disappears as soon as the engineer edits the pointed buffer.
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = augroup,
    callback = function(ev)
      if state.buf == ev.buf then M.clear() end
    end,
  })

  api.nvim_create_user_command('PairClear', M.clear, { desc = 'pair: clear the pointer highlight' })
  api.nvim_create_user_command('PairListen', M.listen, { desc = 'pair: push-to-talk' })
  api.nvim_create_user_command('PairInterrupt', M.interrupt, { desc = 'pair: interrupt Claude, then listen' })
  api.nvim_create_user_command('PairPoint', M.point, { desc = 'pair: point Claude at the selection', range = true })
  api.nvim_create_user_command('PairScratch', M.scratch, { desc = 'pair: toggle PAIRING.md' })

  if M.opts.keymaps then
    vim.keymap.set('n', '<leader>pt', M.listen, { desc = 'pair: push-to-talk' })
    vim.keymap.set('n', '<leader>pi', M.interrupt, { desc = 'pair: interrupt Claude, then listen' })
    vim.keymap.set({ 'n', 'x' }, '<leader>pp', M.point, { desc = 'pair: point Claude at this code' })
    vim.keymap.set('n', '<leader>ps', M.scratch, { desc = 'pair: toggle PAIRING.md' })
  end
end

return M
