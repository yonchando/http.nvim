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
    floats = {}
}

local keymap = function(mode, key, callback)
    vim.keymap.set(mode, key, callback, {
        buffer = state.floats.body.buf
    })
end

local http_request = {
    method = "",
    url = "",
    header = {},
    data = {},
}

local create_output_ui = function()
    local window = floating.create_window_config()
    state.floats.background = floating.create_floating_window(window.background)
    state.floats.header = floating.create_floating_window(window.header)
    state.floats.body = floating.create_floating_window(window.body)

    vim.api.nvim_set_current_buf(state.floats.body.buf)
    vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, {
        http_request.method .. " " .. http_request.url
    })

    keymap('n', 'q', function()
        vim.api.nvim_win_close(state.floats.header.win, false)
        vim.api.nvim_win_close(state.floats.body.win, false)
        vim.api.nvim_win_close(state.floats.background.win, false)


        vim.api.nvim_buf_delete(state.floats.header.buf, {})
        vim.api.nvim_buf_delete(state.floats.body.buf, {})
        vim.api.nvim_buf_delete(state.floats.background.buf, {})
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
                http_request.data = vim.json.decode(value)
            end
        end
    end

    local command = "curl --silent"

    if http_request.method ~= "GET" then
        command = command .. " -X " .. http_request.method
    end

    if #(http_request.header) ~= 0 then
        for _, v in pairs(http_request.header) do
            command = command .. " --header " .. "'" .. v .. "'"
        end
    end

    if #(http_request.data) ~= 0 then
        command = command .. " --json " .. vim.json.encode(http_request.data)
    end

    command = command .. " " .. http_request.url
    return command
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

    local command = build_curl(request)

    local output = {}
    local append = function(_, data)
        if data then
            table.insert(output, data)
        end
    end

    create_output_ui()

    vim.api.nvim_buf_set_lines(state.floats.body.buf, -1, -1, false, {
        "Loading ..."
    })

    vim.fn.jobstart(command, {
        stdout_buffered = true,
        on_stdout = append,
        on_stderr = append,
        on_exit = function()
            vim.api.nvim_buf_set_text(state.floats.body.buf, 0, 0, -1, -1, {})

            for _, v in pairs(output) do
                vim.api.nvim_buf_set_lines(state.floats.body.buf, -1, -1, false, v)
            end
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
    })
end

return M
