local http = require("http-nvim")

http.map_global_keys()

vim.api.nvim_create_user_command("Http", function(cmd)
    local sub = cmd.fargs[1]
    if not sub then
        http.pick()
    elseif sub == "create" and #cmd.fargs > 1 then
        http.create(table.concat(cmd.fargs, " ", 2))
    else
        vim.notify("http-nvim: usage: :Http | :Http create {name}", vim.log.levels.ERROR)
    end
end, {
    nargs = "*",
    desc = "Choose a collection, or create one with :Http create {name}",
    complete = function(arglead, line)
        -- Only the subcommand, the first argument, completes
        if line:match("^%S+%s+%S*$") and ("create"):find(arglead, 1, true) == 1 then
            return { "create" }
        end
        return {}
    end,
})

vim.api.nvim_create_user_command("HttpCookies", http.show_cookies, {
    desc = "Show the cookies of the selected collection",
})

vim.api.nvim_create_user_command("HttpCookiesClear", http.clear_cookies, {
    desc = "Delete the cookies of the selected collection",
})

vim.api.nvim_create_user_command("HttpCookiesDelete", function(cmd)
    http.delete_cookie(cmd.args)
end, {
    nargs = 1,
    desc = "Remove a cookie of the selected collection",
    complete = function(arglead)
        return vim.tbl_filter(function(name)
            return vim.startswith(name, arglead)
        end, require("http-nvim.cookies").names())
    end,
})

vim.api.nvim_create_user_command("HttpCookiesEdit", http.edit_cookies, {
    desc = "Open the cookie jar of the selected collection",
})

local http_augroup = vim.api.nvim_create_augroup("http-nvim", {
    clear = true
})

vim.api.nvim_create_autocmd("VimEnter", {
    group = http_augroup,
    callback = function()
        vim.cmd("silent! helptags " .. vim.fn.stdpath("data") .. "/site/pack/chando/start/http.nvim/doc")
    end
})
