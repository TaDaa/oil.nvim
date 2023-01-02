local cache = require("oil.cache")
local columns = require("oil.columns")
local config = require("oil.config")
local fs = require("oil.fs")
local permissions = require("oil.adapters.files.permissions")
local util = require("oil.util")
local FIELD = require("oil.constants").FIELD
local M = {}

local function read_link_data(path, cb)
  vim.loop.fs_readlink(
    path,
    vim.schedule_wrap(function(link_err, link)
      if link_err then
        cb(link_err)
      else
        local stat_path = link
        if not fs.is_absolute(link) then
          stat_path = fs.join(vim.fn.fnamemodify(path, ":h"), link)
        end
        vim.loop.fs_stat(stat_path, function(stat_err, stat)
          cb(nil, link, stat)
        end)
      end
    end)
  )
end

---@param path string
---@param entry_type nil|oil.EntryType
---@return string
M.to_short_os_path = function(path, entry_type)
  local shortpath = fs.shorten_path(fs.posix_to_os_path(path))
  if entry_type == "directory" then
    shortpath = util.addslash(shortpath)
  end
  return shortpath
end

local file_columns = {}

local fs_stat_meta_fields = {
  stat = function(parent_url, entry, cb)
    local _, path = util.parse_url(parent_url)
    local dir = fs.posix_to_os_path(path)
    vim.loop.fs_stat(fs.join(dir, entry[FIELD.name]), cb)
  end,
}

file_columns.size = {
  meta_fields = fs_stat_meta_fields,

  render = function(entry, conf)
    local meta = entry[FIELD.meta]
    local stat = meta.stat
    if not stat then
      return ""
    end
    if stat.size >= 1e9 then
      return string.format("%.1fG", stat.size / 1e9)
    elseif stat.size >= 1e6 then
      return string.format("%.1fM", stat.size / 1e6)
    elseif stat.size >= 1e3 then
      return string.format("%.1fk", stat.size / 1e3)
    else
      return string.format("%d", stat.size)
    end
  end,

  parse = function(line, conf)
    return line:match("^(%d+%S*)%s+(.*)$")
  end,
}

-- TODO support file permissions on windows
if not fs.is_windows then
  file_columns.permissions = {
    meta_fields = fs_stat_meta_fields,

    render = function(entry, conf)
      local meta = entry[FIELD.meta]
      local stat = meta.stat
      if not stat then
        return ""
      end
      return permissions.mode_to_str(stat.mode)
    end,

    parse = function(line, conf)
      return permissions.parse(line)
    end,

    compare = function(entry, parsed_value)
      local meta = entry[FIELD.meta]
      if parsed_value and meta.stat and meta.stat.mode then
        local mask = bit.lshift(1, 12) - 1
        local old_mode = bit.band(meta.stat.mode, mask)
        if parsed_value ~= old_mode then
          return true
        end
      end
      return false
    end,

    render_action = function(action)
      local _, path = util.parse_url(action.url)
      return string.format(
        "CHMOD %s %s",
        permissions.mode_to_octal_str(action.value),
        M.to_short_os_path(path, action.entry_type)
      )
    end,

    perform_action = function(action, callback)
      local _, path = util.parse_url(action.url)
      path = fs.posix_to_os_path(path)
      vim.loop.fs_stat(path, function(err, stat)
        if err then
          return callback(err)
        end
        -- We are only changing the lower 12 bits of the mode
        local mask = bit.bnot(bit.lshift(1, 12) - 1)
        local old_mode = bit.band(stat.mode, mask)
        vim.loop.fs_chmod(path, bit.bor(old_mode, action.value), callback)
      end)
    end,
  }
end

local current_year = vim.fn.strftime("%Y")

