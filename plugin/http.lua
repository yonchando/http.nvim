local http = require("http-nvim")

vim.keymap.set("n", "<leader>rr", function()
    http.open()
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
