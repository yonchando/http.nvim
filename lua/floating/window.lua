local M = {}

M.create_window_config = function()
    local width = math.floor(vim.o.columns * 0.5)
    local height = math.floor(vim.o.lines * 0.8)

    local header_height = 2 + 2 + 2 -- border

    return {
        background = {
            width = width + 4,
            height = height,
            zindex = 1,

            col = (vim.o.columns - width) / 2,
            row = (vim.o.lines - height) / 2,

            relative = 'editor',
            style = "minimal",
            border = "rounded",
        },
        header = {
            width = width - 2,
            height = 1,
            col = (vim.o.columns - width + 6) / 2,
            row = (vim.o.lines - height + 2) / 2,
            zindex = 3,

            relative = 'editor',
            style = "minimal",
            border = { "-", "-", "-", "+", "-", "-", "-", "+" },
        },
        body = {
            width = width - 2,
            height = height - header_height,
            col = (vim.o.columns - width + 5) / 2,
            row = (vim.o.lines - height + header_height) / 2,
            zindex = 2,

            style = "minimal",
            border = { " ", " ", " ", " ", " ", " ", " ", " " },
            relative = 'editor',
        }
    }
end

M.create_floating_window = function(win_config)
    local buf = vim.api.nvim_create_buf(false, true)

    local win = vim.api.nvim_open_win(buf, true, win_config)

    return { buf = buf, win = win }
end

return M
