local M = {}

local config = {
  openai_api_key = nil, -- Will be read from env var OPENAI_API_KEY if not set
  model = "qwen-plus",
  api_url = "https://api.openai.com/v1/chat/completions",
  max_tokens = 4096,
  system_prompt = [[You are a specialized Git commit message generator. The user provides the result of running `git diff --cached`. Your task is to create clear, structured, and informative commit messages that follow a specific format:

1. First line: A concise title (60-72 characters) that summarizes the change using imperative mood
2. Followed by a blank line
3. Then a bulleted list of specific changes, each starting with a present-tense action verb

RULES:
- Title must be specific and descriptive
- Use imperative mood in title (e.g., "Add", "Fix", "Update", not "Added", "Fixed", "Updated")
- Keep the title under 72 characters
- Each bullet point should start with "- " followed by a present-tense action verb
- Bullet points should be concise but informative about what changed and why
- Keep total bullet points at most 3-5, for simple changes 1 bullet point
- Organize bullet points in order of importance
- Highlight important technical details that would be relevant to other developers
- Do not include unnecessary details or explanations that belong in documentation
- Focus on WHAT changed and WHY, not HOW

Avoid vague messages like "Fix bug" or "Update code" - be specific about what was fixed or updated.]],

  system_prompt_zh = [[你是一个专业的 Git 提交信息生成器。用户提供 `git diff --cached` 的结果。你的任务是创建清晰、结构化且信息丰富的中文提交信息，遵循以下格式：

1. 第一行：简洁的标题（60-72字符）概括变更内容
2. 空一行
3. 然后是具体变更的列表，每项以动词开头

规则：
- 标题必须具体且描述性强
- 标题使用祈使语气（例如："添加"、"修复"、"更新"）
- 保持标题在 72 字符以内
- 每个列表项应以 "- " 开头，后跟动词
- 列表项应简洁但信息丰富，说明改变了什么以及为什么
- 列表项总数最多 3-5 个，简单变更可以只有 1 个
- 按重要性组织列表项
- 突出对其他开发者重要的技术细节
- 不要包含不必要的细节或属于文档的说明
- 关注改变了什么（WHAT）以及为什么（WHY），而不是怎么做（HOW）

避免使用模糊的信息，如"修复 bug"或"更新代码"——要具体说明修复或更新了什么。]]
}

local function get_api_key()
  -- First try to get from environment variable
  local env_key = vim.env.OPENAI_API_KEY
  if env_key and env_key ~= "" then
    return env_key
  end
  
  -- Fallback to configured key
  return config.openai_api_key
end

-- Setup keymaps using autocmd
local function setup_keymaps()
  local group = vim.api.nvim_create_augroup("NeogitAICommit", { clear = true })
  
  -- Set up autocmd for gitcommit filetype
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "gitcommit",
    callback = function(ev)
      -- Set up keymaps for both normal and insert mode
      vim.keymap.set({ "n", "i" }, "<C-c><return>", function()
        M.generate_commit_message(ev.buf)
      end, { buffer = ev.buf, desc = "Generate commit message" })

      vim.keymap.set({ "n", "i" }, "<C-c><C-m>", function()
        M.generate_commit_message(ev.buf)
      end, { buffer = ev.buf, desc = "Generate commit message" })

      vim.keymap.set({ "n", "i" }, "<C-c>m", function()
        M.generate_commit_message_in_zh(ev.buf)
      end, { buffer = ev.buf, desc = "生成提交信息" })

      -- Print a message to confirm the keymap is set
      vim.notify("Press <C-c><C-m>) to generate commit message using AI", vim.log.levels.INFO)
    end,
  })
end

-- Function to get lines from a buffer
local function get_buffer_lines(bufnr, start_line, end_line)
  return vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
end

-- Function to set lines in a buffer
local function set_buffer_lines(bufnr, start_line, end_line, lines)
  vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, lines)
end

