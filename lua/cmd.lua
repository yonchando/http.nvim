local log = require("log")
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
    local output = {}
    local append = function(_, data)
        if data[1] ~= "" then
            table.insert(output, data[1])
        end
    end

    local errs = {}
    local errors = function(_, data)
        if data then
            table.insert(errs, data)
        end
    end

    vim.fn.jobstart(command, {
        stdout_buffered = true,
        on_stdout = append,
        on_stderr = errors,
        on_exit = function()
            local data = vim.deepcopy(output)

            if not vim.tbl_isempty(data) then
                for _, value in pairs(data) do
                    local ok, response = pcall(vim.json.decode, value)


                    if opts.on_exit then
                        if ok then
                            opts.on_exit(response)
                        else
                            log.info({ value = value, decode = ok })
                        end
                    end
                end
            else
                log.error(errs)
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
    local cmd = vim.fn.stdpath("data") .. "/http.nvim/http"
    local command = cmd .. " --url " .. curl.url

    if opts.curl_options then
        command = command .. opts.curl_options
    end

    command = command .. " --method " .. curl.method

    if #curl.header ~= 0 then
        command = command .. " --header " .. "'" .. vim.json.encode(curl.header) .. "'"
    end

    local body = {}

    for _, v in pairs(curl.data) do
        table.insert(body, v)
    end

    if #body ~= 0 then
        local data = vim.json.encode(curl.data)
        command = command .. ' --data ' .. "'" .. data .. "'"
    end

    return command
end

return M
