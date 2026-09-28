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
  -- seconds a drawn change stays visible (0 = until the next one)
  diff_ttl = tonumber(vim.env.PAIR_DIFF_TTL) or 120,
  -- highlight group used for "Claude is pointing here"
  hl = 'PairPointer',
  -- set to false to define no keymaps
  keymaps = true,
  -- the pair binary; `pair start` sets vim.g.pair_bin to its own path
  bin = vim.g.pair_bin or 'pair',
}

local state = { buf = nil, timer = nil }

-- Buffers of these filetypes are file trees, never edit targets.
M.tree_filetypes = { netrw = true, NvimTree = true, ['neo-tree'] = true, oil = true }

local function ensure_hl()
  -- `default = true` lets a colorscheme or the user override it.
  api.nvim_set_hl(0, M.opts.hl, { link = 'Visual', default = true })
  api.nvim_set_hl(0, 'PairAdd', { link = 'DiffAdd', default = true })
  api.nvim_set_hl(0, 'PairAddSign', { link = 'Added', default = true })
  api.nvim_set_hl(0, 'PairDelete', { link = 'DiffDelete', default = true })
end

-- Arm the timer that clears the current highlight after `seconds`.
local function expire_after(seconds)
  if seconds and seconds > 0 then
    state.timer = uv.new_timer()
    state.timer:start(seconds * 1000, 0, vim.schedule_wrap(function() M.clear() end))
  end
end

-- The window that already shows `file`, if any.
local function window_showing(file)
  local want = vim.fn.fnamemodify(file, ':p')
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
    if name ~= '' and vim.fn.fnamemodify(name, ':p') == want then return win end
  end
end

-- Put `file` in the editor window and return the window and buffer. A file
-- that is already on screen (the scratchpad, typically) is shown where it
-- is instead of being opened a second time.
local function open_in_editor(file)
  local win = window_showing(file) or M.editor_win()
  -- A name relative to the working directory keeps the status line short.
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(file, ':.'))
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if api.nvim_win_get_buf(win) ~= buf then
    api.nvim_win_set_buf(win, buf)
  end
  api.nvim_set_current_win(win)
  return win, buf
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
function M.editor_win()
  local function usable(win)
    if not api.nvim_win_is_valid(win) then return false end
    local buf = api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= '' then return false end
    if M.tree_filetypes[vim.bo[buf].filetype] then return false end
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

  local win, buf = open_in_editor(file)

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

  expire_after(M.opts.ttl)
  vim.cmd('redraw')
  return { file = api.nvim_buf_get_name(buf), start = s, ['end'] = e }
end

-- Draw a change inside the file, the way a diff would but in place: added
-- lines are highlighted and get a "+" in the sign column, removed lines are
-- shown as virtual lines where they used to be. `payload` is a JSON string
-- (or a table) { added = { line, ... }, removed = { { at = line, lines = {} } } }
-- with 1-based line numbers of the new file. The cursor goes to the first
-- change.
function M.diff(file, payload)
  local marks = payload
  if type(payload) == 'string' then
    local ok, decoded = pcall(vim.json.decode, payload)
    if not ok then return { error = 'invalid marks' } end
    marks = decoded
  end
  marks = marks or {}
  local win, buf = open_in_editor(file)
  vim.cmd('silent! checktime')

  M.clear()
  ensure_hl()
  local last = api.nvim_buf_line_count(buf)
  local first, added, removed = nil, 0, 0

  for _, l in ipairs(marks.added or {}) do
    if l >= 1 and l <= last then
      api.nvim_buf_set_extmark(buf, ns, l - 1, 0, {
        line_hl_group = 'PairAdd',
        sign_text = '+',
        sign_hl_group = 'PairAddSign',
        priority = 200,
      })
      added = added + 1
      if not first or l < first then first = l end
    end
  end

  for _, block in ipairs(marks.removed or {}) do
    local virt = {}
    for _, text in ipairs(block.lines or {}) do
      virt[#virt + 1] = { { '- ' .. text, 'PairDelete' } }
    end
    if #virt > 0 then
      local at = math.max(1, tonumber(block.at) or 1)
      if at <= last then
        api.nvim_buf_set_extmark(buf, ns, at - 1, 0, { virt_lines = virt, virt_lines_above = true, priority = 200 })
      else -- removed at the end of the file
        at = last
        api.nvim_buf_set_extmark(buf, ns, last - 1, 0, { virt_lines = virt, priority = 200 })
      end
      removed = removed + #virt
      if not first or at < first then first = at end
    end
  end

  if first then
    api.nvim_win_set_cursor(win, { first, 0 })
    api.nvim_win_call(win, function() vim.cmd('normal! zz') end)
  end
  state.buf = buf
  expire_after(M.opts.diff_ttl)
  vim.cmd('redraw')
  return { file = api.nvim_buf_get_name(buf), added = added, removed = removed, first = first }
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
  local from = api.nvim_get_current_win()
  if M.tree_filetypes[vim.bo[api.nvim_win_get_buf(from)].filetype] then
    vim.cmd('wincmd l')
  end
  vim.cmd('belowright split ' .. vim.fn.fnameescape(path))
  vim.cmd('resize ' .. math.max(6, math.floor(vim.o.lines * 0.28)))
  vim.wo.winfixheight = true
end

-- True when the user has their own Neovim configuration.
local function has_user_config()
  local dir = vim.fn.stdpath('config')
  return vim.fn.filereadable(dir .. '/init.lua') == 1 or vim.fn.filereadable(dir .. '/init.vim') == 1
end

-- Colours for someone who never configured Neovim. The default theme is
-- nearly monochrome on a light terminal; retrobox is built in, colourful,
-- and follows the terminal's light or dark background.
local function apply_colors()
  vim.o.termguicolors = true
  vim.cmd('syntax enable')
  for _, scheme in ipairs({ vim.env.PAIR_COLORSCHEME or 'retrobox', 'habamax', 'default' }) do
    if pcall(vim.cmd.colorscheme, scheme) then break end
  end
  -- Tree-sitter highlighting for the languages Neovim ships parsers for.
  api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = { 'markdown', 'lua', 'vim', 'c', 'query', 'help' },
    callback = function(ev) pcall(vim.treesitter.start, ev.buf) end,
  })
  ensure_hl()
