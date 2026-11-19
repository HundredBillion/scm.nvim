-- scm.process — running a program and reading what it prints, with a
-- limit on how much is read: a program that prints without end must not
-- fill the editor's memory.
local M = {}

-- Run `argv`. `opts`: stdin, cwd, env, timeout (ms), max_bytes, text.
-- done({code, signal, stdout, stderr, too_large}) runs once, on the main loop;
-- when stdout passes max_bytes the program is stopped, `stdout` is empty and
-- `too_large` is set. Returns the process, or nil and why it did not start.
function M.run(argv, opts, done)
  local chunks, size, too_large, process = {}, 0, false, nil
  local max = opts.max_bytes or math.huge
  local ok, started = pcall(vim.system, argv, {text=opts.text, stdin=opts.stdin, cwd=opts.cwd, env=opts.env,
    timeout=opts.timeout, stdout=function(_, data)
      if not data or too_large then return end
      size = size + #data
      if size > max then
        too_large, chunks = true, {}
        if process then process:kill(9) end
      else
        chunks[#chunks + 1] = data
      end
    end}, function(out)
      vim.schedule(function()
        done({code=out.code, signal=out.signal, stdout=too_large and '' or table.concat(chunks),
          stderr=out.stderr or '', too_large=too_large})
      end)
    end)
  if not ok then return nil, started end
  process = started
  return process
end

return M
