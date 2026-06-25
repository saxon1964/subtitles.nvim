local parser = require('subsync.parser')
local time   = require('subsync.time')

local M = {}

local cfg = {
  default_encoding        = 'utf-8',
  default_gap             = 80,    -- ms
  min_duration            = 1500,  -- ms
  max_duration            = 6000,  -- ms
  max_reading_speed       = 17,    -- chars/sec
  recommended_line_length = 40,    -- characters
}

function M.setup(user_cfg)
  if user_cfg then
    for k, v in pairs(user_cfg) do cfg[k] = v end
  end
end

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

-- `:SubSync read [encoding]`
function M.read(enc)
  local use_enc = (enc and enc ~= '') and enc or cfg.default_encoding
  local bufnr = vim.api.nvim_get_current_buf()
  local path  = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then err('Buffer has no associated file'); return end

  -- Let Neovim reload the file natively with the given encoding so that
  -- fileencoding, mtime tracking, and undo history are all handled correctly.
  buf_enc[bufnr] = use_enc
  local ok, e = pcall(vim.cmd, 'edit! ++enc=' .. use_enc)
  if not ok then err('Read failed: ' .. tostring(e)); return end
  info('Read with encoding: ' .. use_enc)
end

-- `:SubSync reload`
function M.reload()
  local bufnr = vim.api.nvim_get_current_buf()
  local path  = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then err('Buffer has no associated file'); return end

  local enc = buf_enc[bufnr] or cfg.default_encoding
  local ok, e = pcall(vim.cmd, 'edit! ++enc=' .. enc)
  if not ok then err('Reload failed: ' .. tostring(e)); return end
  info('Reloaded with encoding: ' .. enc)
end

-- `:SubSync write [encoding]`
function M.write(enc)
  local bufnr = vim.api.nvim_get_current_buf()
  local path  = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then err('Buffer has no associated file'); return end

  local use_enc = (enc and enc ~= '') and enc or buf_enc[bufnr] or cfg.default_encoding

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

-- `:SubSync duration [min_timespec] [max_timespec]`
-- Clamps every subtitle's duration into [min_ms, max_ms] by adjusting end times only.
function M.duration(min_str, max_str)
  local min_ms, max_ms
  if min_str and min_str ~= '' then
    min_ms = time.parse(min_str)
    if not min_ms then err('Invalid timespec: ' .. min_str); return end
  else
    min_ms = cfg.min_duration
  end
  if max_str and max_str ~= '' then
    max_ms = time.parse(max_str)
    if not max_ms then err('Invalid timespec: ' .. max_str); return end
  else
    max_ms = cfg.max_duration
  end
  if min_ms > max_ms then err('min_duration must not exceed max_duration'); return end

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

  if changed == 0 then info('All subtitles already within duration bounds'); return end
  lines_set(parser.entries_to_lines(entries))
  info(string.format('Adjusted %d subtitle(s)', changed))
end

-- `:SubSync gap [min_gap_timespec]`
-- Ensures every consecutive pair of subtitles has at least `gap_ms` between them
-- by trimming end times only. Entries where trimming would zero the duration are
-- left unchanged and reported.
function M.gap(gap_str)
  local gap_ms
  if gap_str and gap_str ~= '' then
    gap_ms = time.parse(gap_str)
    if not gap_ms then err('Invalid timespec: ' .. gap_str); return end
  else
    gap_ms = cfg.default_gap
  end

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

-- `:SubSync sort`
-- Reorders subtitle entries by start time (ascending), then renumbers.
function M.sort()
  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local already_sorted = true
  for i = 2, #entries do
    if entries[i].start_ms < entries[i - 1].start_ms then
      already_sorted = false; break
    end
  end
  if already_sorted then info('Subtitles already in order'); return end

  table.sort(entries, function(a, b) return a.start_ms < b.start_ms end)
  lines_set(parser.entries_to_lines(entries))
  info('Subtitles sorted by start time')
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

-- `:SubSync jump <seq>`
-- Moves the cursor to the sequence-number line of subtitle <seq>.
function M.jump(seq_str)
  if not seq_str or seq_str == '' then
    err('Usage: SubSync jump <number>'); return
  end
  local target = tonumber(seq_str)
  if not target then err('Invalid subtitle number: ' .. seq_str); return end

  local entries = parser.parse_buffer(lines_get())
  for _, e in ipairs(entries) do
    if tonumber(e.seq) == target then
      vim.api.nvim_win_set_cursor(0, {e.first_line, 0})
      return
    end
  end
  err('Subtitle #' .. seq_str .. ' not found')
end

