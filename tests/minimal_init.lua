-- Add plugin root to runtimepath so the plugin module can be required
vim.opt.rtp:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

-- Locate plenary installed via lazy.nvim (standard data dir) or via packpath
local function add_plenary()
  local candidates = {
    vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
    vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim",
  }
  for _, path in ipairs(candidates) do
    if vim.fn.isdirectory(path) == 1 then
      vim.opt.rtp:append(path)
      return
    end
  end
  error("plenary.nvim not found — install it via lazy.nvim or add it to packpath")
end

add_plenary()
