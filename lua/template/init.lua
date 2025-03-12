local temp = {}
local uv, api, fn, fs = vim.loop, vim.api, vim.fn, vim.fs
local sep = uv.os_uname().sysname == 'Windows_NT' and '\\' or '/'

-- Variable storage for template processing session
local session_variables = {}

local cursor_pattern = '{{_cursor_}}'
local renderer = {
  expressions = {},
  expression_replacer_map = {}
}

---@param expr string
---@param replacer function(match: string): string
renderer.register = function (expr, replacer)
  if renderer.expression_replacer_map[expr] then
    vim.notify('The expression '..expr..' is registered already. Will not add the replacer.', vim.log.levels.ERROR)
    return
  end
  table.insert(renderer.expressions, expr)
  renderer.expression_replacer_map[expr] = replacer
end

renderer.register_builtins = function()
  renderer.register('{{_date_}}', function(_) return os.date('%Y-%m-%d %H:%M:%S') end)
  renderer.register(cursor_pattern, function(_) return '' end)
  renderer.register('{{_file_name_}}', function(_) return fn.expand('%:t:r') end)
  renderer.register('{{_author_}}', function(_) return temp.author end)
  renderer.register('{{_email_}}', function(_) return temp.email end)
  
  -- Enhanced variable handler with name support
  renderer.register('{{_variable:(.-)_}}', function(matched_expression)
    -- Extract the variable name from the pattern
        print("Matched Expression: " .. vim.inspect(matched_expression)) -- Debugging
    local var_name = matched_expression:match('{{_variable:(.-)_}}')
        print("Var Name (Initial): " .. vim.inspect(var_name)) -- Debugging
    if not var_name then
        vim.notify("Invalid variable pattern: " .. matched_expression, vim.log.levels.ERROR)
        return ""
    end
    -- If we already have this variable in the current session, use it
    if session_variables[var_name] and session_variables[var_name] ~= nil then
      return session_variables[var_name]
    end
    
    -- Otherwise prompt for it and store it
    local value = vim.fn.input(var_name .. ' name: ', '')
    session_variables[var_name] = value
    return value
  end)
  
  -- Keep the original variable handler for backward compatibility
  renderer.register('{{_variable_}}', function(_) return vim.fn.input('Variable name: ', '') end)
  
  renderer.register('{{_upper_file_}}', function(_) return string.upper(fn.expand('%:t:r')) end)
  renderer.register('{{_lua:(.-)_}}', function(matched_expression)
    return load('return ' .. matched_expression)()
  end)
  renderer.register('{{_tomorrow_}}', function()
    local t = os.date('*t')
    t.day = t.day + 1
    ---@diagnostic disable-next-line: param-type-mismatch
    return os.date('%c', os.time(t))
  end)
  renderer.register('{{_camel_file_}}', function(_)
      local file_name = fn.expand('%:t:r')
      local camel_case_file_name = ''
      local up_next = true
      for i = 1, #file_name do
        local char = file_name:sub(i,i)
        if char == '_' then
          up_next = true
        elseif up_next then
          camel_case_file_name = camel_case_file_name..string.upper(char)
          up_next = false
        else
          camel_case_file_name = camel_case_file_name..char
        end
      end
      return camel_case_file_name
  end)
end

renderer.render_line = function(line)
  local rendered = vim.deepcopy(line)
  for _, expr in ipairs(renderer.expressions) do
    if line:find(expr) then
      while rendered:match(expr) do
        local replacement = renderer.expression_replacer_map[expr](rendered:match(expr))
        rendered = rendered:gsub(expr, replacement, 1)
      end
    end
  end
  return rendered
end

