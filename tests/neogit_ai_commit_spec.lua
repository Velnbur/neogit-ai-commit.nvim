local eq = assert.are.equal

-- Stub out heavy dependencies before the plugin is loaded
package.loaded["neogit.lib.git"] = {
  cli = {
    diff = {
      cached = {
        call = function()
          return { stdout = { "diff --git a/foo.lua b/foo.lua", "+added line" } }
        end,
      },
    },
  },
  config = {
    get = function()
      return { read = function() return "#" end }
    end,
  },
}

package.loaded["plenary.curl"] = {
  post = function(_, opts)
    _G._curl_last_opts = opts
    return _G._curl_fixture or {
      status = 200,
      body = vim.fn.json_encode({
        choices = { { message = { content = "Add feature\n\n- Implement new behavior" } } },
      }),
    }
  end,
}

local plugin = require("neogit-ai-commit")
plugin.setup({ openai_api_key = "test-key", confirm_send = false })

-- Default confirm stub: always Yes (overridden per-test where needed)
vim.fn.confirm = function() return 1 end

-- ---------------------------------------------------------------------------
-- clean_commit_message
-- ---------------------------------------------------------------------------

describe("clean_commit_message", function()
  local clean = plugin._clean_commit_message

  it("passes through a plain message unchanged", function()
    local msg = "Add feature\n\n- Do thing"
    eq(msg, clean(msg))
  end)

  it("strips plain backtick code fences", function()
    eq("Add feature\n\n- Do thing", clean("```\nAdd feature\n\n- Do thing\n```"))
  end)

  it("strips fences with a language specifier", function()
    eq("Add feature\n\n- Do thing", clean("```text\nAdd feature\n\n- Do thing\n```"))
  end)

  it("trims leading and trailing whitespace", function()
    eq("Add feature", clean("  \nAdd feature\n  "))
  end)

  it("normalises a whitespace-only second line to an empty string", function()
    local result = clean("Add feature\n   \n- Do thing")
    local lines = vim.split(result, "\n")
    eq("", lines[2])
  end)

  it("leaves an already-empty second line alone", function()
    local result = clean("Add feature\n\n- Do thing")
    local lines = vim.split(result, "\n")
    eq("", lines[2])
  end)
end)

-- ---------------------------------------------------------------------------
-- generate_commit_message – buffer manipulation
-- ---------------------------------------------------------------------------

