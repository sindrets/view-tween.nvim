local utils = require("view_tween.utils")
local Animation = require("view_tween.animation")
local debounce = require("view_tween.debounce")

local api = vim.api

local M = {}

M.MAX_FRAMERATE = 144
M.DURATION = 250

M.cache = {
  ---@type table<integer, ViewTween>
  tweens = {},
}

---[Graph](https://www.desmos.com/calculator/4spoyadbuy)
---@param k number # Steepness
---@param m number # Horizontal bias
function M.parametric_sine(k, m)
  local function g(x)
    if x <= 0 then return 0 end
    if x >= 1 then return 1 end
    return math.pow(1 - x, 2 * (m + 1 / 2)) * (-1) + 1
  end

  ---@param x number # [0,1]
  ---@return number # Progression
  return function(x)
    if x <= 0 then return 0 end
    if x >= 1 then return 1 end
    return math.pow(0.5 + (math.sin((g(x) - 0.5) * math.pi) / 2), math.pow(2 * (1 - x), k))
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
---@field target_line integer
---@field orig_line integer
---@field orig_view WinView
---@field min_line integer
---@field max_line integer
---@field last_cursor { [1]: integer, [2]: integer }
---@field done boolean
---@field animation Animation
---@field folds { [integer]?: { top?: integer, bottom?: integer } }
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
  self.orig_view = utils.get_winview(self.winid)
  self.orig_line = self.orig_view.topline
  self.done = false

  self.animation = Animation({
    time_start = opt.time_start,
    time_end = opt.time_end,
    duration = opt.duration,
    progression_fn = opt.progression_fn or M.DEFAULT_PROGRESSION_FN,
  })

  if opt.folds then
    self.folds = opt.folds
  else
    self.folds = {}

    api.nvim_win_call(self.winid, function()
      local cur = 1
      while cur < self.max_line do
        local fold_start = vim.fn.foldclosed(cur)

        if fold_start > -1 then
          local fold_end = vim.fn.foldclosedend(cur)
          if not self.folds[fold_start] then self.folds[fold_start] = {} end
          if not self.folds[fold_end] then self.folds[fold_end] = {} end
          self.folds[fold_start].bottom = fold_end
          self.folds[fold_end].top = fold_start
          cur = fold_end + 1
        else
          cur = cur + 1
        end
      end
    end)
  end

  if opt.target_line then
    self.scroll_delta = self:get_scroll_delta(self.orig_line, opt.target_line)
  elseif opt.scroll_delta then
    self.scroll_delta = opt.scroll_delta
  else
    error("One of 'target_line' or 'scroll_delta' must be specified!")
  end

  self.target_line = self:resolve_scroll_delta(self.orig_line, self.scroll_delta)
end

function ViewTween:invalidate()
  self.animation:invalidate()
  self.done = true
end

function ViewTween:is_valid()
  return not self.done
end

---@param line_from integer
---@param line_to integer
---@return integer delta
function ViewTween:get_scroll_delta(line_from, line_to)
  line_from = math.max(line_from, 1)
  line_to = math.min(line_to, self.max_line)
  local sign = utils.sign(line_to - line_from)

  if sign == 0 then return 0 end

  local key = sign == -1 and "top" or "bottom"
  local cur = line_from
  local delta = 0

  while (line_to - cur) * sign > 0 do
    if self.folds[cur] and self.folds[cur][key] then
      cur = self.folds[cur][key] + sign
    else
      cur = cur + sign
    end

    delta = delta + sign
  end

  return delta
end

---@param line integer Current line
---@param delta number
---@return integer target_line
function ViewTween:resolve_scroll_delta(line, delta)
  local sign = utils.sign(delta)

  if sign == 0 then return line end

  local idelta = utils.round(delta * sign)
  local key = sign == -1 and "top" or "bottom"
  local ret = line

  for _ = 1, idelta do
    if self.folds[ret] and self.folds[ret][key] then
      ret = self.folds[ret][key] + sign
    else
      ret = ret + sign
    end
  end

  return utils.clamp(ret, self.min_line, self.max_line)
end

function ViewTween:resolve_cursor(line, topline)
  topline = topline or utils.get_winview(self.winid).topline
  local height = utils.get_win_height(self.winid)
  local so = utils.get_scrolloff(self.winid)

  -- If the topline is less than the scrolloff: disregard the scrolloff
  local min = topline < so and topline or self:resolve_scroll_delta(topline, so)
  local max = self:resolve_scroll_delta(topline, height - so - 1)

  return utils.clamp(line, min, max)
end

---@return boolean stop
function ViewTween:update()
  if not api.nvim_win_is_valid(self.winid) then return true end

  local cur_lnum = api.nvim_win_get_cursor(self.winid)[1]

  if api.nvim_win_get_tabpage(self.winid) ~= api.nvim_get_current_tabpage() then
    utils.set_winview({
      topline = self.target_line,
      lnum = self:resolve_cursor(cur_lnum, self.target_line),
    }, self.winid)
    return true
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local p = self.animation:get_p()
  local topline, cursorline

  if self.last_cursor then
    -- We have already scrolled to the top.
    -- Animate the cursor for the remaining duration of the tween.
    cursorline = self:resolve_scroll_delta( self.last_cursor[1], self.scroll_delta * p)
    utils.set_cursor(self.winid, cursorline, 0)
    utils.set_winview({ curswant = self.orig_view.curswant }, self.winid)
  else
    topline = self:resolve_scroll_delta(self.orig_line, self.scroll_delta * p)
    utils.set_winview({
      topline = topline,
      lnum = self:resolve_cursor(cur_lnum, topline),
    }, self.winid)
  end

  if self.last_cursor and (cursor[1] == 1 and self.scroll_delta < 0) then
    -- The cursor has reached the top of the window: terminate
    return true
  end

  if topline == self.target_line then
    if topline == 1 then
      if cursor[1] == 1 then
        -- We have reached the target topline and the cursor is on line 1:
        -- terminate
        return true
      end

      self.last_cursor = cursor
      self.scroll_delta = self.scroll_delta - self:get_scroll_delta(self.orig_line, self.target_line) - 1

      return false
    end

    -- We have reached the target: terminate
    return true
  end

  return false
end

function ViewTween:start()
  local loop

  local function close()
    loop:close()

    if M.cache.tweens[self.winid] == self then
      M.cache.tweens[self.winid] = nil
    end
  end

  loop = debounce.throttle_trailing(1000 / M.MAX_FRAMERATE, true, vim.schedule_wrap(function()
    if not self:is_valid() then
      close()
      return
    end

    local stop = self:update()

    if stop or not self.animation:is_alive() then
      close()
      self:invalidate()
    else
      loop()
    end
  end))

  loop()
end

M.scroll = debounce.throttle_trailing(
  M.DURATION / 2,
  true,
  ---@param winid integer
  ---@param delta number
  ---@param duration? integer
  function(winid, delta, duration)
    local now = utils.now()

    vim.schedule(function()
      if not winid or winid == 0 then
        winid = api.nvim_get_current_win()
      end

      delta = utils.round(delta)
      duration = duration or M.DURATION
      local last_tween = M.cache.tweens[winid]

      if last_tween and last_tween:is_valid() then
        -- An animation is already in progress. Replace it with a continuation animation
        last_tween:invalidate()
        local new_tween = ViewTween({
          winid = winid,
          time_start = now,
          duration = duration,
          scroll_delta = delta,
          progression_fn = M.DEFAULT_CONTINUATION_FN,
          folds = last_tween.folds, -- Assume folds have not changed since we started the last tween
        })
        M.cache.tweens[winid] = new_tween
        new_tween:start()
      else
        local new_tween = ViewTween({
          winid = winid,
          duration = duration,
          scroll_delta = delta,
        })
        M.cache.tweens[winid] = new_tween
        new_tween:start()
      end
    end)
  end
)

M.scroll_actions = {
  --- Emulates |<C-U>|.
  half_page_up = function(duration)
    return function()
      if vim.v.count > 0 then
        -- Set the new 'scroll' value
        vim.opt_local.scroll = vim.v.count
      end

      M.scroll(0, -vim.wo.scroll, duration)
    end
  end,
  --- Emulates |<C-D>|.
  half_page_down = function(duration)
    return function()
      if vim.v.count > 0 then
        -- Set the new 'scroll' value
        vim.opt_local.scroll = vim.v.count
      end

      M.scroll(0, vim.wo.scroll --[[@as integer ]], duration)
    end
  end,
  --- Emulates |<C-B>|.
  page_up = function(duration)
    return function()
      M.scroll(0, - (vim.v.count1 * utils.get_win_height(0)), duration)
    end
  end,
  --- Emulates |<C-F>|.
  page_down = function(duration)
    return function()
      M.scroll(0, vim.v.count1 * utils.get_win_height(0), duration)
    end
  end,
  --- Emulates |zt|.
  cursor_top = function(duration, delta_time_scale)
    return function()
      local height = utils.get_win_height(0)
      local so = utils.get_scrolloff(0)
      local scroll_height = height - so * 2
      local winln = utils.get_winline()
      local delta = winln - so - 1
      local scale = delta_time_scale and (math.abs(delta) / scroll_height) or 1
      M.scroll(0, delta, duration * scale)
    end
  end,
  --- Emulates |zb|.
  cursor_bottom = function(duration, delta_time_scale)
    return function()
      local height = utils.get_win_height(0)
      local so = utils.get_scrolloff(0)
      local scroll_height = height - so * 2
      local winln = utils.get_winline()
      local delta = -(height - winln - so)
      local scale = delta_time_scale and (math.abs(delta) / scroll_height) or 1
      M.scroll(0, delta, duration * scale)
    end
  end,
  --- Emulates |zz|.
  cursor_center = function(duration, delta_time_scale)
    return function()
      local height = utils.get_win_height(0)
      local so = utils.get_scrolloff(0)
      local scroll_height = height - so * 2
      local winln = utils.get_winline()
      local delta = -(height / 2 - winln)
      local scale = delta_time_scale and (math.abs(delta) / (scroll_height / 2)) or 1
      M.scroll(0, delta, duration * scale)
    end
  end,
}

M.DEFAULT_PROGRESSION_FN = M.parametric_sine(0, 0.29)
-- M.DEFAULT_PROGRESSION_FN = M.parametric_ease_out(0.55)
M.DEFAULT_CONTINUATION_FN = M.parametric_ease_out(0.55)
M.ViewTween = ViewTween
return M
