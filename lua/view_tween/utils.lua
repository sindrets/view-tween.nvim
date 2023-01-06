local uv = vim.loop
local api = vim.api

local M = {}

---@class WinView
---@field lnum integer # Cursor line number
---@field col integer # Cursor column (0 indexed)
---@field coladd integer # Cursor column offset for 'virtualedit'
---@field curswant integer # Column for vertical movement
---@field leftcol integer # First column displayed
---@field skipcol integer # Columns skipped
---@field topfill integer # Filler lines (i.e. deleted lines in diff mode)
---@field topline integer # First line in the window

---@param value number
---@param min number
---@param max number
---@return number
function M.clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

---@param value number
---@return integer
function M.round(value)
  return math.floor(value + 0.5)
end

---Get the sign of a given number.
---@param n number
---@return -1|0|1
function M.sign(n)
  return (n > 0 and 1 or 0) - (n < 0 and 1 or 0)
end

---Get the current time (ms)
---@return number
function M.now()
  return uv.hrtime() / 1000000
end

function M.tbl_pack(...)
  return { n = select("#", ...), ... }
end

function M.tbl_unpack(t, i, j)
  return unpack(t, i or 1, j or t.n or #t)
end

---@param winid? integer
---@return WinView
function M.get_winview(winid)
  local ret

  api.nvim_win_call(winid or 0, function()
    ret = vim.fn.winsaveview()
  end)

  return ret
end

---@param view WinView
---@param winid? integer
function M.set_winview(view, winid)
  api.nvim_win_call(winid or 0, function()
    vim.fn.winrestview(view)
  end)
end

return M
