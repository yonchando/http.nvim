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

local http_augroup = vim.api.nvim_create_augroup("http-nvim", {
    clear = true
})

vim.api.nvim_create_autocmd("VimEnter", {
    group = http_augroup,
    callback = function()
        vim.cmd("silent! helptags " .. vim.fn.stdpath("data") .. "/site/pack/chando/start/http.nvim/doc")
    end
})
