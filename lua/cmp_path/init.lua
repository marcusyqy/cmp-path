local cmp = require 'cmp'

local NAME_REGEX = '\\%([^/\\\\:\\*?<>\'"`\\|]\\)'
local NAME_REGEX_CMDLINE = '\\%([^[:space:]/\\\\:\\*?<>\'"`\\|]\\)'
local PATH_REGEX = vim.regex(([[\%(\%(/PAT*[^/\\\\:\\*?<>\'"`\\| .~]\)\|\%(/\.\.\)\)*/\zePAT*$]]):gsub('PAT', NAME_REGEX))

local source = {}

local constants = {
  max_lines = 20,
}

---@class cmp_path.Option
---@field public trailing_slash boolean
---@field public label_trailing_slash boolean
---@field public get_cwd fun(): string

---@type cmp_path.Option
local defaults = {
  trailing_slash = false,
  label_trailing_slash = true,
  get_cwd = function(params)
    return vim.fn.expand(('#%d:p:h'):format(params.context.bufnr))
  end,
}

source.new = function()
  return setmetatable({}, { __index = source })
end

source.get_trigger_characters = function()
  return { '/', '.' }
end

source.get_keyword_pattern = function(self, params)
  if vim.api.nvim_get_mode().mode == 'c' then
    return NAME_REGEX_CMDLINE .. '*'
  end
  return NAME_REGEX .. '*'
end

source.complete = function(self, params, callback)
  local option = self:_validate_option(params)
  local is_cmdline = vim.api.nvim_get_mode().mode == 'c'

  if is_cmdline then
    local cmdline_special_candidates = self:_cmdline_special_candidates(params, option)
    if cmdline_special_candidates then
      return callback(cmdline_special_candidates)
    end
  end

  local dirname = self:_dirname(params, option)
  if not dirname then
    return callback()
  end

  local include_hidden = string.sub(params.context.cursor_before_line, params.offset, params.offset) == '.'
  self:_candidates(dirname, include_hidden, option, function(err, candidates)
    if err then
      return callback()
    end
    callback(candidates)
  end)
end

source.resolve = function(self, completion_item, callback)
  local data = completion_item.data
  if data.stat and data.stat.type == 'file' then
    local ok, documentation = pcall(function()
      return self:_get_documentation(data.path, constants.max_lines)
    end)
    if ok then
      completion_item.documentation = documentation
    end
  end
  callback(completion_item)
end

source._has_cmdline_special = function(_, text)
  local i = 1
  while i <= #text do
    local c = string.sub(text, i, i)
    local escaped = i > 1 and string.sub(text, i - 1, i - 1) == '\\'
    if not escaped then
      if c == '%' or c == '#' then
        return true
      end
      if c == '<' and string.find(text, '>', i + 1, true) then
        return true
      end
    end
    i = i + 1
  end
  return false
end

source._expand_cmdline_special_dirname = function(self, cursor_before_line)
  local path_expr = string.match(cursor_before_line, '%S+$')
  if not path_expr then
    return nil
  end

  local slash_pos = path_expr:find('/[^/]*$')
  if not slash_pos then
    return nil
  end

  local dirname_expr = string.sub(path_expr, 1, slash_pos)
  if not self:_has_cmdline_special(dirname_expr) then
    return nil
  end

  local expanded = vim.fn.expandcmd(dirname_expr)
  if expanded == '' then
    return nil
  end
  expanded = expanded:gsub('\\ ', ' ')
  expanded = vim.fn.fnamemodify(expanded, ':p')
  return vim.fn.resolve(expanded)
end

source._cmdline_special_candidates = function(self, params, option)
  local cursor_before_line = params.context.cursor_before_line
  local path_expr = string.match(cursor_before_line, '%S+$')
  if not path_expr then
    return nil
  end

  if path_expr:find('/') then
    return nil
  end

  if not self:_has_cmdline_special(path_expr) then
    return nil
  end

  local matched = vim.fn.getcompletion(path_expr, 'file')
  if #matched == 0 then
    return nil
  end

  local token_start = #cursor_before_line - #path_expr + 1
  local cursor = params.context.cursor
  local has_cursor = cursor and cursor.row and cursor.col
  local text_edit_line = has_cursor and (cursor.row - 1) or 0
  local text_edit_end_character = has_cursor and (cursor.col - 1) or 0

  local items = {}
  for _, match in ipairs(matched) do
    local resolved_match = match:gsub('\\ ', ' ')
    local normalized_match = resolved_match
    if normalized_match:sub(1, #path_expr) == path_expr then
      normalized_match = normalized_match:sub(#path_expr + 1)
    end
    if normalized_match == '' then
      normalized_match = resolved_match
    end

    local resolved_path = vim.fn.resolve(vim.fn.fnamemodify(normalized_match, ':p'))
    local stat = vim.loop.fs_stat(resolved_path)
    local insert_text = normalized_match
    local item = {
      label = normalized_match,
      filterText = path_expr,
      insertText = insert_text,
      kind = cmp.lsp.CompletionItemKind.File,
      data = {
        path = resolved_path,
        type = stat and stat.type or 'file',
        stat = stat,
        lstat = nil,
      },
    }

    if stat and stat.type == 'directory' then
      local directory = normalized_match
      if not directory:match('/$') then
        directory = directory .. '/'
      end

      item.kind = cmp.lsp.CompletionItemKind.Folder
      item.label = option.label_trailing_slash and directory or directory:sub(1, -2)
      insert_text = option.trailing_slash and directory or directory:sub(1, -2)
      item.insertText = insert_text
      if not option.trailing_slash then
        item.word = directory:sub(1, -2)
      end
    end

    if has_cursor then
      item.textEdit = {
        newText = insert_text,
        range = {
          start = {
            line = text_edit_line,
            character = token_start - 1,
          },
          ['end'] = {
            line = text_edit_line,
            character = text_edit_end_character,
          },
        },
      }
    end

    table.insert(items, item)
  end

  return items
end

source._dirname = function(self, params, option)
  local is_cmdline = vim.api.nvim_get_mode().mode == 'c'
  if is_cmdline then
    local expanded = self:_expand_cmdline_special_dirname(params.context.cursor_before_line)
    if expanded then
      return expanded
    end
  end

  local s = PATH_REGEX:match_str(params.context.cursor_before_line)
  if not s then
    return nil
  end

  local dirname = string.gsub(string.sub(params.context.cursor_before_line, s + 2), '%a*$', '') -- exclude '/'
  local prefix = string.sub(params.context.cursor_before_line, 1, s + 1) -- include '/'

  local buf_dirname = option.get_cwd(params)
  if is_cmdline then
    buf_dirname = vim.fn.getcwd()
  end
  if prefix:match('%.%./$') then
    return vim.fn.resolve(buf_dirname .. '/../' .. dirname)
  end
  if (prefix:match('%./$') or prefix:match('"$') or prefix:match('\'$')) then
    return vim.fn.resolve(buf_dirname .. '/' .. dirname)
  end
  if prefix:match('~/$') then
    return vim.fn.resolve(vim.fn.expand('~') .. '/' .. dirname)
  end
  local env_var_name = prefix:match('%$([%a_]+)/$')
  if env_var_name then
    local env_var_value = vim.fn.getenv(env_var_name)
    if env_var_value ~= vim.NIL then
      return vim.fn.resolve(env_var_value .. '/' .. dirname)
    end
  end
  if prefix:match('/$') then
    local accept = true
    -- Ignore URL components
    accept = accept and not prefix:match('%a/$')
    -- Ignore URL scheme
    accept = accept and not prefix:match('%a+:/$') and not prefix:match('%a+://$')
    -- Ignore HTML closing tags
    accept = accept and not prefix:match('</$')
    -- Ignore math calculation
    accept = accept and not prefix:match('[%d%)]%s*/$')
    -- Ignore / comment
    accept = accept and (not prefix:match('^[%s/]*$') or not self:_is_slash_comment())
    if accept then
      return vim.fn.resolve('/' .. dirname)
    end
  end
  return nil
end

source._candidates = function(_, dirname, include_hidden, option, callback)
  local fs, err = vim.loop.fs_scandir(dirname)
  if err then
    return callback(err, nil)
  end

  local items = {}

  local function create_item(name, fs_type)
    if not (include_hidden or string.sub(name, 1, 1) ~= '.') then
      return
    end

    local path = dirname .. '/' .. name
    local stat = vim.loop.fs_stat(path)
    local lstat = nil
    if stat then
      fs_type = stat.type
    elseif fs_type == 'link' then
      -- Broken symlink
      lstat = vim.loop.fs_lstat(dirname)
      if not lstat then
        return
      end
    else
      return
    end

    local item = {
      label = name,
      filterText = name,
      insertText = name,
      kind = cmp.lsp.CompletionItemKind.File,
      data = {
        path = path,
        type = fs_type,
        stat = stat,
        lstat = lstat,
      },
    }
    if fs_type == 'directory' then
      item.kind = cmp.lsp.CompletionItemKind.Folder
      if option.label_trailing_slash then
        item.label = name .. '/'
      else
        item.label = name
      end
      item.insertText = name .. '/'
      if not option.trailing_slash then
        item.word = name
      end
    end
    table.insert(items, item)
  end

  while true do
    local name, fs_type, e = vim.loop.fs_scandir_next(fs)
    if e then
      return callback(fs_type, nil)
    end
    if not name then
      break
    end
    create_item(name, fs_type)
  end

  callback(nil, items)
end

source._is_slash_comment = function(_)
  local commentstring = vim.bo.commentstring or ''
  local no_filetype = vim.bo.filetype == ''
  local is_slash_comment = false
  is_slash_comment = is_slash_comment or commentstring:match('/%*')
  is_slash_comment = is_slash_comment or commentstring:match('//')
  return is_slash_comment and not no_filetype
end

---@return cmp_path.Option
source._validate_option = function(_, params)
  local option = vim.tbl_deep_extend('keep', params.option, defaults)
  if vim.fn.has('nvim-0.11.2') == 1 then
    vim.validate('trailing_slash', option.trailing_slash, 'boolean')
    vim.validate('label_trailing_slash', option.label_trailing_slash, 'boolean')
    vim.validate('get_cwd', option.get_cwd, 'function')
  else
    vim.validate({
      trailing_slash = { option.trailing_slash, 'boolean' },
      label_trailing_slash = { option.label_trailing_slash, 'boolean' },
      get_cwd = { option.get_cwd, 'function' },
    })
  end
  return option
end

source._get_documentation = function(_, filename, count)
  local binary = assert(io.open(filename, 'rb'))
  local first_kb = binary:read(1024)
  if first_kb:find('\0') then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = 'binary file' }
  end

  local contents = {}
  for content in first_kb:gmatch("[^\r\n]+") do
    table.insert(contents, content)
    if count ~= nil and #contents >= count then
      break
    end
  end

  local filetype = vim.filetype.match({ filename = filename })
  if not filetype then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = table.concat(contents, '\n') }
  end

  table.insert(contents, 1, '```' .. filetype)
  table.insert(contents, '```')
  return { kind = cmp.lsp.MarkupKind.Markdown, value = table.concat(contents, '\n') }
end

return source