function temp.get_temp_list()
  -- Normalize the temp directory path
  temp.temp_dir = fs.normalize(temp.temp_dir)
  
  -- Table to store results
  local res = {}

  -- Find files and links in the directory
  local result = vim.fs.find(function(name)
    return name:match('.*')  -- Match all files
  end, { type = 'file', path = temp.temp_dir, limit = math.huge })
  
  local link = vim.fs.find(function(name)
    return name:match('.*')  -- Match all links
  end, { type = 'link', path = temp.temp_dir, limit = math.huge })

  -- Combine files and links
  result = vim.list_extend(result, link)

  -- Iterate through the found files and determine filetypes
  for _, name in ipairs(result) do
    -- Determine the filetype using vim.filetype
    local ft = vim.filetype.match({ filename = name })

    -- Handle 'smarty' files with specific first-line processing
    if ft == 'smarty' then
      local first_row = vim.fn.readfile(name, '', 1)[1]
      ft = vim.split(first_row, '%s')[2]
    end

    -- If no filetype is found, determine based on file extension
    if not ft then
      if name:match("%.h$") then
        ft = "c"  -- C header files
      elseif name:match("%.html?$") then
        ft = "html"  -- HTML files
      end
    end

    -- If a filetype is determined, categorize the file
    if ft then
      if not res[ft] then
        res[ft] = {}
      end
      table.insert(res[ft], name)
    else
      -- Log a warning if no filetype could be determined
      vim.notify('[Template.nvim] Could not find the filetype of template file ' .. name, vim.log.levels.INFO)
    end
  end

  return res
end


-- Get list of project templates
function temp.get_project_templates()
  local project_dir = fs.normalize(temp.temp_dir .. sep .. 'project_templates')
  
  -- Check if project_templates directory exists
  local stat = uv.fs_stat(project_dir)
  if not stat or stat.type ~= 'directory' then
    return {}
  end
  
  local templates = {}
  
  -- Find all directories in project_templates
  local dirs = vim.fs.find(function(name, _)
    return true  -- match all
  end, { type = 'directory', path = project_dir, limit = math.huge })
  
  -- Add directory names as available templates
  for _, dir in ipairs(dirs) do
    local name = vim.fn.fnamemodify(dir, ':t')
    table.insert(templates, name)
  end
  
  return templates
end

local function expand_expressions(line)
  local cursor

  if line:find(cursor_pattern) then
    cursor = true
  end

  line = renderer.render_line(line)

  return line, cursor
end

--@private
local function create_and_load(file)
  local current_path = fn.getcwd()
  file = current_path .. sep .. file
  local ok, fd = pcall(uv.fs_open, file, 'w', 420)
  if not ok then
    vim.notify("Couldn't create file " .. file)
    return
  end
  uv.fs_close(fd)

  vim.cmd(':e ' .. file)
end

-- Create directory if it doesn't exist
local function create_directory(path)
  local stat = uv.fs_stat(path)
  if stat and stat.type == 'directory' then
    return true
  end
  
  return uv.fs_mkdir(path, 493) -- 0755 permissions
end

-- Parse arguments for Template command
local function parse_args(args)
  local data = {}
  
  -- If there's only one argument, it's the template name
  if #args == 1 then
    data.tp_name = args[1]
    data.file = args[1]
  -- If there are two or more arguments, first is file name, second is template name
  elseif #args >= 2 then
    data.file = args[1]
    data.tp_name = args[2]
  end
  
  return data
end

-- Parse arguments for TemProject command
local function parse_project_args(args)
  local data = {}
  
  -- If there's only one argument, it's the project template name
  if #args == 1 then
    data.tp_name = args[1]
    data.project_name = args[1]
  -- If there are two or more arguments, first is project name, second is template name
  elseif #args >= 2 then
    data.project_name = args[1]
    data.tp_name = args[2]
  end
  
  return data
end

local function async_read(path, callback)
  uv.fs_open(path, 'r', 438, function(err, fd)
    assert(not err, err)
    ---@diagnostic disable-next-line: redefined-local
    uv.fs_fstat(fd, function(err, stat)
      assert(not err, err)
      ---@diagnostic disable-next-line: redefined-local
      uv.fs_read(fd, stat.size, 0, function(err, data)
        assert(not err, err)
        ---@diagnostic disable-next-line: redefined-local
        uv.fs_close(fd, function(err)
          assert(not err, err)
          return callback(data)
        end)
      end)
    end)
  end)