for _, time_key in ipairs({ "ctime", "mtime", "atime", "birthtime" }) do
  file_columns[time_key] = {
    meta_fields = fs_stat_meta_fields,

    render = function(entry, conf)
      local meta = entry[FIELD.meta]
      local stat = meta.stat
      local fmt = conf and conf.format
      local ret
      if fmt then
        ret = vim.fn.strftime(fmt, stat[time_key].sec)
      else
        local year = vim.fn.strftime("%Y", stat[time_key].sec)
        if year ~= current_year then
          ret = vim.fn.strftime("%b %d %Y", stat[time_key].sec)
        else
          ret = vim.fn.strftime("%b %d %H:%M", stat[time_key].sec)
        end
      end
      return ret
    end,

    parse = function(line, conf)
      local fmt = conf and conf.format
      local pattern
      if fmt then
        pattern = fmt:gsub("%%.", "%%S+")
      else
        pattern = "%S+%s+%d+%s+%d%d:?%d%d"
      end
      return line:match("^(" .. pattern .. ")%s+(.+)$")
    end,
  }
end

---@param name string
---@return nil|oil.ColumnDefinition
M.get_column = function(name)
  return file_columns[name]
end

---@param url string
---@param callback fun(url: string)
M.normalize_url = function(url, callback)
  local scheme, path = util.parse_url(url)
  local os_path = vim.fn.fnamemodify(fs.posix_to_os_path(path), ":p")
  local realpath = vim.loop.fs_realpath(os_path) or os_path
  local norm_path = util.addslash(fs.os_to_posix_path(realpath))
  if norm_path ~= os_path then
    callback(scheme .. fs.os_to_posix_path(norm_path))
  else
    callback(util.addslash(url))
  end
end

---@param url string
---@param column_defs string[]
---@param callback fun(err: nil|string, entries: nil|oil.InternalEntry[])
M.list = function(url, column_defs, callback)
  local _, path = util.parse_url(url)
  local dir = fs.posix_to_os_path(path)
  local fetch_meta = columns.get_metadata_fetcher(M, column_defs)
  cache.begin_update_url(url)
  local function cb(err, data)
    if err or not data then
      cache.end_update_url(url)
    end
    callback(err, data)
  end
  vim.loop.fs_opendir(dir, function(open_err, fd)
    if open_err then
      if open_err:match("^ENOENT: no such file or directory") then
        -- If the directory doesn't exist, treat the list as a success. We will be able to traverse
        -- and edit a not-yet-existing directory.
        return cb()
      else
        return cb(open_err)
      end
    end
    local read_next
    read_next = function(read_err)
      if read_err then
        cb(read_err)
        return
      end
      vim.loop.fs_readdir(fd, function(err, entries)
        if err then
          vim.loop.fs_closedir(fd, function()
            cb(err)
          end)
          return
        elseif entries then
          local poll = util.cb_collect(#entries, function(inner_err)
            if inner_err then
              cb(inner_err)
            else
              cb(nil, true)
              read_next()
            end
          end)
          for _, entry in ipairs(entries) do
            local cache_entry = cache.create_entry(url, entry.name, entry.type)
            fetch_meta(url, cache_entry, function(meta_err)
              if err then
                poll(meta_err)
              else
                local meta = cache_entry[FIELD.meta]
                -- Make sure we always get fs_stat info for links
                if entry.type == "link" then
                  read_link_data(fs.join(dir, entry.name), function(link_err, link, link_stat)
                    if link_err then
                      poll(link_err)
                    else
                      if not meta then
                        meta = {}
                        cache_entry[FIELD.meta] = meta
                      end
                      meta.link = link
                      meta.link_stat = link_stat
                      cache.store_entry(url, cache_entry)
                      poll()
                    end
                  end)
                else
                  cache.store_entry(url, cache_entry)
                  poll()
                end
              end
            end)
          end
        else
          vim.loop.fs_closedir(fd, function(close_err)
            if close_err then
              cb(close_err)
            else
              cb()
            end
          end)
        end
      end)
    end
    read_next()
  end, 100) -- TODO do some testing for this
end

