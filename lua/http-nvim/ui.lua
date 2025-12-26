local floating = require("http-nvim.floating.window")
local log = require("http-nvim.log")

local M = {}
local floats = {}
local open_request = false

local keymap = function(mode, key, callback, bufnr)
    if bufnr then
        vim.keymap.set(mode, key, callback, {
            buffer = bufnr
        })
    else
        vim.keymap.set(mode, key, callback, {
            buffer = floats.body.buf
        })
    end
end

M.define_keymapping = function(self, bufnr, state)
    keymap('n', 'q', M.quit, bufnr)
    keymap('n', '<ESC>', M.quit, bufnr)

    keymap('n', 'i', function()
        if open_request == false then
            open_request = true
            vim.api.nvim_buf_set_lines(floats.header.buf, 0, -1, false, {
                " Info",
            })

            vim.api.nvim_buf_set_lines(floats.body.buf, 0, -1, false, {})

            self.set_content({ vim.json.encode({
                response = state.response,
                request = state.curl
            }) })
        else
            open_request = false
            vim.api.nvim_buf_set_lines(floats.header.buf, 0, -1, false, {
                " " .. state.curl.method .. ": " .. state.curl.url,
            })
            self.set_content({ vim.json.encode(state.response.body) })
        end
    end)
end

M.quit = function()
    vim.api.nvim_win_close(floats.header.win, false)
    vim.api.nvim_win_close(floats.body.win, false)
    vim.api.nvim_win_close(floats.background.win, false)

    vim.api.nvim_buf_delete(floats.header.buf, {})
    vim.api.nvim_buf_delete(floats.body.buf, {})
    vim.api.nvim_buf_delete(floats.background.buf, {})
end

---@param bufnr integer
---@param start integer
---@param end_ integer
---@param strict_indexing boolean
---@param replacement string[]|nil
M.nvim_buf_set_lines = function(bufnr, start, end_, strict_indexing, replacement)
    replacement = replacement or {}
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, start, end_, strict_indexing, replacement)
    end
end

M.create_output_ui = function(self, state)
    local window = floating.create_window_config()

    floats.background = floating.create_floating_window(window.background)
    floats.header = floating.create_floating_window(window.header)
    floats.body = floating.create_floating_window(window.body)

    vim.api.nvim_set_current_buf(floats.body.buf)

    vim.api.nvim_buf_set_lines(floats.header.buf, 0, -1, false, {
        " " .. state.curl.method .. ": " .. state.curl.url,
    })

    vim.api.nvim_buf_set_lines(floats.body.buf, 0, -1, false, {
        " Loading...",
    })

    self:define_keymapping(floats.body.buf, state)
    self:define_keymapping(floats.header.buf, state)
    self:define_keymapping(floats.background.buf, state)
end

M.set_content = function(content)
    local bufnr = floats.body.buf

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)

    vim.bo[bufnr].filetype = 'json'

    local ok, conform = pcall(require, "conform")
    if ok then
        conform.format({ bufnr = bufnr })
    end
end

return M
