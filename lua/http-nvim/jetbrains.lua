-- Convert Postman requests to and from the JetBrains HTTP Client format:
--
--   ### name
--   < {%
--     client.global.set("nonce", $uuid)
--   %}
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

--- Lines of a script's `exec`, or nil when there is none.
---@param item PostmanItem|PostmanCollection
---@param listen string|nil `test` (the response handler, the default) or `prerequest`
---@return string[]|nil
M.script_of = function(item, listen)
    listen = listen or "test"
    for _, event in ipairs(item.event or {}) do
        if event.listen == listen and event.script then
            local exec = event.script.exec
            if type(exec) == "string" then
                exec = vim.split(exec, "\n", { plain = true })
            end
            if exec and #exec > 0 then
                -- Postman exports keep the `\r` of Windows line ends
                return vim.tbl_map(function(line)
                    return (line:gsub("\r$", ""))
                end, exec)
            end
        end
    end
end

--- Store a script as the item's Postman `listen` event, or remove that event
--- when `script` is nil. Other events are kept.
---@param item PostmanItem|PostmanCollection
---@param script string[]|nil
---@param listen string|nil `test` (the response handler, the default) or `prerequest`
M.set_script = function(item, script, listen)
    listen = listen or "test"
    local events = vim.tbl_filter(function(event)
        return event.listen ~= listen
    end, item.event or {})
    if script then
        table.insert(events, { listen = listen, script = { type = "text/javascript", exec = script } })
    end
    item.event = #events > 0 and events or nil
end

--- `lines` without the blank lines at both ends, or nil when nothing is left.
---@param lines string[]
---@return string[]|nil
local function trim_blank(lines)
    lines = vim.deepcopy(lines)
    while #lines > 0 and lines[1]:match("^%s*$") do
        table.remove(lines, 1)
    end
    while #lines > 0 and lines[#lines]:match("^%s*$") do
        table.remove(lines)
    end
    return #lines > 0 and lines or nil
end

--- The `< {% %}` (pre-request) and `> {% %}` (response handler) scripts in
--- `lines[from..to]`, one-line ones too. A script that is empty comes back as nil.
---@param lines string[]
---@param from integer 1-based
---@param to integer 1-based, inclusive
---@return { prerequest: string[]|nil, test: string[]|nil }|nil scripts, string|nil err
---@return integer|nil stray First line outside a script that is neither blank nor a comment
M.script_blocks = function(lines, from, to)
    local scripts, stray = {}, nil
    local i = from
    while i <= to do
        local mark, rest = lines[i]:match("^%s*([<>])%s*{%%(.*)$")
        if mark then
            local listen = mark == "<" and "prerequest" or "test"
            local body = {}
            local inner = rest:match("^(.-)%%}%s*$")
            if inner then
                table.insert(body, vim.trim(inner))
            else
                local start = i
                table.insert(body, rest)
                i = i + 1
                while i <= to and not lines[i]:find("%}", 1, true) do
                    table.insert(body, lines[i])
                    i = i + 1
                end
                if i > to then
                    return nil, "line " .. start .. ": '" .. mark .. " {%' is not closed with '%}'"
                end
                table.insert(body, lines[i]:match("^(.-)%%}"))
            end
            scripts[listen] = vim.list_extend(scripts[listen] or {}, body)
        elseif not (lines[i]:match("^%s*$") or lines[i]:match("^%s*#") or lines[i]:match("^%s*//")) then
            stray = stray or i
        end
        i = i + 1
    end
    scripts.prerequest = scripts.prerequest and trim_blank(scripts.prerequest)
    scripts.test = scripts.test and trim_blank(scripts.test)
    return scripts, nil, stray
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
---@param pre_script string[]|nil Pre-request script, written as `< {% ... %}` before the request line
---@return string[]
M.to_lines = function(name, request, script, pre_script)
    local method = type(request) == "table" and request.method or "GET"
    local lines = { "### " .. name }
    if pre_script then
        table.insert(lines, "< {%")
        vim.list_extend(lines, pre_script)
        table.insert(lines, "%}")
    end
    table.insert(lines, method .. " " .. M.url_of(request))

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

