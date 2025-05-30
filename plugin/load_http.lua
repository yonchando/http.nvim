vim.api.nvim_create_user_command("HttpRun", function()
    -- Easy Reloading
    package.loaded["http-nvim"] = nil
    package.loaded["http-nvim.floating.window"] = nil

    local http = require("http-nvim")

    http.make_request()
end, {})

vim.keymap.set("n", "<F2>", function()
    local http = require("http-nvim")
    http.toggle_window()
end)
vim.keymap.set("n", "<leader>rc", ":HttpRun<CR>")