function M.generate_commit_message(bufnr)
  local api_key = get_api_key()
  if not api_key then
    vim.notify("OpenAI API key not found. Please set OPENAI_API_KEY environment variable or configure via setup()", vim.log.levels.ERROR)
    return
  end

  local git = require("neogit.lib.git")
  local staged_diff = git.cli.diff.cached.call().stdout
  if #staged_diff == 0 then
    vim.notify("No staged changes to generate commit message from", vim.log.levels.WARN)
    return
  end

  -- Get all lines from the buffer to check for user input
  local lines = get_buffer_lines(bufnr, 0, -1)
  local comment_char = git.config.get("core.commentChar"):read() or "#"
  local comment_pattern = "^" .. comment_char
  
  -- Find the first comment line and extract user input before it
  local user_input_lines = {}
  local first_comment_start = -1
  
  for i, line in ipairs(lines) do
    if line:match(comment_pattern) then
      first_comment_start = i - 1  -- Convert to 0-based index
      break
    end
    table.insert(user_input_lines, line)
  end
  
  -- Remove trailing empty lines from user input
  while #user_input_lines > 0 and user_input_lines[#user_input_lines]:match("^%s*$") do
    table.remove(user_input_lines)
  end

  -- Join the diff lines with newlines
  local diff_content = table.concat(staged_diff, "\n")
  
  -- Debug info
  vim.notify("Diff content length: " .. #diff_content .. " characters", vim.log.levels.INFO)

  vim.notify("User input lines: " .. #user_input_lines, vim.log.levels.INFO)

  -- Show a loading message
  vim.notify("Generating commit message...", vim.log.levels.INFO)

  -- Prepare the user content to send to AI
  local user_content = diff_content
  if #user_input_lines > 0 then
    local user_prefix = table.concat(user_input_lines, "\n")
    user_content = "The user has already started writing the following commit message:\n\n" .. user_prefix .. "\n\nPlease complete or improve this commit message based on the following staged changes:\n\n" .. diff_content
  end

  -- Make the API request
  local curl = require("plenary.curl")
  local response = curl.post(config.api_url, {
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key
    },
    body = vim.fn.json_encode({
      model = config.model,
      messages = {
        { role = "system", content = config.system_prompt },
        { role = "user", content = user_content }
      },
      stream = false,
    })
  })

  if response.status ~= 200 then
    vim.notify("Failed to generate commit message: " .. response.body, vim.log.levels.ERROR)
    return
  end

  local result = vim.fn.json_decode(response.body)
  if not result or not result.choices or #result.choices == 0 then
    vim.notify("Invalid response from OpenAI API", vim.log.levels.ERROR)
    return
  end

  local commit_message = result.choices[1].message.content

  -- Get all lines from the buffer again
  lines = get_buffer_lines(bufnr, 0, -1)
  
  -- Find the comment section
  if first_comment_start == -1 then
    for i, line in ipairs(lines) do
      if line:match(comment_pattern) then
        first_comment_start = i - 1
        break
      end
    end
  end

  if first_comment_start >= 0 then
    -- Get the comment section
    local comment_lines = {}
    local in_comment = false
    
    for i = first_comment_start + 1, #lines do
      local line = lines[i]
      if line:match(comment_pattern) then
        if not in_comment then
          in_comment = true
        end
        table.insert(comment_lines, line)
      elseif in_comment then
        break
      end
    end

    -- Clear the buffer
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    
    -- Insert the generated message (which already includes user's input)
    local message_lines = vim.split(commit_message, "\n")
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, message_lines)
    
    -- Add a blank line between message and comments if needed
    if #message_lines > 0 then
      local last_line = vim.api.nvim_buf_get_lines(bufnr, #message_lines - 1, #message_lines, false)[1]
      if last_line and not last_line:match("^%s*$") then
        vim.api.nvim_buf_set_lines(bufnr, #message_lines, #message_lines, false, {""})
      end
    end
    
    -- Add the comment section
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, comment_lines)
  else
    -- No comments found, just set the message
    -- Clear the buffer
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    
    -- Insert the generated message (which already includes user's input)
    local message_lines = vim.split(commit_message, "\n")
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, message_lines)
  end

  vim.notify("Commit message generated!", vim.log.levels.INFO)
end


function M.generate_commit_message_in_zh(bufnr)
  local api_key = get_api_key()
  if not api_key then
    vim.notify("未找到 OpenAI API 密钥。请设置 OPENAI_API_KEY 环境变量或通过 setup() 配置", vim.log.levels.ERROR)
    return
  end

  local git = require("neogit.lib.git")
  local staged_diff = git.cli.diff.cached.call().stdout
  if #staged_diff == 0 then
    vim.notify("没有暂存的更改来生成提交信息", vim.log.levels.WARN)
    return
  end

  -- Get all lines from the buffer to check for user input
  local lines = get_buffer_lines(bufnr, 0, -1)
  local comment_char = git.config.get("core.commentChar"):read() or "#"
  local comment_pattern = "^" .. comment_char

  -- Find the first comment line and extract user input before it
  local user_input_lines = {}
  local first_comment_start = -1

  for i, line in ipairs(lines) do
    if line:match(comment_pattern) then
      first_comment_start = i - 1  -- Convert to 0-based index
      break
    end
    table.insert(user_input_lines, line)
  end

  -- Remove trailing empty lines from user input
  while #user_input_lines > 0 and user_input_lines[#user_input_lines]:match("^%s*$") do
    table.remove(user_input_lines)
  end

  -- Join the diff lines with newlines
  local diff_content = table.concat(staged_diff, "\n")

  -- Show a loading message
  vim.notify("正在生成中文提交信息...", vim.log.levels.INFO)

  -- Prepare the user content to send to AI
  local user_content = diff_content
  if #user_input_lines > 0 then
    local user_prefix = table.concat(user_input_lines, "\n")
    user_content = "用户已经写下了以下提交信息：\n\n" .. user_prefix .. "\n\n请根据以下暂存的更改完成或改进此提交信息：\n\n" .. diff_content
  end

  -- Make the API request
  local curl = require("plenary.curl")
  local response = curl.post(config.api_url, {
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key
    },
    body = vim.fn.json_encode({
      model = config.model,
      messages = {
        { role = "system", content = config.system_prompt_zh },
        { role = "user", content = user_content }
      },
      stream = false,
    })
  })

  if response.status ~= 200 then
    vim.notify("生成提交信息失败: " .. response.body, vim.log.levels.ERROR)
    return
  end

  local result = vim.fn.json_decode(response.body)
  if not result or not result.choices or #result.choices == 0 then
    vim.notify("OpenAI API 返回无效响应", vim.log.levels.ERROR)
    return
  end

  local commit_message = result.choices[1].message.content

  -- Get all lines from the buffer again
  lines = get_buffer_lines(bufnr, 0, -1)

  -- Find the comment section
  if first_comment_start == -1 then
    for i, line in ipairs(lines) do
      if line:match(comment_pattern) then
        first_comment_start = i - 1
        break
      end
    end
  end

  if first_comment_start >= 0 then
    -- Get the comment section
    local comment_lines = {}
    local in_comment = false

    for i = first_comment_start + 1, #lines do
      local line = lines[i]
      if line:match(comment_pattern) then
        if not in_comment then
          in_comment = true
        end
        table.insert(comment_lines, line)
      elseif in_comment then
        break
      end
    end

    -- Clear the buffer
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

    -- Insert the generated message (which already includes user's input)
    local message_lines = vim.split(commit_message, "\n")
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, message_lines)

    -- Add a blank line between message and comments if needed
    if #message_lines > 0 then
      local last_line = vim.api.nvim_buf_get_lines(bufnr, #message_lines - 1, #message_lines, false)[1]
      if last_line and not last_line:match("^%s*$") then
        vim.api.nvim_buf_set_lines(bufnr, #message_lines, #message_lines, false, {""})
      end
    end

    -- Add the comment section
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, comment_lines)
  else
    -- No comments found, just set the message
    -- Clear the buffer
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

    -- Insert the generated message (which already includes user's input)
    local message_lines = vim.split(commit_message, "\n")
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, message_lines)
  end

  vim.notify("提交信息已生成！", vim.log.levels.INFO)
end

-- Function to get current buffer if it's a commit message buffer
local function get_commit_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype == "gitcommit" then
    return bufnr
  end
  return nil
end

-- Create the Neovim command
local function create_commands()
  vim.api.nvim_create_user_command("NeogitAICommit", function()
    local bufnr = get_commit_buffer()
    if not bufnr then
      vim.notify("This command can only be used in a git commit message buffer", vim.log.levels.ERROR)
      return
    end
    M.generate_commit_message(bufnr)
  end, {
    desc = "Generate AI-powered commit message"
  })

  vim.api.nvim_create_user_command("NeogitAICommitZh", function()
    local bufnr = get_commit_buffer()
    if not bufnr then
      vim.notify("此命令只能在 git 提交信息缓冲区中使用", vim.log.levels.ERROR)
      return
    end
    M.generate_commit_message_in_zh(bufnr)
  end, {
    desc = "生成 AI 驱动的中文提交信息"
  })
end

function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", config, opts)
  setup_keymaps()
  create_commands()
end

return M
