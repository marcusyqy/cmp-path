package.preload['cmp'] = function()
  return {
    lsp = {
      CompletionItemKind = {
        File = 1,
        Folder = 2,
      },
      MarkupKind = {
        PlainText = 'plaintext',
        Markdown = 'markdown',
      },
    },
  }
end

local repo_root = vim.fn.getcwd()
package.path = table.concat({
  repo_root .. '/lua/?.lua',
  repo_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local function assert_eq(actual, expected, name)
  if actual ~= expected then
    error(string.format('[%s] expected %s, got %s', name, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_contains_label(items, expected, name)
  for _, item in ipairs(items) do
    if item.label == expected then
      return item
    end
  end
  error(string.format('[%s] expected label %s in %s', name, vim.inspect(expected), vim.inspect(items)))
end

local function run()
  local tmp = vim.fn.tempname() .. '-cmp-path'
  local cfg_dir = tmp .. '/nvim'
  assert_eq(vim.fn.mkdir(cfg_dir, 'p'), 1, 'mkdir fixture')
  assert_eq(vim.fn.writefile({ '-- fixture' }, cfg_dir .. '/init.lua'), 0, 'write fixture')

  vim.cmd('cd ' .. vim.fn.fnameescape(tmp))
  vim.cmd('edit nvim/init.lua')

  local source = require('cmp_path').new()
  vim.api.nvim_get_mode = function()
    return { mode = 'c' }
  end

  local params = {
    context = {
      bufnr = vim.api.nvim_get_current_buf(),
    },
  }
  local option = {
    get_cwd = function()
      return vim.fn.getcwd()
    end,
  }

  local expected_dir = vim.fn.resolve(cfg_dir)
  local parent_dir = vim.fn.resolve(vim.fn.fnamemodify(tmp, ':h'))
  local cwd_dir = vim.fn.resolve(tmp)

  local cases = {
    { name = 'special %:h slash', line = ':e %:h/fo', expected = expected_dir },
    { name = 'special %:h only slash', line = ':e %:h/', expected = expected_dir },
    { name = 'special %:p:h slash', line = ':e %:p:h/fo', expected = expected_dir },
    { name = 'relative dot', line = ':e ./fo', expected = cwd_dir },
    { name = 'relative dotdot', line = ':e ../fo', expected = parent_dir },
    { name = 'root absolute', line = ':e /usr/bi', expected = '/usr' },
    { name = 'special no trailing slash', line = ':e %:h', expected = nil },
  }

  for _, case in ipairs(cases) do
    params.context.cursor_before_line = case.line
    local actual = source:_dirname(params, option)
    assert_eq(actual, case.expected, case.name)
  end

  local complete_cases = {
    { name = 'special percent completion', line = ':e %', label = 'nvim/init.lua', expect_new_text = 'nvim/init.lua' },
    { name = 'special percent head completion', line = ':e %:h', label = 'nvim/', expect_new_text = 'nvim' },
  }
  for _, case in ipairs(complete_cases) do
    local items = nil
    local cursor_col = #case.line + 1
    local token_start = #case.line - #string.match(case.line, '%S+$') + 1
    source:complete({
      context = {
        bufnr = params.context.bufnr,
        cursor_before_line = case.line,
        cursor = {
          row = 1,
          col = cursor_col,
        },
      },
      offset = 1,
      option = {},
    }, function(response)
      items = response
    end)
    if not items then
      error(string.format('[%s] completion callback returned nil', case.name))
    end
    local item = assert_contains_label(items, case.label, case.name)
    assert_eq(item.textEdit.newText, case.expect_new_text, case.name .. ' textEdit newText')
    assert_eq(item.textEdit.range.start.character, token_start - 1, case.name .. ' textEdit start')
    assert_eq(item.textEdit.range['end'].character, cursor_col - 1, case.name .. ' textEdit end')
  end

  do
    local keyword = source:get_keyword_pattern({})
    local token_start = vim.regex([[\%(]] .. keyword .. [[\)\m$]]):match_str(':e %')
    assert_eq(token_start and (token_start + 1) or nil, 4, 'special percent keyword offset')
  end

  local original_getcompletion = vim.fn.getcompletion
  vim.fn.getcompletion = function(arglead, completion_type)
    if completion_type == 'file' and arglead == '%' then
      return { '%nvim/init.lua' }
    end
    return original_getcompletion(arglead, completion_type)
  end
  do
    local line = ':e %'
    local cursor_col = #line + 1
    local items = nil
    source:complete({
      context = {
        bufnr = params.context.bufnr,
        cursor_before_line = line,
        cursor = {
          row = 1,
          col = cursor_col,
        },
      },
      offset = 1,
      option = {},
    }, function(response)
      items = response
    end)
    if not items then
      error('[special percent prefixed completion] completion callback returned nil')
    end
    local item = assert_contains_label(items, 'nvim/init.lua', 'special percent prefixed completion')
    assert_eq(item.textEdit.newText, 'nvim/init.lua', 'special percent prefixed completion textEdit newText')
  end
  vim.fn.getcompletion = original_getcompletion
end

run()
