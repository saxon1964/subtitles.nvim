local M = {}

function M.setup(user_cfg)
  local cmds = require('subsync.commands')
  cmds.setup(user_cfg)

  vim.api.nvim_create_user_command('SubSync', function(opts)
    local args = opts.fargs
    local sub   = args[1]
    if not sub then
      vim.notify('[SubSync] Usage: SubSync <read|reload|write|shift|interpolate|clean>', vim.log.levels.ERROR)
      return
    end
    sub = sub:lower()

    if sub == 'read' then
      cmds.read(args[2])
    elseif sub == 'reload' then
      cmds.reload()
    elseif sub == 'write' then
      cmds.write(args[2] or '')
    elseif sub == 'shift' then
      cmds.shift(args[2] or '')
    elseif sub == 'interpolate' then
      cmds.interpolate(args[2] and args[2]:lower() == 'strict')
    elseif sub == 'length' then
      cmds.length(args[2], args[3])
    elseif sub == 'gap' then
      cmds.gap(args[2])
    elseif sub == 'clean' then
      cmds.clean()
    else
      vim.notify('[SubSync] Unknown command: ' .. sub, vim.log.levels.ERROR)
    end
  end, {
    nargs = '*',
    desc  = 'SubSync subtitle timing commands',
    complete = function(arglead, cmdline, _)
      local parts = vim.split(cmdline, '%s+', {trimempty=true})
      -- parts[1] = 'SubSync', parts[2] = subcommand, parts[3] = argument
      local n = #parts
      -- If the line ends with whitespace the user already typed the previous word fully.
      local trailing_space = cmdline:match('%s$')

      if n == 1 or (n == 2 and not trailing_space) then
        local subs = {'clean', 'gap', 'interpolate', 'length', 'read', 'reload', 'shift', 'write'}
        local out  = {}
        for _, s in ipairs(subs) do
          if s:sub(1, #arglead) == arglead then out[#out + 1] = s end
        end
        return out
      end

      local sub = (parts[2] or ''):lower()
      if sub == 'interpolate' and (n == 2 or (n == 3 and not trailing_space)) then
        if ('strict'):sub(1, #arglead) == arglead then return {'strict'} end
      end
      return {}
    end,
  })
end

return M
