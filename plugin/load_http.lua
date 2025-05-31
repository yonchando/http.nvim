vim.api.nvim_create_user_command("HttpRun", function()
    -- Easy Reloading
    -- package.loaded["http-nvim"] = nil
    local http = require("http-nvim")
    http.make_request()
end, {})
