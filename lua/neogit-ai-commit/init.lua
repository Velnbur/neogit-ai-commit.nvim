local M = {}

local providers = {
  openai = {
    api_url     = "https://api.openai.com/v1/chat/completions",
    model       = "gpt-4o-mini",
    api_key_env = "OPENAI_API_KEY",
  },
  mistral = {
    api_url     = "https://api.mistral.ai/v1/chat/completions",
    model       = "mistral-small-latest",
    api_key_env = "MISTRAL_API_KEY",
  },
}

local config = {
  openai_api_key = nil, -- Will be read from env var specified by api_key_env if not set
  api_key_env = "OPENAI_API_KEY",
  model = "qwen-plus",
  api_url = "https://api.openai.com/v1/chat/completions",
  max_tokens = 4096,
  temperature = 0.2,
  confirm_send = true,
  timeout = 30,
  system_prompt = [[Output only the raw commit message text — no explanations, no markdown, no code fences.

You are a Git commit message generator. Given a staged diff, produce one commit message in this exact format:

1. Subject line: under 72 characters, imperative mood, specific and descriptive
2. Second line: blank (no spaces)
3. Body: 1–5 bullet points, each starting with "- " followed by an imperative verb

RULES:
- Use imperative mood throughout (Add, Fix, Remove — not Added, Fixed, Removed)
- Each bullet point should start with "- " followed by an imperative verb (Add, Fix, Remove, Update…)
- Focus on what changed and why, not how
- For simple changes, one bullet point is enough; use up to 5 for complex ones
- Organize bullets in order of importance
- Bad subject: "Fix bug" — Good subject: "Fix null pointer in session teardown"]],

}

-- Strip markdown code fences and trailing explanatory text from AI response
local function clean_commit_message(message)
  -- Remove wrapping ```...``` code fences
  message = message:gsub("^%s*```[^\n]*\n", "")
  message = message:gsub("\n```%s*$", "")
  message = message:gsub("^%s*```%s*$", "")

  -- Trim leading/trailing whitespace
  message = message:gsub("^%s+", ""):gsub("%s+$", "")

  -- Ensure second line is truly empty (no whitespace)
  local lines = vim.split(message, "\n")
  if #lines >= 2 and lines[2]:match("^%s+$") then
    lines[2] = ""
  end

  return table.concat(lines, "\n")
end

local function get_api_key()
  local env_key = vim.env[config.api_key_env or "OPENAI_API_KEY"]
  if env_key and env_key ~= "" then
    return env_key
  end
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
    vim.notify(
      "API key not found. Set the " .. (config.api_key_env or "OPENAI_API_KEY")
        .. " environment variable or configure openai_api_key via setup()",
      vim.log.levels.ERROR
    )
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

  if not vim.startswith(config.api_url, "https://") then
    vim.notify("Warning: api_url does not use HTTPS. The diff and API key will be sent unencrypted.", vim.log.levels.WARN)
  end

  if config.confirm_send then
    local hostname = config.api_url:match("https?://([^/:]+)") or config.api_url
    local choice = vim.fn.confirm(
      "Send " .. #diff_content .. " bytes to " .. hostname .. "?",
      "&Yes\n&No", 1)
    if choice ~= 1 then
      vim.notify("Commit message generation cancelled.", vim.log.levels.INFO)
      return
    end
  end

  -- Show a loading message
  vim.notify("Generating commit message...", vim.log.levels.INFO)

  -- Prepare the user content to send to AI
  local user_content = diff_content
  if #user_input_lines > 0 then
    local user_prefix = table.concat(user_input_lines, "\n")
    user_content = "The user has already started writing the following commit message:\n\n" .. user_prefix .. "\n\nPlease complete or improve this commit message based on the following staged changes:\n\n" .. diff_content
  end

  -- Make the API request
  local messages = {
    { role = "system", content = config.system_prompt },
    { role = "user",   content = user_content },
  }
  -- Mistral-specific: force the model to begin its reply immediately (no preamble)
  if config.provider == "mistral" then
    table.insert(messages, { role = "assistant", content = "", prefix = true })
  end

  local curl = require("plenary.curl")
  local response = curl.post(config.api_url, {
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key
    },
    body = vim.fn.json_encode({
      model       = config.model,
      messages    = messages,
      temperature = config.temperature,
      stream      = false,
    }),
    timeout = config.timeout,
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

  local commit_message = clean_commit_message(result.choices[1].message.content)

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

end

M._clean_commit_message = clean_commit_message
M._get_api_key = get_api_key

function M.setup(opts)
  opts = opts or {}
  if opts.provider and providers[opts.provider] then
    config = vim.tbl_deep_extend("force", config, providers[opts.provider])
  end
  config = vim.tbl_deep_extend("force", config, opts)
  M._config = config
  setup_keymaps()
  create_commands()
end

return M