end

local function get_tpl(buf, name)
  local list = temp.get_temp_list()
  if not list[vim.bo[buf].filetype] then
    return
  end

  for _, v in ipairs(list[vim.bo[buf].filetype]) do
    if v:find(name) then
      return v
    end
  end
end

function temp:generate_template(args)
  local data = parse_args(args)

  if data.file then
    create_and_load(data.file)
  end

  local current_buf = api.nvim_get_current_buf()

  local tpl = get_tpl(current_buf, data.tp_name)
  if not tpl then
    return
  end

  local lines = {}

  -- Clear session variables for new template
  session_variables = {}

  async_read(
    tpl,
    ---@diagnostic disable-next-line: redefined-local
    vim.schedule_wrap(function(data)
      local cursor_pos = {}
      data = data:gsub('\r\n?', '\n')
      local tbl = vim.split(data, '\n')

      local skip_lines = 0

      for i, v in ipairs(tbl) do
        if i == 1 then
          local line_data = vim.split(v, '%s')
          if #line_data == 2 and ";;" == line_data[1] then
            skip_lines = skip_lines + 1
            goto continue
          end
        end
        local line, cursor = expand_expressions(v)
        lines[#lines + 1] = line
        if cursor then
          cursor_pos = { i - skip_lines, 2 }
        end
        ::continue::
      end

      local cur_line = api.nvim_win_get_cursor(0)[1]
      local start = cur_line
      if cur_line == 1 and #api.nvim_get_current_line() == 0 then
        start = cur_line - 1
      end
      api.nvim_buf_set_lines(current_buf, start, cur_line, false, lines)
      cursor_pos[1] = start ~= 0 and cur_line + cursor_pos[1] or cursor_pos[1]

      if next(cursor_pos) ~= nil then
        api.nvim_win_set_cursor(0, cursor_pos)
        vim.cmd('startinsert!')
      end
    end)
  )
end

-- Process a single file from project template
local function process_template_file(src_file, dest_file)
  local stat = uv.fs_stat(src_file)
  if not stat then
    vim.notify('[Template.nvim] Failed to stat file: ' .. src_file, vim.log.levels.ERROR)
    return false
  end
  
  -- Read source file
  local fd = uv.fs_open(src_file, 'r', 438)
  if not fd then
    vim.notify('[Template.nvim] Failed to open file: ' .. src_file, vim.log.levels.ERROR)
    return false
  end
  
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  
  if not data then
    vim.notify('[Template.nvim] Failed to read file: ' .. src_file, vim.log.levels.ERROR)
    return false
  end
  
  -- Process file content with template engine
  data = data:gsub('\r\n?', '\n')
  local lines = vim.split(data, '\n')
  local processed_lines = {}
  
  local skip_lines = 0
  for i, line in ipairs(lines) do
    if i == 1 then
      local line_data = vim.split(line, '%s')
      if #line_data == 2 and ";;" == line_data[1] then
        skip_lines = skip_lines + 1
        goto continue
      end
    end
    
    local processed_line = renderer.render_line(line)
    table.insert(processed_lines, processed_line)
    
    ::continue::
  end
  
  -- Write processed content to destination file
  local out_fd = uv.fs_open(dest_file, 'w', 438)
  if not out_fd then
    vim.notify('[Template.nvim] Failed to create file: ' .. dest_file, vim.log.levels.ERROR)
    return false
  end
  
  uv.fs_write(out_fd, table.concat(processed_lines, '\n'))
  uv.fs_close(out_fd)
  
  return true
end

-- Recursively process a project template directory
local function process_project_directory(src_dir, dest_dir)
  -- Create destination directory
  if not create_directory(dest_dir) then
    vim.notify('[Template.nvim] Failed to create directory: ' .. dest_dir, vim.log.levels.ERROR)
    return false
  end
  
  -- Get all entries in source directory
  local dir_handle = uv.fs_scandir(src_dir)
  if not dir_handle then
    vim.notify('[Template.nvim] Failed to scan directory: ' .. src_dir, vim.log.levels.ERROR)
    return false
  end
  
  local name, type
  while true do
    name, type = uv.fs_scandir_next(dir_handle)
    if not name then break end
    
    local src_path = src_dir .. sep .. name
    local dest_path = dest_dir .. sep .. name
    
    if type == 'directory' then
      -- Recursively process subdirectory
      process_project_directory(src_path, dest_path)
    else
      -- Process file
      process_template_file(src_path, dest_path)
    end
  end
  
  return true
end

-- Generate a complete project from template
function temp:generate_project(args)
  local data = parse_project_args(args)
  if not data.tp_name or not data.project_name then
    vim.notify('[Template.nvim] Missing project name or template name', vim.log.levels.ERROR)
    return
  end
  
  -- Get source template directory
  local template_dir = fs.normalize(temp.temp_dir .. sep .. 'project_templates' .. sep .. data.tp_name)
  local stat = uv.fs_stat(template_dir)
  if not stat or stat.type ~= 'directory' then
    vim.notify('[Template.nvim] Project template not found: ' .. data.tp_name, vim.log.levels.ERROR)
    return
  end
  
  -- Create destination directory
  local current_path = fn.getcwd()
  local project_path = current_path .. sep .. data.project_name
  
  -- Clear session variables for new project
  session_variables = {}
  
  -- Process the entire project
  if process_project_directory(template_dir, project_path) then
    vim.notify('[Template.nvim] Project generated successfully: ' .. data.project_name, vim.log.levels.INFO)
    
    -- Open the project directory in Neovim
    vim.cmd('cd ' .. vim.fn.fnameescape(project_path))
  else
    vim.notify('[Template.nvim] Failed to generate project: ' .. data.project_name, vim.log.levels.ERROR)
  end
end

function temp.in_template(buf)
  local list = temp.get_temp_list()
  if vim.tbl_isempty(list) or not list[vim.bo[buf].filetype] then
    return false
  end
  local bufname = api.nvim_buf_get_name(buf)

  if vim.tbl_contains(list[vim.bo[buf].filetype], bufname) then
    return true
  end

  return false
end

temp.register = renderer.register

function temp.setup(config)
  renderer.register_builtins()
  vim.validate({
    config = { config, 't' },
  })

  if not config.temp_dir then
    vim.notify('[template.nvim] please config the temp_dir variable')
    return
  end

  temp.temp_dir = config.temp_dir

  temp.author = config.author and config.author or ''
  temp.email = config.email and config.email or ''

  local fts = vim.tbl_keys(temp.get_temp_list())

  if #fts == 0 then
    vim.notify('[template.nvim] does not get the filetype in template dir')
    return
  end

  api.nvim_create_autocmd({ 'BufEnter', 'BufNewFile' }, {
    pattern = temp.temp_dir .. '/*',
    group = api.nvim_create_augroup('Template', { clear = false }),
    callback = function(opt)
      if vim.bo[opt.buf].filetype == 'smarty' then
        local fname = api.nvim_buf_get_name(opt.buf)
        local row = vim.fn.readfile(fname, '', 1)[1]
        local lang = vim.split(row, '%s')[2]
        vim.treesitter.start(opt.buf, lang)
        api.nvim_buf_add_highlight(opt.buf, 0, 'Comment', 0, 0, -1)
        return
      end

      if temp.in_template(opt.buf) then
        vim.diagnostic.disable(opt.buf)
      end
    end,
  })
end

-- Clear variable session cache (useful for testing)
temp.clear_variables = function()
  session_variables = {}
  vim.notify("Variable cache cleared", vim.log.levels.INFO)
end

return temp
