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

  if M.opts.keymaps then
    vim.keymap.set('n', '<leader>pt', M.listen, { desc = 'pair: push-to-talk' })
    vim.keymap.set('n', '<leader>pi', M.interrupt, { desc = 'pair: interrupt Claude, then listen' })
  end
end

return M
