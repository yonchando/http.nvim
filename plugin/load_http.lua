local function reload()
    package.loaded["http-nvim"] = nil
    package.loaded["ui"] = nil
    package.loaded["cmd"] = nil
    package.loaded["floating.window"] = nil
end

vim.api.nvim_create_user_command("HttpRun", function()
    -- reload()
    local http = require("http-nvim")
    http.make_request()
end, {})

vim.api.nvim_create_user_command("HttpResult", function()
    local http = require("http-nvim")
    http.last_result()
end, {})

vim.api.nvim_create_user_command("HttpRerun", function()
    local http = require("http-nvim")
    http.rerun()
end, {})

vim.api.nvim_create_user_command("HttpHistory", function()
    local http = require("http-nvim")
    http.history()
end, {})

vim.api.nvim_create_user_command("HttpClose", function()
    local http = require("http-nvim")
    http.close()
end, {})
