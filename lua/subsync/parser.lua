local time = require('subsync.time')
local M = {}

-- Parse an annotation string (the text after the sequence number).
-- Returns {kind, ms} or nil.
-- Kinds: shift_add, shift_sub, set, add, sub, anchor_abs, anchor_add, anchor_sub
function M.parse_annotation(str)
  if not str or str == '' then return nil end

  local ts

  ts = str:match('^@%+(.+)$')
  if ts then local ms = time.parse(ts); return ms and {kind='anchor_add', ms=ms} end

  ts = str:match('^@%-(.+)$')
  if ts then local ms = time.parse(ts); return ms and {kind='anchor_sub', ms=ms} end

  ts = str:match('^@(.+)$')
  if ts then local ms = time.parse(ts); return ms and {kind='anchor_abs', ms=ms} end

  ts = str:match('^%+%=(.+)$')
  if ts then local ms = time.parse(ts); return ms and {kind='add', ms=ms} end

  ts = str:match('^%-%=(.+)$')
  if ts then local ms = time.parse(ts); return ms and {kind='sub', ms=ms} end

  ts = str:match('^%=(.+)$')
  if ts then local ms = time.parse(ts); return ms and {kind='set', ms=ms} end

  ts = str:match('^%+(.+)$')
  if ts then local ms = time.parse(ts); return ms and {kind='shift_add', ms=ms} end

  ts = str:match('^%-(.+)$')
  if ts then local ms = time.parse(ts); return ms and {kind='shift_sub', ms=ms} end

  return nil
end

-- Parse buffer lines into a list of entry tables.
-- Each entry: { first_line, seq, annotation_str, annotation, start_ms, end_ms, text[] }
-- first_line is 1-based index into lines[].
function M.parse_buffer(lines)
  local entries = {}
  local i = 1

  while i <= #lines do
    if lines[i]:match('^%s*$') then
      i = i + 1
    else
      local seq_line = lines[i]
      local seq, ann_str = seq_line:match('^(%S+)%s+(.-)%s*$')
      if not seq then
        seq = seq_line:match('^%S+')
      end

      if seq and i + 1 <= #lines then
        local timing = lines[i + 1]
        local s_str, e_str = timing:match(
          '^(%d+:%d+:%d+,%d+)%s*%-%->%s*(%d+:%d+:%d+,%d+)%s*$'
        )
        if s_str then
          local start_ms = time.parse_srt(s_str)
          local end_ms   = time.parse_srt(e_str)
          local text = {}
          local j = i + 2
          while j <= #lines and not lines[j]:match('^%s*$') do
            text[#text + 1] = lines[j]
            j = j + 1
          end
          local annotation = ann_str and M.parse_annotation(ann_str) or nil
          entries[#entries + 1] = {
            first_line    = i,
            seq           = seq,
            annotation_str = ann_str,
            annotation    = annotation,
            start_ms      = start_ms,
            end_ms        = end_ms,
            text          = text,
          }
          i = j
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    end
  end

  return entries
end

-- Serialise entries back to buffer lines with sequential numbering.
-- Entries are separated by a single blank line; no trailing blank.
function M.entries_to_lines(entries)
  local lines = {}
  for idx, e in ipairs(entries) do
    lines[#lines + 1] = tostring(idx)
    lines[#lines + 1] = time.format(e.start_ms) .. ' --> ' .. time.format(e.end_ms)
    for _, t in ipairs(e.text) do
      lines[#lines + 1] = t
    end
    lines[#lines + 1] = ''
  end
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

return M