--- 1-based rows of the first section's request line and of its headers (from
--- the line after it to the last one before a blank line, a `<`/`>` line or the
--- next `###`). Nil when there is no request line.
---@param lines string[]
---@return integer|nil request, integer|nil first, integer|nil last `last` < `first` when there are no headers
local function header_rows(lines)
    local i = 1
    while i <= #lines and not lines[i]:match("^###") do
        i = i + 1
    end
    i = i + 1
    local in_script = false
    while i <= #lines do
        local text = vim.trim(lines[i])
        if lines[i]:match("^###") then
            return nil
        elseif in_script then
            in_script = not lines[i]:find("%}", 1, true)
        elseif text:match("^<%s*{%%") then
            in_script = not text:match("%%}$")
        elseif text ~= "" and not text:match("^#") and not text:match("^//") then
            break
        end
        i = i + 1
    end
    if i > #lines then
        return nil
    end
    local last = i
    for j = i + 1, #lines do
        if vim.trim(lines[j]) == "" or lines[j]:match("^###") or lines[j]:match("^%s*[<>]") then
            break
        end
        last = j
    end
    return i, i + 1, last
end

--- Parse lines written by `to_lines` back into a Postman request, keeping the
--- fields the HTTP format cannot express from `original`.
--- Only the first `### name` section is read; other sections are ignored.
---@param lines string[]
---@param original PostmanRequest|string
--- The response handler script (`> {% ... %}`) and the pre-request script
--- (`< {% ... %}`) come back as their own lines.
---@return PostmanRequest|nil, string|nil, { name: string, start_row: integer, end_row: integer }|nil, string[]|nil, string[]|nil Name and 0-based, end-exclusive line range of the section used, the script and the pre-request script
M.from_lines = function(lines, original)
    -- The grammar breaks the section on a one-line `< {% ... %}`: parse without
    -- it (keeping the rows), and read the pre-request script from the lines
    local parsed = vim.tbl_map(function(line)
        return line:match("^%s*<%s*{%%.*%%}%s*$") and "" or line
    end, lines)
    -- It also ends the request at a header without `:` or without a value:
    -- refuse the first, and give the second a stand-in value to parse
    local empty_values = {}
    local _, first_header, last_header = header_rows(lines)
    for i = first_header or 1, first_header and last_header or 0 do
        local line = vim.trim(lines[i])
        if not (line:match("^#") or line:match("^//")) then
            if not line:match("^[^:%s][^:]*:") then
                return nil, ("line %d: '%s' is not a header: write 'Name: value', or leave a blank line before the body")
                    :format(i, line)
            elseif line:match(":$") then
                parsed[i] = lines[i] .. " _"
                empty_values[i - 1] = true
            end
        end
    end
    local text = table.concat(parsed, "\n") .. "\n"
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
    -- Anything the grammar left out of the section (up to the next `###`) would be
    -- lost when saving drops the other sections: refuse instead
    for i = range.end_row + 1, #lines do
        if lines[i]:match("^###") then
            break
        end
        if vim.trim(lines[i]) ~= "" then
            return nil, ("line %d: can't read '%s' as part of the request '%s'"):format(i, vim.trim(lines[i]), range.name)
        end
    end
    -- Between `### name` and the request line
    local pre_scripts, pre_err = M.script_blocks(lines, range.start_row + 2, (request_node:range()))
    if not pre_scripts then
        return nil, pre_err
    end
    local pre_script = pre_scripts.prerequest

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
                value = value and not empty_values[(node:range())] and vim.trim(vim.treesitter.get_node_text(value, text))
                    or "",
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
                script = trim_blank(vim.split(inner, "\n", { plain = true }))
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
        return request, nil, range, script, pre_script
    end
    if #body_lines > 0 then
        request.body = vim.tbl_extend("force", body or {}, { mode = "raw", raw = table.concat(body_lines, "\n") })
    else
        request.body = nil
    end

    return request, nil, range, script, pre_script
end

return M
