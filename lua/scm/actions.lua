-- scm.actions — the git commands SCM runs when the user stages, unstages,
-- discards or commits. UI-free like Core: each function runs git in one
-- repository and calls done(err) once on the main loop, err nil on success.
local M = {}

-- Another git process (a shell prompt, an editor) may hold the index lock for
-- a moment. A command that loses that race is tried again before it is
-- reported, because nothing was changed and the lock is usually gone.
local LOCK_RETRIES, LOCK_RETRY_MS = 3, 100

-- `--literal-pathspecs` makes git take every path as the exact name it is. A
-- file may be called "*" or ":/", and as a pattern either would widen a
-- discard to the whole repository.
local function git(repo, args, done, attempt)
  attempt = attempt or 1
  local cmd = { "git", "--literal-pathspecs", "-C", repo }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code == 0 then
        done(nil)
        return
      end
      local message = vim.trim(out.stderr or "")
      if message:find("index.lock", 1, true) and attempt < LOCK_RETRIES then
        vim.defer_fn(function()
          git(repo, args, done, attempt + 1)
        end, LOCK_RETRY_MS)
        return
      end
      if message == "" then
        message = vim.trim(out.stdout or "")
      end
      done(message ~= "" and message or ("git " .. args[1] .. " failed"))
    end)
  end)
end

-- paths, or the whole repository when paths is nil.
local function pathspec(paths)
  local spec = { "--" }
  vim.list_extend(spec, paths or { "." })
  return spec
end

-- Stage paths (repository-relative), or every change when paths is nil.
-- `-A` so a deleted file is staged as a deletion.
function M.stage(repo, paths, done)
  local args = { "add", "-A" }
  vim.list_extend(args, pathspec(paths))
  git(repo, args, done)
end

-- Unstage paths, or everything staged when paths is nil. A repository with no
-- commit yet has no HEAD to reset to, so its index entries are removed
-- instead. That is only ever done when HEAD is known to be missing: removing
-- index entries in a repository that has commits would stage every file as
-- deleted.
function M.unstage(repo, paths, done)
  git(repo, { "rev-parse", "-q", "--verify", "HEAD" }, function(unborn)
    local args = unborn and { "rm", "-r", "-q", "--cached" } or { "reset", "-q", "HEAD" }
    vim.list_extend(args, pathspec(paths))
    git(repo, args, done)
  end)
end

-- Throw away the working-tree change to one path: delete an untracked file,
-- or restore a tracked one from the index.
function M.discard(repo, path, opts, done)
  if opts.untracked then
    git(repo, { "clean", "-f", "-q", "--", path }, done)
  else
    git(repo, { "checkout", "-q", "--", path }, done)
  end
end

-- Commit what is staged. With opts.all, stage every change first, as VS Code
-- does when nothing is staged.
function M.commit(repo, message, opts, done)
  local function commit()
    git(repo, { "commit", "-q", "-m", message }, done)
  end
  if not opts.all then
    commit()
    return
  end
  M.stage(repo, nil, function(err)
    if err then
      done(err)
    else
      commit()
    end
  end)
end

return M