-- `:SubSync info`
function M.info()
  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local n = #entries

  -- Collect violations.
  local too_short, too_long, gap_small, overlapping, too_fast, out_of_order, long_lines = {}, {}, {}, {}, {}, {}, {}

  for i, e in ipairs(entries) do
    local dur = e.end_ms - e.start_ms
    if dur < cfg.min_duration then too_short[#too_short + 1] = e.seq end
    if dur > cfg.max_duration then too_long[#too_long  + 1] = e.seq end

    local text = table.concat(e.text, ' ')
    local chars = #text:gsub('%s+', ' '):gsub('<[^>]+>', '')
    if dur > 0 and (chars / (dur / 1000)) > cfg.max_reading_speed then
      too_fast[#too_fast + 1] = e.seq
    end

    for _, line in ipairs(e.text) do
      if #line:gsub('<[^>]+>', '') > cfg.recommended_line_length then
        long_lines[#long_lines + 1] = e.seq
        break
      end
    end

    if i > 1 then
      local prev = entries[i - 1]
      local gap = e.start_ms - prev.end_ms
      if gap < 0 then
        overlapping[#overlapping + 1] = prev.seq
      elseif gap < cfg.default_gap then
        gap_small[#gap_small + 1] = prev.seq
      end
      if e.start_ms < prev.start_ms then
        out_of_order[#out_of_order + 1] = e.seq
      end
    end
  end

  local function fmt_list(t)
    if #t == 0 then return 'none' end
    local seqs = {}
    for _, s in ipairs(t) do seqs[#seqs + 1] = '#' .. tostring(s) end
    return table.concat(seqs, ', ')
  end

  local function fmt_count(t, label)
    return string.format('  %-30s: %d%s', label, #t,
      #t > 0 and ('  (' .. fmt_list(t) .. ')') or '')
  end

  local lines = {
    'SubSync Info — ' .. n .. ' subtitle' .. (n ~= 1 and 's' or ''),
    '',
    'Limits in use:',
    string.format('  Min duration       : %d ms',        cfg.min_duration),
    string.format('  Max duration       : %d ms',        cfg.max_duration),
    string.format('  Min gap            : %d ms',        cfg.default_gap),
    string.format('  Max reading speed  : %d chars/sec', cfg.max_reading_speed),
    string.format('  Max line length    : %d chars',     cfg.recommended_line_length),
    '',
    'Issues found:',
    fmt_count(too_short,    'Too short (< ' .. cfg.min_duration .. ' ms)'),
    fmt_count(too_long,     'Too long  (> ' .. cfg.max_duration .. ' ms)'),
    fmt_count(gap_small,    'Gap too small (< ' .. cfg.default_gap .. ' ms)'),
    fmt_count(overlapping,  'Overlapping'),
    fmt_count(too_fast,     'Too fast (> ' .. cfg.max_reading_speed .. ' cps)'),
    fmt_count(out_of_order, 'Out of order'),
    fmt_count(long_lines,   'Line too long (> ' .. cfg.recommended_line_length .. ' chars)'),
  }

  -- Remember the subtitle window before opening the split.
  local sub_win = vim.api.nvim_get_current_win()

  -- Open a scratch split at the bottom.
  vim.cmd('botright 16split')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden  = 'wipe'
  vim.bo[bufnr].filetype   = 'subsync-info'
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = bufnr, silent = true })

  -- Enter on a line jumps to the subtitle whose #N is under/nearest the cursor.
  vim.keymap.set('n', '<CR>', function()
    local line = vim.api.nvim_get_current_line()
    local col  = vim.api.nvim_win_get_cursor(0)[2]  -- 0-indexed byte offset

    -- Scan all #N tokens; pick the one the cursor is inside, else the nearest.
    local best_seq, best_dist = nil, math.huge
    local pos = 1
    while true do
      local s, e, seq = line:find('#(%d+)', pos)
      if not s then break end
      local token_start = s - 1  -- convert to 0-indexed
      local token_end   = e - 1
      if col >= token_start and col <= token_end then
        best_seq = seq
        break
      end
      local dist = math.min(math.abs(col - token_start), math.abs(col - token_end))
      if dist < best_dist then best_dist = dist; best_seq = seq end
      pos = e + 1
    end

    if not best_seq then info('No subtitle number on this line'); return end
    if not vim.api.nvim_win_is_valid(sub_win) then
      err('Subtitle window no longer open'); return
    end
    vim.api.nvim_set_current_win(sub_win)
    M.jump(best_seq)
  end, { buffer = bufnr, silent = true })
end

-- `:SubSync fixspeed [chars_per_sec]`
-- Extends end times of subtitles that exceed the reading speed threshold so
-- they become readable. End time is capped at next subtitle's start (no overlap).
function M.fixspeed(speed_str)
  local speed
  if speed_str and speed_str ~= '' then
    speed = tonumber(speed_str)
    if not speed or speed <= 0 then err('Invalid reading speed: ' .. speed_str); return end
  else
    speed = cfg.max_reading_speed
  end

  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local changed = 0
  local clamped = 0
  for i, e in ipairs(entries) do
    local text  = table.concat(e.text, ' ')
    local chars = #text:gsub('%s+', ' '):gsub('<[^>]+>', '')
    local required_ms = math.ceil(chars / speed * 1000)
    if e.end_ms - e.start_ms < required_ms then
      local new_end = e.start_ms + required_ms
      local next = entries[i + 1]
      if next and new_end > next.start_ms then
        new_end = next.start_ms
        clamped = clamped + 1
      end
      if new_end > e.end_ms then
        e.end_ms = new_end
        changed  = changed + 1
      end
    end
  end

  if changed == 0 then info('All subtitles within reading speed limit'); return end
  lines_set(parser.entries_to_lines(entries))
  local msg = string.format('Adjusted %d subtitle(s)', changed)
  if clamped > 0 then
    msg = msg .. string.format('; %d clamped to next subtitle start', clamped)
  end
  info(msg)
end

-- `:SubSync merge`
-- Merges the subtitle under the cursor with the immediately following entry.
-- Result keeps current entry's start time and next entry's end time.
-- Text lines are concatenated. Buffer is renumbered.
function M.merge()
  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]  -- 1-based

  -- Find which entry the cursor is in.
  local idx = nil
  for i, e in ipairs(entries) do
    local entry_lines = 2 + #e.text  -- seq line + timing line + text lines
    local last_line = e.first_line + entry_lines - 1
    if cursor_line >= e.first_line and cursor_line <= last_line then
      idx = i
      break
    end
  end

  if not idx then err('Cursor is not inside a subtitle entry'); return end
  if idx == #entries then err('No next subtitle to merge with'); return end

  local cur  = entries[idx]
  local next = entries[idx + 1]

  -- Merge: start from cur, end from next, text concatenated.
  cur.end_ms = next.end_ms
  for _, line in ipairs(next.text) do
    cur.text[#cur.text + 1] = line
  end
  cur.annotation = nil; cur.annotation_str = nil

  table.remove(entries, idx + 1)

  lines_set(parser.entries_to_lines(entries))
  info(string.format('Merged #%s with #%s', cur.seq, next.seq))
end

-- `:SubSync split`
-- Splits the subtitle under the cursor into two entries.
-- If the cursor is on a text line, that line becomes the last line of the first
-- entry and remaining text goes to the second. If on the seq/timing line,
-- text is divided in half. Duration is always split at the midpoint.
function M.split()
  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]  -- 1-based

  local idx        = nil
  local split_after = nil  -- split after this many text lines (1-based into text[])

  for i, e in ipairs(entries) do
    local last_line = e.first_line + 1 + #e.text  -- seq + timing + text lines
    if cursor_line >= e.first_line and cursor_line <= last_line then
      idx = i
      local text_offset = cursor_line - (e.first_line + 2) + 1  -- 1-based index into text[]
      if text_offset >= 1 and text_offset <= #e.text then
        split_after = text_offset
      else
        split_after = math.max(1, math.ceil(#e.text / 2))
      end
      break
    end
  end

  if not idx then err('Cursor is not inside a subtitle entry'); return end

  local e      = entries[idx]
  local mid_ms = math.floor((e.start_ms + e.end_ms) / 2)

  local text1, text2 = {}, {}
  for i, line in ipairs(e.text) do
    if i <= split_after then text1[#text1 + 1] = line
    else                     text2[#text2 + 1] = line end
  end

  local new_entry = {
    seq            = e.seq,
    annotation_str = nil,
    annotation     = nil,
    start_ms       = mid_ms,
    end_ms         = e.end_ms,
    text           = text2,
    first_line     = 0,
  }

  e.end_ms        = mid_ms
  e.text          = text1
  e.annotation    = nil
  e.annotation_str = nil

  table.insert(entries, idx + 1, new_entry)

  lines_set(parser.entries_to_lines(entries))
  info(string.format('Split #%s at %s', e.seq, time.format(mid_ms)))
end

-- `:SubSync wrap [N]`
-- Rebalances over-long text lines in subtitle N (or the subtitle under the cursor).
-- Text is split into paragraphs at lines starting with - or —. Paragraphs where
-- all lines are already within recommended_line_length are left untouched.
-- Paragraphs with at least one long line are rejoined and re-wrapped greedily.

local function visible_len(s)
  return #s:gsub('<[^>]+>', '')
end

local function rebalance_paragraph(para_lines, max_len)
  local needs = false
  for _, l in ipairs(para_lines) do
    if visible_len(l) > max_len then needs = true; break end
  end
  if not needs then return para_lines end

  -- Preserve leading dash/em-dash on first line.
  local leader = para_lines[1]:match('^(%s*[-—]%s*)') or ''
  local joined = para_lines[1]:sub(#leader + 1)
  for i = 2, #para_lines do joined = joined .. ' ' .. para_lines[i] end
  joined = joined:match('^%s*(.-)%s*$')

  local words = {}
  for w in joined:gmatch('%S+') do words[#words + 1] = w end
  if #words == 0 then return {leader} end

  local result = {}
  local cur = leader .. words[1]
  for i = 2, #words do
    local candidate = cur .. ' ' .. words[i]
    if visible_len(candidate) <= max_len then
      cur = candidate
    else
      result[#result + 1] = cur
      cur = words[i]
    end
  end
  result[#result + 1] = cur
  return result
end

function M.wrap(seq_str)
  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local idx = nil
  if seq_str and seq_str ~= '' then
    local target = tonumber(seq_str)
    if not target then err('Invalid subtitle number: ' .. seq_str); return end
    for i, e in ipairs(entries) do
      if tonumber(e.seq) == target then idx = i; break end
    end
    if not idx then err('Subtitle #' .. seq_str .. ' not found'); return end
  else
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    for i, e in ipairs(entries) do
      local last_line = e.first_line + 1 + #e.text
      if cursor_line >= e.first_line and cursor_line <= last_line then
        idx = i; break
      end
    end
    if not idx then err('Cursor is not inside a subtitle entry'); return end
  end

  local e       = entries[idx]
  local max_len = cfg.recommended_line_length

  -- Split text into paragraphs (new paragraph starts at a leading - or —).
  local paragraphs = {}
  local cur_para   = {}
  for _, line in ipairs(e.text) do
    if #cur_para > 0 and line:match('^%s*[-—]') then
      paragraphs[#paragraphs + 1] = cur_para
      cur_para = {line}
    else
      cur_para[#cur_para + 1] = line
    end
  end
  if #cur_para > 0 then paragraphs[#paragraphs + 1] = cur_para end

  local new_text = {}
  local changed  = false
  for _, para in ipairs(paragraphs) do
    local new_para = rebalance_paragraph(para, max_len)
    if #new_para ~= #para then
      changed = true
    else
      for i = 1, #para do
        if new_para[i] ~= para[i] then changed = true; break end
      end
    end
    for _, line in ipairs(new_para) do new_text[#new_text + 1] = line end
  end

  if not changed then
    info(string.format('#%s: all lines within %d character limit', e.seq, max_len))
    return
  end

  e.text = new_text
  lines_set(parser.entries_to_lines(entries))
  info(string.format('#%s: lines rebalanced', e.seq))
end

-- `:SubSync dup [N]`
-- Inserts a copy of subtitle N (or the subtitle under the cursor) immediately
-- after it with identical timing and text.
function M.dup(seq_str)
  local entries = parser.parse_buffer(lines_get())
  if #entries == 0 then info('No subtitle entries found'); return end

  local idx = nil

  if seq_str and seq_str ~= '' then
    local target = tonumber(seq_str)
    if not target then err('Invalid subtitle number: ' .. seq_str); return end
    for i, e in ipairs(entries) do
      if tonumber(e.seq) == target then idx = i; break end
    end
    if not idx then err('Subtitle #' .. seq_str .. ' not found'); return end
  else
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    for i, e in ipairs(entries) do
      local last_line = e.first_line + 1 + #e.text
      if cursor_line >= e.first_line and cursor_line <= last_line then
        idx = i; break
      end
    end
    if not idx then err('Cursor is not inside a subtitle entry'); return end
  end

  local src = entries[idx]
  local copy_text = {}
  for _, line in ipairs(src.text) do copy_text[#copy_text + 1] = line end

  local copy = {
    seq            = src.seq,
    annotation_str = nil,
    annotation     = nil,
    start_ms       = src.start_ms,
    end_ms         = src.end_ms,
    text           = copy_text,
    first_line     = 0,
  }

  table.insert(entries, idx + 1, copy)

  lines_set(parser.entries_to_lines(entries))
  info(string.format('Duplicated #%s as #%d', entries[idx].seq, idx + 1))
end

return M
