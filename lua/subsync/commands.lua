local parser = require('subsync.parser')
local time   = require('subsync.time')

local M = {}

-- Remembered encoding per buffer number.
local buf_enc = {}

local function lines_get()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function lines_set(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

local function info(msg)  vim.notify('[SubSync] ' .. msg, vim.log.levels.INFO)  end
local function warn(msg)  vim.notify('[SubSync] ' .. msg, vim.log.levels.WARN)  end
local function err(msg)   vim.notify('[SubSync] ' .. msg, vim.log.levels.ERROR) end

-- `:SubSync read <encoding>`
function M.read(enc)
  if not enc or enc == '' then
    err('Usage: SubSync read <encoding>'); return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local path  = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then err('Buffer has no associated file'); return end

  -- Let Neovim reload the file natively with the given encoding so that
  -- fileencoding, mtime tracking, and undo history are all handled correctly.
  buf_enc[bufnr] = enc
  local ok, e = pcall(vim.cmd, 'edit! ++enc=' .. enc)
  if not ok then err('Read failed: ' .. tostring(e)); return end
  info('Read with encoding: ' .. enc)
end

-- `:SubSync reload`
function M.reload()
  local bufnr = vim.api.nvim_get_current_buf()
  local path  = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then err('Buffer has no associated file'); return end

  local enc = buf_enc[bufnr] or 'utf-8'
  local ok, e = pcall(vim.cmd, 'edit! ++enc=' .. enc)
  if not ok then err('Reload failed: ' .. tostring(e)); return end
  info('Reloaded with encoding: ' .. enc)
end

-- `:SubSync write [encoding]`
function M.write(enc)
  local bufnr = vim.api.nvim_get_current_buf()
  local path  = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then err('Buffer has no associated file'); return end

  local use_enc = (enc and enc ~= '') and enc or buf_enc[bufnr] or 'utf-8'

  local entries   = parser.parse_buffer(lines_get())
  local new_lines = parser.entries_to_lines(entries)
  lines_set(new_lines)

  -- Set encoding before writing so Neovim converts the UTF-8 buffer content
  -- to the target encoding on disk and updates its own mtime tracking.
  -- This prevents autoread from treating the file as externally modified.
  vim.bo.fileencoding = use_enc
  local ok, e = pcall(vim.cmd, 'write')
  if not ok then err('Write failed: ' .. tostring(e)); return end
  info('Written (' .. use_enc .. '): ' .. path)
end

-- `:SubSync shift [+/-timespec]`
function M.shift(arg)
  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  if arg and arg ~= '' then
    -- Global shift: apply a fixed delta to every subtitle.
    local sign, ts = arg:match('^([%+%-])(.+)$')
    if not sign then err('Invalid argument: ' .. arg); return end
    local delta = time.parse(ts)
    if not delta then err('Invalid timespec: ' .. ts); return end
    if sign == '-' then delta = -delta end

    local had_ann = false
    for _, e in ipairs(entries) do
      if e.annotation then had_ann = true end
      e.start_ms = math.max(0, e.start_ms + delta)
      e.end_ms   = math.max(0, e.end_ms   + delta)
      e.annotation = nil; e.annotation_str = nil
    end
    if had_ann then warn('Annotations removed (global shift applied)') end
  else
    -- Apply per-entry annotations.
    local had_ann = false
    for _, e in ipairs(entries) do
      if e.annotation then had_ann = true; break end
    end
    if not had_ann then info('No annotations found'); return end

    local had_interp = false
    for _, e in ipairs(entries) do
      if e.annotation then
        local k = e.annotation.kind
        if k == 'anchor_abs' or k == 'anchor_add' or k == 'anchor_sub' then
          had_interp = true; break
        end
      end
    end
    if had_interp then warn('Interpolation annotations (@) ignored') end

    local cascade = 0
    for _, e in ipairs(entries) do
      local ann = e.annotation
      if ann then
        local k = ann.kind
        if k == 'shift_add' then
          cascade = ann.ms
          e.start_ms = math.max(0, e.start_ms + cascade)
          e.end_ms   = math.max(0, e.end_ms   + cascade)
        elseif k == 'shift_sub' then
          cascade = -ann.ms
          e.start_ms = math.max(0, e.start_ms + cascade)
          e.end_ms   = math.max(0, e.end_ms   + cascade)
        elseif k == 'set' then
          local dur  = e.end_ms - e.start_ms
          e.start_ms = ann.ms
          e.end_ms   = ann.ms + dur
        elseif k == 'add' then
          e.start_ms = math.max(0, e.start_ms + ann.ms)
          e.end_ms   = math.max(0, e.end_ms   + ann.ms)
        elseif k == 'sub' then
          e.start_ms = math.max(0, e.start_ms - ann.ms)
          e.end_ms   = math.max(0, e.end_ms   - ann.ms)
        end
        -- anchor_* kinds: silently ignored
        e.annotation = nil; e.annotation_str = nil
      else
        e.start_ms = math.max(0, e.start_ms + cascade)
        e.end_ms   = math.max(0, e.end_ms   + cascade)
      end
    end
  end

  lines_set(parser.entries_to_lines(entries))
end

-- `:SubSync interpolate [strict]`
function M.interpolate(strict)
  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local had_ann = false
  for _, e in ipairs(entries) do
    if e.annotation then had_ann = true; break end
  end
  if not had_ann then info('No annotations found'); return end

  -- Collect anchor points and warn about non-anchor annotations.
  local anchors    = {}
  local had_shift  = false
  for i, e in ipairs(entries) do
    local ann = e.annotation
    if ann then
      local k = ann.kind
      if k == 'anchor_abs' then
        anchors[#anchors + 1] = {idx=i, ms=ann.ms}
      elseif k == 'anchor_add' then
        anchors[#anchors + 1] = {idx=i, ms=e.start_ms + ann.ms}
      elseif k == 'anchor_sub' then
        anchors[#anchors + 1] = {idx=i, ms=e.start_ms - ann.ms}
      else
        had_shift = true
      end
    end
  end
  if had_shift then warn('Shift/single-subtitle annotations ignored') end

  if #anchors < 2 then
    err('Interpolate requires at least 2 anchor points (@)'); return
  end

  -- Convert anchor target times to deltas relative to original start times.
  for _, a in ipairs(anchors) do
    a.delta = a.ms - entries[a.idx].start_ms
  end

  -- Linearly interpolated delta at entry index `idx`.
  local function get_delta(idx)
    local first = anchors[1]
    local last  = anchors[#anchors]

    if idx < first.idx then
      if strict then return nil end
      local a1, a2 = anchors[1], anchors[2]
      local t = (idx - a1.idx) / (a2.idx - a1.idx)
      return a1.delta + t * (a2.delta - a1.delta)
    end

    if idx > last.idx then
      if strict then return nil end
      local a1, a2 = anchors[#anchors - 1], anchors[#anchors]
      local t = (idx - a1.idx) / (a2.idx - a1.idx)
      return a1.delta + t * (a2.delta - a1.delta)
    end

    for i = 1, #anchors - 1 do
      local a1, a2 = anchors[i], anchors[i + 1]
      if idx >= a1.idx and idx <= a2.idx then
        if idx == a1.idx then return a1.delta end
        if idx == a2.idx then return a2.delta end
        local t = (idx - a1.idx) / (a2.idx - a1.idx)
        return a1.delta + t * (a2.delta - a1.delta)
      end
    end

    return 0
  end

  for i, e in ipairs(entries) do
    local delta = get_delta(i)
    if delta ~= nil then
      e.start_ms = math.max(0, e.start_ms + delta)
      e.end_ms   = math.max(0, e.end_ms   + delta)
    end
    e.annotation = nil; e.annotation_str = nil
  end

  lines_set(parser.entries_to_lines(entries))
end

-- `:SubSync length <min_timespec> <max_timespec>`
-- Clamps every subtitle's duration into [min_ms, max_ms] by adjusting end times only.
function M.length(min_str, max_str)
  if not min_str or min_str == '' or not max_str or max_str == '' then
    err('Usage: SubSync length <min_timespec> <max_timespec>'); return
  end
  local min_ms = time.parse(min_str)
  local max_ms = time.parse(max_str)
  if not min_ms then err('Invalid timespec: ' .. min_str); return end
  if not max_ms then err('Invalid timespec: ' .. max_str); return end
  if min_ms > max_ms then err('min_length must not exceed max_length'); return end

  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local changed = 0
  for i, e in ipairs(entries) do
    local dur = e.end_ms - e.start_ms
    if dur < min_ms then
      local new_end = e.start_ms + min_ms
      local next = entries[i + 1]
      if next and new_end > next.start_ms then
        new_end = next.start_ms
      end
      if new_end > e.end_ms then
        e.end_ms = new_end
        changed = changed + 1
      end
    elseif dur > max_ms then
      e.end_ms = e.start_ms + max_ms
      changed = changed + 1
    end
  end

  if changed == 0 then info('All subtitles already within length bounds'); return end
  lines_set(parser.entries_to_lines(entries))
  info(string.format('Adjusted %d subtitle(s)', changed))
end

-- `:SubSync gap <min_gap_timespec>`
-- Ensures every consecutive pair of subtitles has at least `gap_ms` between them
-- by trimming end times only. Entries where trimming would zero the duration are
-- left unchanged and reported.
function M.gap(gap_str)
  if not gap_str or gap_str == '' then
    err('Usage: SubSync gap <timespec>'); return
  end
  local gap_ms = time.parse(gap_str)
  if not gap_ms then err('Invalid timespec: ' .. gap_str); return end

  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local changed = 0
  local skipped = 0
  for i = 1, #entries - 1 do
    local e    = entries[i]
    local next = entries[i + 1]
    local actual_gap = next.start_ms - e.end_ms
    if actual_gap < gap_ms then
      local new_end = next.start_ms - gap_ms
      if new_end <= e.start_ms then
        skipped = skipped + 1
      else
        e.end_ms = new_end
        changed  = changed + 1
      end
    end
  end

  if changed == 0 and skipped == 0 then
    info('All gaps already sufficient'); return
  end
  if changed > 0 then
    lines_set(parser.entries_to_lines(entries))
  end
  local msg = string.format('Adjusted %d subtitle(s)', changed)
  if skipped > 0 then
    msg = msg .. string.format('; %d skipped (duration too short to fix)', skipped)
  end
  info(msg)
end

-- `:SubSync clean`
-- Strips all annotations without changing times or renumbering.
function M.clean()
  local lines = lines_get()
  local entries = parser.parse_buffer(lines)

  -- Build a set of first_line -> seq for annotated entries.
  local strip = {}
  for _, e in ipairs(entries) do
    if e.annotation_str then
      strip[e.first_line] = e.seq
    end
  end

  if not next(strip) then info('No annotations found'); return end

  local new_lines = {}
  for i, line in ipairs(lines) do
    new_lines[#new_lines + 1] = strip[i] and strip[i] or line
  end

  lines_set(new_lines)
  info('Annotations removed')
end

return M
