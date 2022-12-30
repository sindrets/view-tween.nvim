local utils = require("view_tween.utils")

---@class Animation
---@field time_start number (ms)
---@field time_end number (ms)
---@field duration number (ms)
---@field progression_fn? fun(t: number): number
---@field done boolean
local Animation = setmetatable({}, {
  __call = function(t, ...)
    local self = setmetatable({}, { __index = t })
    if self.init then self:init(...) end
    return self
  end,
})

---@class Animation.init.Opt
---@field time_start? number
---@field time_end? number
---@field duration? number
---@field progression_fn? fun(t: number): number

---@param opt Animation.init.Opt
function Animation:init(opt)
  self.time_start = opt.time_start or utils.now()
  self.progression_fn = opt.progression_fn

  if opt.time_end then
    self:set_time_end(opt.time_end)
  elseif opt.duration then
    self:set_duration(opt.duration)
  else
    error("One of 'time_end' or 'duration' must be specified!")
  end
end

---@param time? number # (ms)
function Animation:is_alive(time)
  if self.done then return false end
  time = time or utils.now()
  return self:get_t(time) < 1
end

function Animation:invalidate()
  self.done = true
end

function Animation:get_elapsed(time)
  time = time or utils.now()
  return time - self.time_start
end

---@param time? number # (ms)
function Animation:get_t(time)
  time = time or utils.now()
  return (time - self.time_start) / self.duration
end

---Get progression decimal
---@param time? number # (ms)
---@return number
function Animation:get_p(time)
  local t = self:get_t(time)
  local ret

  if self.progression_fn then
    ret = self.progression_fn(t)
  else
    ret = t
  end

  return utils.clamp(ret, 0, 1)
end

function Animation:set_time_start(time)
  self.time_start = time
  self:set_time_end(self.time_end)
end

function Animation:set_time_end(time)
  self.time_end = time
  self.duration = self.time_end - self.time_start
end

function Animation:set_duration(time)
  self.duration = time
  self.time_end = self.time_start + self.duration
end

return Animation