---@param bufnr integer
---@return boolean
M.is_modifiable = function(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local _, path = util.parse_url(bufname)
  local dir = fs.posix_to_os_path(path)
  local stat = vim.loop.fs_stat(dir)
  if not stat then
    return true
  end

  -- Can't do permissions checks on windows
  if fs.is_windows then
    return true
  end

  local uid = vim.loop.getuid()
  local gid = vim.loop.getgid()
  local rwx
  if uid == stat.uid then
    rwx = bit.rshift(stat.mode, 6)
  elseif gid == stat.gid then
    rwx = bit.rshift(stat.mode, 3)
  else
    rwx = stat.mode
  end
  return bit.band(rwx, 2) ~= 0
end

---@param url string
M.url_to_buffer_name = function(url)
  local _, path = util.parse_url(url)
  return fs.posix_to_os_path(path)
end

---@param action oil.Action
---@return string
M.render_action = function(action)
  if action.type == "create" then
    local _, path = util.parse_url(action.url)
    local ret = string.format("CREATE %s", M.to_short_os_path(path, action.entry_type))
    if action.link then
      ret = ret .. " -> " .. fs.posix_to_os_path(action.link)
    end
    return ret
  elseif action.type == "delete" then
    local _, path = util.parse_url(action.url)
    return string.format("DELETE %s", M.to_short_os_path(path, action.entry_type))
  elseif action.type == "move" or action.type == "copy" then
    local dest_adapter = config.get_adapter_by_scheme(action.dest_url)
    if dest_adapter == M then
      local _, src_path = util.parse_url(action.src_url)
      local _, dest_path = util.parse_url(action.dest_url)
      return string.format(
        "  %s %s -> %s",
        action.type:upper(),
        M.to_short_os_path(src_path, action.entry_type),
        M.to_short_os_path(dest_path, action.entry_type)
      )
    else
      -- We should never hit this because we don't implement supports_xfer
      error("files adapter doesn't support cross-adapter move/copy")
    end
  else
    error(string.format("Bad action type: '%s'", action.type))
  end
end

---@param action oil.Action
---@param cb fun(err: nil|string)
M.perform_action = function(action, cb)
  if action.type == "create" then
    local _, path = util.parse_url(action.url)
    path = fs.posix_to_os_path(path)
    if action.entry_type == "directory" then
      vim.loop.fs_mkdir(path, 493, function(err)
        -- Ignore if the directory already exists
        if not err or err:match("^EEXIST:") then
          cb()
        else
          cb(err)
        end
      end) -- 0755
    elseif action.entry_type == "link" and action.link then
      local flags = nil
      local target = fs.posix_to_os_path(action.link)
      if fs.is_windows then
        flags = {
          dir = vim.fn.isdirectory(target) == 1,
          junction = false,
        }
      end
      vim.loop.fs_symlink(target, path, flags, cb)
    else
      fs.touch(path, cb)
    end
  elseif action.type == "delete" then
    local _, path = util.parse_url(action.url)
    path = fs.posix_to_os_path(path)
    fs.recursive_delete(action.entry_type, path, cb)
  elseif action.type == "move" then
    local dest_adapter = config.get_adapter_by_scheme(action.dest_url)
    if dest_adapter == M then
      local _, src_path = util.parse_url(action.src_url)
      local _, dest_path = util.parse_url(action.dest_url)
      src_path = fs.posix_to_os_path(src_path)
      dest_path = fs.posix_to_os_path(dest_path)
      fs.recursive_move(action.entry_type, src_path, dest_path, vim.schedule_wrap(cb))
    else
      -- We should never hit this because we don't implement supports_xfer
      cb("files adapter doesn't support cross-adapter move")
    end
  elseif action.type == "copy" then
    local dest_adapter = config.get_adapter_by_scheme(action.dest_url)
    if dest_adapter == M then
      local _, src_path = util.parse_url(action.src_url)
      local _, dest_path = util.parse_url(action.dest_url)
      src_path = fs.posix_to_os_path(src_path)
      dest_path = fs.posix_to_os_path(dest_path)
      fs.recursive_copy(action.entry_type, src_path, dest_path, cb)
    else
      -- We should never hit this because we don't implement supports_xfer
      cb("files adapter doesn't support cross-adapter copy")
    end
  else
    cb(string.format("Bad action type: %s", action.type))
  end
end

return M