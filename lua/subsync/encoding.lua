local M = {}

local function is_utf8(enc)
  return enc:lower():gsub('[^%w]', '') == 'utf8'
end

-- Read a file from disk, converting from `encoding` to UTF-8.
-- Returns content string or (nil, error_string).
function M.read_file(path, encoding)
  local f = io.open(path, 'rb')
  if not f then return nil, 'Cannot open file: ' .. path end
  local content = f:read('*a')
  f:close()

  if not is_utf8(encoding) then
    local converted = vim.iconv(content, encoding, 'utf-8')
    if not converted then
      return nil, 'Failed to decode with encoding: ' .. encoding
    end
    content = converted
  end

  return content
end

-- Write UTF-8 content to disk, converting to `encoding`.
-- Returns true or (false, error_string).
function M.write_file(path, content, encoding)
  if not is_utf8(encoding) then
    local converted = vim.iconv(content, 'utf-8', encoding)
    if not converted then
      return false, 'Failed to encode as: ' .. encoding
    end
    content = converted
  end

  local f = io.open(path, 'wb')
  if not f then return false, 'Cannot write file: ' .. path end
  f:write(content)
  f:close()
  return true
end

return M
