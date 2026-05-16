-- Add plugin root to runtimepath so the plugin module can be required
vim.opt.rtp:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

-- Locate plenary: check packpath (nixvim / system packages), then lazy.nvim fallback
local function add_plenary()
  for _, dir in ipairs(vim.opt.packpath:get()) do
    local matches = vim.fn.glob(dir .. "/pack/*/start/plenary.nvim", false, true)
    for _, m in ipairs(matches) do
      if vim.fn.isdirectory(m) == 1 then
        vim.opt.rtp:append(m)
        vim.cmd("runtime! plugin/plenary.vim")
        return
      end
    end
  end
  -- Fallback: lazy.nvim or manual packpath
  local candidates = {
    vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
    vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim",
  }
  for _, path in ipairs(candidates) do
    if vim.fn.isdirectory(path) == 1 then
      vim.opt.rtp:append(path)
      vim.cmd("runtime! plugin/plenary.vim")
      return
    end
  end
  error("plenary.nvim not found — install it or add it to packpath")
end

add_plenary()
