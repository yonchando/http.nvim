-- Convert Postman requests to and from the JetBrains HTTP Client format:
--
--   ### name
--   POST {{url}}/v1/login
--   Content-Type: application/json
--   # or // X-Disabled: header
--   // comment
--
--   { "body": true }
--
--   > {%
--     client.global.set("token", response.body.token)
--   %}

local M = {}

-- Captures come back in document order, so headers and disabled-header comments stay interleaved
local fields_source = [[
(request method: (method) @method)
(request url: (target_url) @url)
(request header: (header) @header)
(request (comment) @comment)
(request body: (_) @body)
(request (res_handler_script) @handler)
]]

--- Lines of the item's response handler script: the `exec` of its Postman `test` event.
---@param item PostmanItem
---@return string[]|nil
M.script_of = function(item)
    for _, event in ipairs(item.event or {}) do
        if event.listen == "test" and event.script then
            local exec = event.script.exec
            if type(exec) == "string" then
                exec = vim.split(exec, "\n", { plain = true })
            end
            if exec and #exec > 0 then
                return exec
            end
        end
    end
end

--- Store the response handler script as the item's Postman `test` event, or
--- remove that event when `script` is nil. Other events are kept.
---@param item PostmanItem
---@param script string[]|nil
M.set_script = function(item, script)
    local events = vim.tbl_filter(function(event)
        return event.listen ~= "test"
    end, item.event or {})
    if script then
        table.insert(events, { listen = "test", script = { type = "text/javascript", exec = script } })
    end
    item.event = #events > 0 and events or nil
end

---@param request PostmanRequest|string
---@return string
M.url_of = function(request)
    local url = type(request) == "table" and request.url or request
    if type(url) == "table" then
        return url.raw or ""
    end
    return url or ""
end

---@param name string
---@param request PostmanRequest|string
---@param script string[]|nil Response handler script, written as `> {% ... %}`
---@return string[]
M.to_lines = function(name, request, script)
    local method = type(request) == "table" and request.method or "GET"
    local lines = {
        "### " .. name,
        method .. " " .. M.url_of(request),
    }

    if type(request) == "table" then
        for _, header in ipairs(request.header or {}) do
            local prefix = header.disabled and "# " or ""
            table.insert(lines, prefix .. header.key .. ": " .. (header.value or ""))
        end

        local body = request.body
        if body and body.mode == "raw" and body.raw and body.raw ~= "" then
            table.insert(lines, "")
            for _, line in ipairs(vim.split((body.raw:gsub("\r\n", "\n")), "\n", { plain = true })) do
                table.insert(lines, line)
            end
        elseif body and body.mode and body.mode ~= "raw" then
            table.insert(lines, "")
            table.insert(lines, "# body mode '" .. body.mode .. "' is not editable here and is kept as is")
        end
    end

    if script then
        table.insert(lines, "")
        table.insert(lines, "> {%")
        vim.list_extend(lines, script)
        table.insert(lines, "%}")
    end

    return lines
end

--- Parse lines written by `to_lines` back into a Postman request, keeping the
--- fields the HTTP format cannot express from `original`.
--- Only the first `### name` section is read; other sections are ignored.
---@param lines string[]
---@param original PostmanRequest|string
--- The response handler script (`> {% ... %}`) comes back as its own lines.
---@return PostmanRequest|nil, string|nil, { name: string, start_row: integer, end_row: integer }|nil, string[]|nil Name and 0-based, end-exclusive line range of the section used, and the script
M.from_lines = function(lines, original)
    local text = table.concat(lines, "\n") .. "\n"
    -- `query.parse` is memoized, so this only parses the queries once
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, "http")
    if not ok then
        return nil, "tree-sitter http parser not found (:TSInstall http)"
    end
    local section_query = vim.treesitter.query.parse("http", [[
(section (request_separator value: (value) @name) request: (request) @request) @section
]])
    local fields_query = vim.treesitter.query.parse("http", fields_source)
    local root = parser:parse()[1]:root()

    -- Only the first named section is used
    local request_node, range
    for _, match in section_query:iter_matches(root, text) do
        local section_name, section
        for id, nodes in pairs(match) do
            local capture = section_query.captures[id]
            if capture == "name" then
                section_name = vim.trim(vim.treesitter.get_node_text(nodes[1], text))
            elseif capture == "request" then
                request_node = nodes[1]
            elseif capture == "section" then
                section = nodes[1]
            end
        end
        local start_row, _, end_row, end_col = section:range()
        range = { name = section_name, start_row = start_row, end_row = end_col > 0 and end_row + 1 or end_row }
        break
    end
    if not request_node or not range or range.name == "" then
        return nil, "missing '### name' section with a request"
    end

    local method, url = "GET", nil
    local headers = {}
    local body_lines = {}
    local script
    for id, node in fields_query:iter_captures(request_node, text) do
        local capture = fields_query.captures[id]
        local node_text = vim.treesitter.get_node_text(node, text)
        if capture == "method" then
            method = node_text
        elseif capture == "url" then
            url = vim.trim(node_text)
        elseif capture == "header" then
            local key = node:field("name")[1]
            local value = node:field("value")[1]
            table.insert(headers, {
                key = vim.trim(vim.treesitter.get_node_text(key, text)),
                value = value and vim.trim(vim.treesitter.get_node_text(value, text)) or "",
            })
        elseif capture == "comment" then
            -- `# Key: value` comments are disabled headers
            local key, value = node_text:match("^#%s*([^:%s][^:]*):%s*(.-)%s*$")
            if key then
                table.insert(headers, { key = vim.trim(key), value = value, disabled = true })
            end
        elseif capture == "body" then
            body_lines = vim.split(node_text, "\n", { plain = true })
        elseif capture == "handler" then
            -- Read from the text: the grammar only parses a `{% %}` spanning several lines
            local inner = node_text:match("^>%s*{%%(.-)%%}%s*$")
            if inner then
                script = vim.split(inner, "\n", { plain = true })
                while #script > 0 and script[1]:match("^%s*$") do
                    table.remove(script, 1)
                end
                while #script > 0 and script[#script]:match("^%s*$") do
                    table.remove(script)
                end
                script = #script > 0 and script or nil
            end
        end
    end
    if not url or url == "" then
        return nil, "missing url"
    end

    while #body_lines > 0 and body_lines[#body_lines]:match("^%s*$") do
        table.remove(body_lines)
    end

    local request = type(original) == "table" and vim.deepcopy(original) or {}
    request.method = method
    request.header = headers
    if url ~= M.url_of(original) then
        request.url = { raw = url }
    end

    local body = request.body
    if body and body.mode and body.mode ~= "raw" then
        -- Not representable in the HTTP format: leave the original body untouched
        return request, nil, range, script
    end
    if #body_lines > 0 then
        request.body = vim.tbl_extend("force", body or {}, { mode = "raw", raw = table.concat(body_lines, "\n") })
    else
        request.body = nil
    end

    return request, nil, range, script
end

return M