describe("generate_commit_message", function()
  local function make_buf(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(bufnr, "filetype", "gitcommit")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  local function buf_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  before_each(function()
    _G._curl_fixture = nil
    _G._curl_last_opts = nil
    -- Restore default setup (confirm_send off, default timeout, default url)
    plugin.setup({
      openai_api_key = "test-key",
      confirm_send = false,
      timeout = 30,
      api_url = "https://api.openai.com/v1/chat/completions",
      api_key_env = "OPENAI_API_KEY",
    })
    vim.fn.confirm = function() return 1 end
  end)

  it("inserts the AI message when buffer has only comment lines", function()
    local bufnr = make_buf({ "# On branch main", "# Changes to be committed:" })
    plugin.generate_commit_message(bufnr)
    local lines = buf_lines(bufnr)
    eq("Add feature", lines[1])
    eq("", lines[2])
    eq("- Implement new behavior", lines[3])
  end)

  it("preserves comment section after the generated message", function()
    local bufnr = make_buf({ "# On branch main", "# Changes to be committed:" })
    plugin.generate_commit_message(bufnr)
    local lines = buf_lines(bufnr)
    local found = false
    for _, l in ipairs(lines) do
      if l == "# On branch main" then found = true end
    end
    assert.is_true(found, "comment line '# On branch main' should still be present")
  end)

  it("replaces user-typed prefix with the AI message", function()
    local bufnr = make_buf({ "WIP: something", "", "# On branch main" })
    plugin.generate_commit_message(bufnr)
    local lines = buf_lines(bufnr)
    eq("Add feature", lines[1])
  end)

  it("comment lines are not duplicated", function()
    local bufnr = make_buf({ "# On branch main" })
    plugin.generate_commit_message(bufnr)
    local lines = buf_lines(bufnr)
    local count = 0
    for _, l in ipairs(lines) do
      if l == "# On branch main" then count = count + 1 end
    end
    eq(1, count)
  end)

  it("sets message when buffer has no comment lines", function()
    local bufnr = make_buf({})
    plugin.generate_commit_message(bufnr)
    local lines = buf_lines(bufnr)
    eq("Add feature", lines[1])
  end)

  it("shows an error notification when the API returns non-200", function()
    _G._curl_fixture = { status = 500, body = "Internal Server Error" }
    local notified = nil
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified = msg end
    end
    local bufnr = make_buf({ "# comment" })
    plugin.generate_commit_message(bufnr)
    vim.notify = orig
    assert.is_not_nil(notified)
    assert.truthy(notified:match("Failed to generate"))
  end)

  it("strips code fences from the API response before writing to buffer", function()
    _G._curl_fixture = {
      status = 200,
      body = vim.fn.json_encode({
        choices = { { message = { content = "```\nFix bug\n\n- Remove off-by-one\n```" } } },
      }),
    }
    local bufnr = make_buf({ "# comment" })
    plugin.generate_commit_message(bufnr)
    local lines = buf_lines(bufnr)
    eq("Fix bug", lines[1])
    assert.falsy(lines[1]:match("^```"))
  end)

  -- -------------------------------------------------------------------------
  -- Security fixes
  -- -------------------------------------------------------------------------

  it("does not emit debug notifications during normal flow", function()
    local debug_msgs = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.INFO then
        table.insert(debug_msgs, msg)
      end
    end
    local bufnr = make_buf({ "# comment" })
    plugin.generate_commit_message(bufnr)
    vim.notify = orig
    for _, msg in ipairs(debug_msgs) do
      assert.falsy(msg:match("Diff content"), "unexpected debug notify: " .. msg)
      assert.falsy(msg:match("User input lines"), "unexpected debug notify: " .. msg)
    end
  end)

  it("emits a WARN when api_url uses http://", function()
    plugin.setup({ openai_api_key = "test-key", confirm_send = false,
                   api_url = "http://localhost:11434/v1/chat/completions" })
    local warned = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN and msg:lower():match("https") then
        warned = true
      end
    end
    local bufnr = make_buf({ "# comment" })
    plugin.generate_commit_message(bufnr)
    vim.notify = orig
    assert.is_true(warned, "expected an HTTPS warning for http:// api_url")
  end)

  it("does not emit an HTTPS warning for https:// api_url", function()
    local warned = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN and msg:lower():match("https") then
        warned = true
      end
    end
    local bufnr = make_buf({ "# comment" })
    plugin.generate_commit_message(bufnr)
    vim.notify = orig
    assert.is_false(warned)
  end)

  it("leaves buffer unchanged when user declines confirmation", function()
    plugin.setup({ openai_api_key = "test-key", confirm_send = true })
    vim.fn.confirm = function() return 2 end  -- No
    local original = { "# existing comment" }
    local bufnr = make_buf(original)
    plugin.generate_commit_message(bufnr)
    local lines = buf_lines(bufnr)
    eq(1, #lines)
    eq("# existing comment", lines[1])
  end)

  it("passes configured timeout to curl", function()
    plugin.setup({ openai_api_key = "test-key", confirm_send = false, timeout = 60 })
    local bufnr = make_buf({ "# comment" })
    plugin.generate_commit_message(bufnr)
    assert.is_not_nil(_G._curl_last_opts)
    eq(60, _G._curl_last_opts.timeout)
  end)

  it("uses default timeout of 30 when not configured", function()
    local bufnr = make_buf({ "# comment" })
    plugin.generate_commit_message(bufnr)
    assert.is_not_nil(_G._curl_last_opts)
    eq(30, _G._curl_last_opts.timeout)
  end)
end)

-- ---------------------------------------------------------------------------
-- provider presets
-- ---------------------------------------------------------------------------

describe("provider presets", function()
  after_each(function()
    -- Restore default setup so other tests are unaffected
    plugin.setup({ openai_api_key = "test-key", confirm_send = false })
  end)

  it("mistral preset sets correct api_url and model", function()
    plugin.setup({ provider = "mistral", openai_api_key = "test-key", confirm_send = false })
    eq("https://api.mistral.ai/v1/chat/completions", plugin._config.api_url)
    eq("mistral-small-latest", plugin._config.model)
    eq("MISTRAL_API_KEY", plugin._config.api_key_env)
  end)

  it("mistral preset reads MISTRAL_API_KEY from environment", function()
    vim.env.MISTRAL_API_KEY = "mk-test-key"
    plugin.setup({ provider = "mistral", confirm_send = false })
    eq("mk-test-key", plugin._get_api_key())
    vim.env.MISTRAL_API_KEY = nil
  end)

  it("user opts override provider preset", function()
    plugin.setup({ provider = "mistral", model = "mistral-large-latest",
                   openai_api_key = "test-key", confirm_send = false })
    eq("mistral-large-latest", plugin._config.model)
    eq("https://api.mistral.ai/v1/chat/completions", plugin._config.api_url)
  end)

  it("openai preset sets correct api_url", function()
    plugin.setup({ provider = "openai", openai_api_key = "test-key", confirm_send = false })
    eq("https://api.openai.com/v1/chat/completions", plugin._config.api_url)
    eq("OPENAI_API_KEY", plugin._config.api_key_env)
  end)

  it("no provider leaves existing config untouched", function()
    plugin.setup({ openai_api_key = "test-key", confirm_send = false,
                   api_url = "https://custom.example.com/v1/chat/completions" })
    eq("https://custom.example.com/v1/chat/completions", plugin._config.api_url)
  end)
end)
