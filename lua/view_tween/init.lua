local utils = require("view_tween.utils")
local Animation = require("view_tween.animation")
local debounce = require("view_tween.debounce")

local api = vim.api

local M = {}

M.MAX_FRAMERATE = 144
M.DURATION = 250

---[Graph](https://www.desmos.com/calculator/c5egnupfgj)
---@param k number # Steepness
function M.parametric_sine(k)
  ---@param x number # [0,1]
  ---@return number # Progression
  return function(x)
    if x <= 0 then return 0 end
    if x >= 1 then return 1 end
    return math.pow(0.5 + (math.sin((x - 0.5) * math.pi) / 2), math.pow(2 * (1 - x), k))
  end
end

---[Graph](https://www.desmos.com/calculator/tmiqlckphe)
---@param k number # Slope
function M.parametric_ease_out(k)
  ---@param x number # [0,1]
  ---@return number # Progression
  return function(x)
    if x <= 0 then return 0 end
    if x >= 1 then return 1 end
    return math.pow(1 - x, 2 * (k + 1 / 2)) * (-1) + 1
  end
end

---@class ViewTween
---@operator call : ViewTween
---@field winid integer
---@field line_wants integer
---@field target_line integer
---@field orig_line integer
---@field orig_view WinView
---@field min_line integer
---@field max_line integer
---@field done boolean
---@field animation Animation
local ViewTween = setmetatable({}, {
  __call = function(t, ...)
    local self = setmetatable({}, { __index = t })
    if self.init then self:init(...) end
    return self
  end,
})

function ViewTween:init(opt)
  self.winid = opt.winid or api.nvim_get_current_win()
  local bufnr = api.nvim_win_get_buf(self.winid)

  self.min_line = opt.min_line or 1
  self.max_line = opt.max_line or api.nvim_buf_line_count(bufnr)
  self.line_wants = opt.target_line
  self.target_line = utils.clamp(opt.target_line, self.min_line, self.max_line)
  self.orig_view = utils.get_winview(self.winid)
  self.orig_line = self.orig_view.topline
  self.done = false
  self.animation = Animation({
    time_start = opt.time_start,
    time_end = opt.time_end,
    duration = opt.duration,
    progression_fn = opt.progression_fn or M.DEFAULT_PROGRESSION_FN,
  })
end

function ViewTween:invalidate()
  self.animation:invalidate()
  self.done = true
end

function ViewTween:is_valid()
  return not self.done
end

---@return boolean stop
function ViewTween:update()
  if not api.nvim_win_is_valid(self.winid) then return true end

  local height = api.nvim_win_get_height(self.winid)
  local cur_lnum = api.nvim_win_get_cursor(self.winid)[1]
  local so = vim.wo[self.winid].scrolloff

  if api.nvim_win_get_tabpage(self.winid) ~= api.nvim_get_current_tabpage() then
    utils.set_winview({
      topline = self.target_line,
      lnum = utils.clamp(cur_lnum, self.target_line + so, self.target_line + height - so - 1),
    }, self.winid)
    return true
  end

  local p = self.animation:get_p()
  local topline = utils.clamp(
    utils.round(self.orig_line + (self.line_wants - self.orig_line) * p),
    self.min_line,
    self.max_line
  )
  utils.set_winview({
    topline = topline,
    lnum = utils.clamp(cur_lnum, topline + so, topline + height - so - 1),
  }, self.winid)

  if topline == self.target_line then return true end

  return false
end

function ViewTween:start()
  local step
  step = debounce.throttle_trailing(1000 / M.MAX_FRAMERATE, true, vim.schedule_wrap(function()
    if not self:is_valid() then
      step:close()
      return
    end

    local stop = self:update()

    if stop or not self.animation:is_alive() then
      step:close()
      self:invalidate()
    else
      step()
    end
  end))

  step()
end

---@param winid integer
---@param delta integer
---@param duration? integer
function M.scroll(winid, delta, duration)
  if not winid or winid == 0 then
    winid = api.nvim_get_current_win()
  end

  duration = duration or M.DURATION
  local view = utils.get_winview(winid)
  local target_line = view.topline + delta

  if M.last_tween and M.last_tween:is_valid() then
    -- An animation is already in progress. Replace it with a continuation animation
    M.last_tween:invalidate()
    M.last_tween = ViewTween({
      duration = duration,
      target_line = target_line,
      progression_fn = M.DEFAULT_CONTINUATION_FN,
    })
    M.last_tween:start()
  else
    M.last_tween = ViewTween({
      duration = duration,
      target_line = target_line,
    })
    M.last_tween:start()
  end
end

M.scroll_actions = {
  half_page_up = function(duration)
    return function()
      M.scroll(0, -vim.wo.scroll, duration)
    end
  end,
  half_page_down = function(duration)
    return function()
      M.scroll(0, vim.wo.scroll --[[@as integer ]], duration)
    end
  end,
  page_up = function(duration)
    return function()
      M.scroll(0, -api.nvim_win_get_height(0), duration)
    end
  end,
  page_down = function(duration)
    return function()
      M.scroll(0, api.nvim_win_get_height(0), duration)
    end
  end,
  cursor_top = function(duration)
    return function()
      local view = utils.get_winview()
      local so = vim.o.scrolloff --[[@as integer ]]
      M.scroll(0, view.lnum - view.topline - so, duration)
    end
  end,
  cursor_bottom = function(duration)
    return function()
      local view = utils.get_winview()
      local height = api.nvim_win_get_height(0)
      local so = vim.o.scrolloff --[[@as integer ]]
      M.scroll(0, -(view.topline + height - view.lnum - so), duration)
    end
  end,
  cursor_center = function(duration)
    return function()
      local view = utils.get_winview()
      local height = api.nvim_win_get_height(0)
      local center = view.topline + math.floor(height / 2)
      M.scroll(0, view.lnum - center, duration)
    end
  end,
}

M.DEFAULT_PROGRESSION_FN = M.parametric_sine(0.5)
M.DEFAULT_CONTINUATION_FN = M.parametric_ease_out(0.55)
M.ViewTween = ViewTween
return M
