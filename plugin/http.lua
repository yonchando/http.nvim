local http = require("http-nvim")

vim.keymap.set("n", "<leader>ho", function()
    http.open()
end)

vim.keymap.set("n", "<leader>hp", function()
    http.preview_last()
end)

vim.keymap.set("n", "<leader>hl", function()
    http.run_last()
end)

local http_augroup = vim.api.nvim_create_augroup("http-nvim", {
    clear = true
})

vim.api.nvim_create_autocmd("VimEnter", {
    group = http_augroup,
    callback = function()
        vim.cmd("silent! helptags " .. vim.fn.stdpath("data") .. "/site/pack/chando/start/http.nvim/doc")
    end
})
