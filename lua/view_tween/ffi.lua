local ffi = require("ffi")

local C = ffi.C

local M = {}

---@param winid integer
---@return ffi.cdata* wp # Window pointer
function M.find_win(winid)
  return C.find_window_by_handle(winid, M.shared.err)
end

---@class FoldInfo
---@field start integer # Line number where the deepest fold starts
---@field level integer # Fold level, when zero other fields are N/A
---@field low_level integer # Lowest fold level that starts in v:lnum
---@field rem_lines integer # Number of lines from v:lnum to end of closed fold. When 0: the fold is open

---@param winid integer
---@param lnum integer
---@return FoldInfo
function M.fold_info(winid, lnum)
  local wp = M.find_win(winid)
  return C.fold_info(wp, lnum)
end

if vim.fn.has("nvim-0.8") == 1 then
  ffi.cdef([[
  typedef int32_t linenr_T;
  ]])
else
  ffi.cdef([[
  typedef long linenr_T;
  ]])
end

ffi.cdef([[
typedef struct window_S win_T;

typedef struct {} Error;
win_T *find_window_by_handle(int window, Error *err);

typedef struct {
  linenr_T start;
  int level;
  int low_level;
  linenr_T rem_lines;
} foldinfo_T;

foldinfo_T fold_info(win_T* wp, int lnum);

int plines_win(win_T *wp, linenr_T lnum, bool winheight);
int plines_win_nofill(win_T *wp, linenr_T lnum, bool winheight);
]])

M.shared = {
  err = ffi.new("Error")
}
M.ffi = ffi

return M
