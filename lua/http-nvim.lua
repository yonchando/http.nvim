local ts_utils = require("nvim-treesitter.ts_utils")
local floating = require("floating.window")
local cmd = require('cmd')

local M = {}

local state = {
    floats = {},
    open_request = false,
    command = "",
    curl = {
        method = "",
        url = "",
        header = {},
        data = {},
    }
}

local keymap = function(mode, key, callback, bufnr)
    if bufnr then
        vim.keymap.set(mode, key, callback, {
            buffer = bufnr
        })
    else
        vim.keymap.set(mode, key, callback, {
            buffer = state.floats.body.buf
        })
    end
end

---@param node TSNode|nil
local get_request = function(node)
    if node == nil then
        return nil
    end

    local result = node ---@type TSNode|nil

    while result and result:type() ~= "request" do
        result = result:parent()
    end

    return result
end

local create_output_ui = function()
    local window = floating.create_window_config()

    state.floats.background = floating.create_floating_window(window.background)
    state.floats.header = floating.create_floating_window(window.header)
    state.floats.body = floating.create_floating_window(window.body)

    vim.api.nvim_set_current_buf(state.floats.body.buf)

    vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, {
        " " .. state.curl.method .. ": " .. state.curl.url
    })

    local quit = function()
        vim.api.nvim_win_close(state.floats.header.win, false)
        vim.api.nvim_win_close(state.floats.body.win, false)
        vim.api.nvim_win_close(state.floats.background.win, false)

        vim.api.nvim_buf_delete(state.floats.header.buf, {})
        vim.api.nvim_buf_delete(state.floats.body.buf, {})
        vim.api.nvim_buf_delete(state.floats.background.buf, {})
    end

    keymap('n', 'q', quit)
    keymap('n', '<ESC>', quit)

    keymap('n', 'i', function()
        if state.open_request == false then
            local body_buf = state.floats.body.buf
            local original_header = vim.api.nvim_buf_get_lines(state.floats.header.buf, 0, -1, true)
            local original_body = vim.api.nvim_buf_get_lines(body_buf, 0, -1, true)
            local original_filetype = vim.bo[state.floats.body.buf].filetype
            local command_run = cmd.build_curl({
                curl = state.curl,
                curl_options = " -v "
            })


            local set_content = function()
                vim.bo[state.floats.body.buf].filetype = original_filetype
                vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, original_header)
                vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, original_body)
                vim.api.nvim_win_set_cursor(state.floats.body.win, { 1, 0 })

                state.open_request = false
                keymap('n', 'q', quit)
                keymap('n', '<ESC>', quit)
            end

            state.open_request = true

            vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, {
                "Info",
            })

            cmd.run_command(command_run, {
                bufnr = body_buf,
                filetype = 'json',
                on_exit = function()
                    vim.api.nvim_buf_set_lines(body_buf, -1, -1, false, {
                        command_run,
                        "",
                    })
                end
            })

            keymap('n', 'q', set_content)
            keymap('n', '<ESC>', set_content)
        end
    end)
end

M.make_request = function()
    local node = ts_utils.get_node_at_cursor(0)

    if node == nil then
        error("No treesitter parser, Please use :TSInstall http")
    end

    local request = nil

    if node:type() == 'request_separator' then
        request = node:next_sibling()
    elseif node:type() == 'value' and node:parent():type() == 'request_separator' then
        request = node:parent():next_sibling()
    else
        request = get_request(node)
    end

    if request == nil or request:type() == 'document' then
        print("Not found request, Please try put cursor the line request or headers")
        return
    end

    state.curl = cmd.get_curl(request)
    state.command = cmd.build_curl({ curl = state.curl })
    create_output_ui()
    cmd.run_command(state.command, { bufnr = state.floats.body.buf })
end

M.run_last = function()
    create_output_ui()
    cmd.run_command(state.command, { bufnr = state.floats.body.buf })
end

M.setup = function()
    vim.cmd [[
augroup ReqFiltypeRelated
  au BufNewFile,BufRead *.http set ft=http
augroup END
]]
end

return M
