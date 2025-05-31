local ts = vim.treesitter
local ts_utils = require("nvim-treesitter.ts_utils")
local floating = require("floating.window")

local P = function(value, isMeta)
    if isMeta then
        print(vim.inspect(getmetatable(value)))
    else
        print(vim.inspect(value))
    end
end

---@param node TSNode|nil
---@return string|nil
local get_node_text = function(node)
    if node ~= nil then
        return ts.get_node_text(node, 0)
    end
    return nil
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

local M = {}

local state = {
    floats = {},
    open_request = false,
    command = ""
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

local http_request = {
    method = "",
    url = "",
    header = {},
    data = nil,
}

local create_output_ui = function()
    local window = floating.create_window_config()

    state.floats.background = floating.create_floating_window(window.background)
    state.floats.header = floating.create_floating_window(window.header)
    state.floats.body = floating.create_floating_window(window.body)

    vim.api.nvim_set_current_buf(state.floats.body.buf)

    vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, {
        " " .. http_request.method .. ": " .. http_request.url
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
            state.open_request = true
            local original_header = vim.api.nvim_buf_get_lines(state.floats.header.buf, 0, -1, true)
            local original_body = vim.api.nvim_buf_get_lines(state.floats.body.buf, 0, -1, true)

            local set_content = function()
                vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, original_header)
                vim.api.nvim_buf_set_lines(state.floats.body.buf, 0, -1, false, original_body)

                state.open_request = false
                keymap('n', 'q', quit)
                keymap('n', '<ESC>', quit)
            end

            vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, {
                "Info"
            })

            vim.api.nvim_buf_set_lines(state.floats.body.buf, 0, -1, false, {
                "curl",
                state.command,
                "",
                "Headers",
                "",
                vim.json.encode(http_request.header),
                "---------------",
                "",
                "Request body",
                "",
            })

            keymap('n', 'q', set_content)
            keymap('n', '<ESC>', set_content)
        end
    end)
end

---@param request TSNode
local build_curl = function(request)
    for n, type in request:iter_children() do
        local value = get_node_text(n)

        if value ~= nil then
            if type == 'method' then
                http_request.method = value
            end
            if type == 'url' then
                http_request.url = value
            end
            if type == 'header' then
                table.insert(http_request.header, value)
            end
            if type == 'body' then
                http_request.data = value
            end
        end
    end

    local command = "curl -L --no-progress-meter"

    if http_request.method ~= "GET" then
        command = command .. " -X " .. http_request.method
    end

    if #(http_request.header) ~= 0 then
        for _, v in pairs(http_request.header) do
            command = command .. " -H " .. "'" .. v .. "'"
        end
    end

    if http_request.data ~= nil then
        local json = vim.json.decode(http_request.data)
        local body = vim.json.encode(json)
        command = command .. " --data-raw " .. "'" .. body .. "'"
    end

    command = command .. " " .. http_request.url

    state.command = command
    return command
end

local run_command = function()
    create_output_ui()

    vim.api.nvim_buf_set_lines(state.floats.body.buf, -1, -1, false, {
        "Loading ..."
    })

    local output = {}
    local append = function(_, data)
        if data then
            table.insert(output, data)
        end
    end

    vim.fn.jobstart(state.command, {
        stdout_buffered = true,
        on_stdout = append,
        on_stderr = append,
        on_exit = function()
            vim.api.nvim_buf_set_lines(state.floats.body.buf, 0, -1, false, {})

            for _, v in pairs(output) do
                vim.api.nvim_buf_set_lines(state.floats.body.buf, -1, -1, false, v)
            end

            local lines = vim.api.nvim_buf_get_lines(state.floats.body.buf, 0, -1, false)

            if lines[2] == '<!DOCTYPE html>' then
                vim.bo[state.floats.body.buf].filetype = 'html'
            else
                vim.bo[state.floats.body.buf].filetype = 'json'
                local ok, conform = pcall(require, "conform")

                if ok then
                    conform.format({
                        async = true,
                        lsp_fallback = true,
                        timeout_ms = 50000,
                    })
                end
            end

            local ns = vim.api.nvim_create_namespace("result curl")
            vim.api.nvim_buf_set_extmark(state.floats.header.buf, ns, 0, 0, {
                virt_text = { { "" } }
            })
        end
    })
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

    build_curl(request)
    run_command()
end

M.run_last = function()
    run_command()
end

M.setup = function()
    vim.cmd [[
augroup ReqFiltypeRelated
  au BufNewFile,BufRead *.http set ft=http
augroup END
]]
end

return M