end

-- Reasonable editor defaults for someone who never configured Neovim.
local function apply_defaults()
  vim.o.number = true
  vim.o.mouse = 'a'
  vim.o.termguicolors = true
  vim.o.cursorline = true
  vim.o.signcolumn = 'yes'
  vim.o.splitright = true
  vim.o.splitbelow = true
  vim.o.swapfile = false
  vim.o.wrap = false
  vim.o.scrolloff = 5
  vim.o.ignorecase = true
  vim.o.smartcase = true
  vim.o.clipboard = 'unnamedplus'
  vim.o.laststatus = 2
end

-- Open a project tree on the left: the user's tree plugin when there is
-- one, the built-in netrw otherwise.
local function open_tree(root)
  if vim.fn.exists(':NvimTreeOpen') == 2 then
    vim.cmd('NvimTreeOpen')
    return true
  end
  if vim.fn.exists(':Neotree') == 2 then
    vim.cmd('Neotree show left')
    return true
  end
  vim.g.netrw_banner = 0
  vim.g.netrw_liststyle = 3 -- tree
  vim.g.netrw_browse_split = 4 -- Enter opens the file in the editor window
  vim.g.netrw_altv = 1
  vim.g.netrw_winsize = -30 -- columns
  vim.g.netrw_list_hide = [[^\.\./$,^\./$,^\.git/$,^\.pair/$,^node_modules/$,^tmp/$,^log/$,^\.DS_Store$]]
  vim.g.netrw_hide = 1
  local ok = pcall(vim.cmd, 'Lexplore ' .. vim.fn.fnameescape(root))
  return ok
end

-- The pairing layout: project tree | editor, with PAIRING.md below the
-- editor. `pair start` calls this once Neovim is up.
function M.layout()
  local root = repo_root()
  vim.cmd('cd ' .. vim.fn.fnameescape(root))
  if not has_user_config() then
    apply_defaults()
    apply_colors()
  end

  -- The editor window starts on the README when there is one.
  local readme = vim.fn.glob(root .. '/README*', false, true)[1]
  if readme and vim.fn.filereadable(readme) == 1 then
    vim.cmd('edit ' .. vim.fn.fnameescape(readme))
  end
  local editor = api.nvim_get_current_win()

  open_tree(root)
  if api.nvim_win_is_valid(editor) then api.nvim_set_current_win(editor) end

  if vim.fn.filereadable(root .. '/PAIRING.md') == 1 then
    vim.cmd('belowright split ' .. vim.fn.fnameescape(root .. '/PAIRING.md'))
    vim.cmd('resize ' .. math.max(6, math.floor(vim.o.lines * 0.28)))
    vim.wo.winfixheight = true
  end
  if api.nvim_win_is_valid(editor) then api.nvim_set_current_win(editor) end
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
