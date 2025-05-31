local ts = vim.treesitter
local M = {}

---@param node TSNode|nil
---@return string|nil
local get_node_text = function(node)
    if node ~= nil then
        return ts.get_node_text(node, 0)
    end
    return nil
end

M.run_command = function(command, opts)
    local bufnr = opts.bufnr
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
        "Loading ..."
    })

    local output = {}
    local append = function(_, data)
        if data then
            table.insert(output, data)
        end
    end

    vim.fn.jobstart(command, {
        stdout_buffered = true,
        on_stdout = append,
        on_stderr = append,
        on_exit = function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            if opts.on_exit then
                opts.on_exit()
            end

            for _, v in pairs(output) do
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, v)
            end

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            if opts.filetype then
                vim.bo[bufnr].filetype = opts.filetype
            else
                if lines[2] == '<!DOCTYPE html>' then
                    vim.bo[bufnr].filetype = 'html'
                else
                    vim.bo[bufnr].filetype = 'json'
                    local ok, conform = pcall(require, "conform")

                    if ok then
                        conform.format({
                            async = true,
                            lsp_fallback = true,
                            timeout_ms = 50000,
                        })
                    end
                end
            end
        end
    })
end

---@param request TSNode
M.get_curl = function(request)
    local curl = {
        method = "",
        url = "",
        header = {},
        data = {}
    }

    for n, type in request:iter_children() do
        local value = get_node_text(n)

        if value ~= nil then
            if type == 'method' then
                curl.method = value
            end
            if type == 'url' then
                curl.url = value
            end
            if type == 'header' then
                table.insert(curl.header, value)
            end
            if type == 'body' then
                curl.data = vim.json.decode(value)
            end
        end
    end

    return curl
end


---@class curl
---@field url string
---@field method string
---@field header table
---@field data table

---@class BuildCurl
---@field curl curl
---@field curl_options string|nil

---@param opts BuildCurl
M.build_curl = function(opts)
    local curl = opts.curl
    local command = "curl -L --no-progress-meter"
    local is_content_json = false

    if opts.curl_options then
        command = command .. opts.curl_options
    end

    if curl.method ~= "GET" then
        command = command .. " -X " .. curl.method
    end

    if #(curl.header) ~= 0 then
        for _, v in pairs(curl.header) do
            if v == 'Content-Type: application/json' then
                is_content_json = true
            end

            command = command .. " -H " .. "'" .. v .. "'"
        end
    end

    local body = {}

    for _, v in pairs(curl.data) do
        table.insert(body, v)
    end

    if #body and is_content_json then
        local data = vim.json.encode(curl.data)
        command = command .. " --data-raw " .. "'" .. data .. "'"
    end

    command = command .. " " .. curl.url

    return command
end

return M
