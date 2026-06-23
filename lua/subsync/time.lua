local M = {}

-- Parse timespec: [HH:][MM:]SS[,mmm]
-- Returns total milliseconds, or nil on parse failure.
function M.parse(str)
  if not str or str == '' then return nil end
  str = str:match('^%s*(.-)%s*$')

  local parts = {}
  for p in str:gmatch('[^:]+') do
    parts[#parts + 1] = p
  end
  if #parts == 0 or #parts > 3 then return nil end

  local last = parts[#parts]
  local sec_str, ms_str = last:match('^(%d+),(%d+)$')
  if not sec_str then
    sec_str = last:match('^(%d+)$')
    ms_str = '0'
  end
  if not sec_str then return nil end

  local sec = tonumber(sec_str)
  local ms  = tonumber(ms_str) or 0
  local mins  = #parts >= 2 and (tonumber(parts[#parts - 1]) or 0) or 0
  local hours = #parts == 3 and (tonumber(parts[1]) or 0) or 0

  return ((hours * 60 + mins) * 60 + sec) * 1000 + ms
end

-- Parse an SRT timestamp "HH:MM:SS,mmm". Returns ms or nil.
function M.parse_srt(str)
  local h, m, s, ms = str:match('^(%d+):(%d+):(%d+),(%d+)$')
  if not h then return nil end
  return ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * 1000 + tonumber(ms)
end

-- Format ms as SRT timestamp "HH:MM:SS,mmm".
function M.format(ms)
  ms = math.max(0, math.floor(ms + 0.5))
  local h = math.floor(ms / 3600000); ms = ms % 3600000
  local m = math.floor(ms / 60000);   ms = ms % 60000
  local s = math.floor(ms / 1000);    ms = ms % 1000
  return string.format('%02d:%02d:%02d,%03d', h, m, s, ms)
end

return M
