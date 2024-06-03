local require = require("flash.require")

local Config = require("flash.config")
local Jump = require("flash.jump")
local State = require("flash.state")
local Util = require("flash.util")

local M = {}

---@type Flash.State?
M.state = nil
M.op = false
M.enabled = true

---@type integer?
M.delay = nil

---@param enabled? boolean
function M.toggle(enabled)
  if enabled == nil then
    enabled = not M.enabled
  end

  if M.enabled == enabled then
    return M.enabled
  end

  M.enabled = enabled

  if State.is_search() then
    if M.enabled then
      M.start()
      M.update(false)
    elseif M.state then
      M.state:hide()
      M.state = nil
    end
    -- redraw to show the change
    vim.cmd("redraw")
    -- trigger incsearch to update the matches
    vim.api.nvim_feedkeys(" " .. Util.BS, "n", true)
  end
  return M.enabled
end

---@param check_jump? boolean
function M.update(check_jump)
  if not M.state then
    return
  end

  local pattern = vim.fn.getcmdline()

  -- when doing // or ??, get the pattern from the search register
  -- See :h search-commands
  if pattern:sub(1, 1) == vim.fn.getcmdtype() then
    pattern = vim.fn.getreg("/") .. pattern:sub(2)
  end
  M.state:update({ pattern = pattern, check_jump = check_jump })
end

function M.start()
  M.state = State.new({
    mode = "search",
    action = M.jump,
    search = {
      forward = vim.fn.getcmdtype() == "/",
      mode = "search",
      incremental = vim.go.incsearch,
    },
  })
  if M.op then
    M.state.opts.search.multi_window = false
  end
end

local cmdline_changed_callback, cmdline_leave_callback, cmdline_enter_callback, mode_changed_callback, cmdline_changed_callback1, cmdline_leave_callback1, cmdline_enter_callback1 --, mode_changed_callback1

do
  local function wrap(fn)
    return function(...)
      if M.state then return fn(...) end
    end
  end

  local timer_callback = vim.schedule_wrap(function()
    --[[print(
      string.format(
        "Timer elapsed. S/V: %d/%d, CJ: %d->1",
        M.state and 1 or 0,
        M.state and M.state.visible and 1 or 0,
        M.check_jump and 1 or 0
      )
    ) --]]
    if M.state then
      if not M.state.visible then
        M.state:update({ force = true, check_jump = false })
        M.state:show()
        vim.cmd "redraw"
        -- vim.api.nvim__redraw({})
      end
      M.check_jump = M.state ~= nil
    end
  end)

  -- Search trigger --> Flash hidden initially until timer expires after last input change
  -- Typing --> reset timer to restart delay for activating/enabling Flash
  -- Timer expires --> activate/enable Flash

  cmdline_changed_callback = wrap(function() M.update() end)

  ---@param tbl {file:string}
  cmdline_changed_callback1 = wrap(function(tbl)
    --[[print(
      string.format(
        "Received input (%s). Remaining time: %s, S/V: %d/%d, CJ: %d->?",
        tbl.file,
        M.timer and tostring(vim.uv.timer_get_due_in(M.timer)) or "(nil)",
        M.state and 1 or 0,
        M.state.visible and 1 or 0,
        M.check_jump and 1 or 0
      )
    ) --]]
    if tbl.file == "/" or tbl.file == "?" then
      if not (M.update(M.check_jump) or resetting_timer) then
        M.resetting_timer = true
        M.check_jump = false
        if M.state and M.state.visible then M.state:hide() end
        if M.timer and vim.uv.timer_get_due_in(M.timer) > 0 then vim.uv.timer_stop(M.timer) end
        if not M.timer then M.timer = vim.uv.new_timer() end
        vim.uv.timer_start(M.timer, M.delay, 0, timer_callback)
        M.resetting_timer = false
      end
    else
      if M.timer then vim.uv.timer_stop(M.timer) end
      M.check_jump = false
      M.update(false)
      if M.state and M.state.visible then M.state:hide() end
    end
  end)

  cmdline_leave_callback = wrap(function()
    M.state:hide()
    M.state = nil
  end)

  cmdline_leave_callback1 = wrap(function()
    if M.timer then vim.uv.timer_stop(M.timer) end
    if M.state.visible then M.state:hide() end
    M.state = nil
  end)

  cmdline_enter_callback = function()
    if State.is_search() and M.enabled then
      M.start()
      M.set_op(vim.fn.mode() == "v")
    end
  end

  cmdline_enter_callback1 = function()
    M.Timer = M.Timer or vim.uv.new_timer()
    if State.is_search() and M.enabled then
      M.set_op(vim.fn.mode() == "v")
      M.check_jump = false
      vim.uv.timer_start(M.Timer, M.delay, 0, timer_callback)
      M.start()
      M.state:hide()
    end
  end

  mode_changed_callback = function() M.set_op(vim.v.event.old_mode:sub(1, 2) == "no" or vim.fn.mode() == "v") end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("flash", { clear = true })
  M.enabled = Config.modes.search.enabled or false

  if Config.modes.search.delay == true then
    M.delay = 1500
  elseif Config.modes.search.delay and Config.modes.search.delay > 0 then
    M.delay = Config.modes.search.delay --[[@as integer]]
  else
    M.delay = nil
  end

  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    callback = M.delay and cmdline_changed_callback1 or cmdline_changed_callback,
  })

  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    callback = M.delay and cmdline_leave_callback1 or cmdline_leave_callback,
  })
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    callback = M.delay and cmdline_enter_callback1 or cmdline_enter_callback,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    pattern = "*:c",
    group = group,
    callback = mode_changed_callback,
  })
end

function M.set_op(op)
  M.op = op
  if M.op and M.state then
    M.state.opts.search.multi_window = false
  end
end

---@param self Flash.State
---@param match Flash.Match
function M.jump(match, self)
  local pos = match.pos
  local search_reg = vim.fn.getreg("/")

  -- For operator pending mode, set the search pattern to the
  -- first character on the match position
  if M.op then
    local pos_pattern = ("\\%%%dl\\%%%dc."):format(pos[1], pos[2] + 1)
    vim.fn.setcmdline(pos_pattern)
  end

  -- schedule a <cr> input to trigger the search
  vim.schedule(function()
    vim.api.nvim_input(M.op and "<cr>" or "<esc>")
  end)

  -- restore the real search pattern after the search
  -- and perform the jump when not in operator pending mode
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    once = true,
    callback = vim.schedule_wrap(function()
      -- delete the search pattern.
      -- The correct one will be added in `on_jump`
      vim.fn.histdel("search", -1)
      if M.op then
        -- restore original search pattern
        vim.fn.setreg("/", search_reg)
      else
        Jump.jump(match, self)
      end
      Jump.on_jump(self)
    end),
  })
end

return M
