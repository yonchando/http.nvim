--- A built-in language server, running inside Neovim, for request and scripts edit buffers.
--- It completes `{{key}}` environment variables, methods, header names and
--- values, cookie names from the collection's jar (in a `Cookie:` header and
--- `response.cookiesByName("")`), the script API in `< {% %}` and `> {% %}`, and
--- variable names in `client.global.get("")`, and shows the value of a
--- `{{key}}` on hover. It reads the buffer
--- straight from Neovim, so it doesn't track `didOpen`/`didChange`.
local cookies = require("http-nvim.cookies")
local dynamic = require("http-nvim.dynamic")
local state = require("http-nvim.state")

local kind = vim.lsp.protocol.CompletionItemKind
local snippet_format = vim.lsp.protocol.InsertTextFormat.Snippet

local methods = { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" }

local media_types = {
    "application/json",
    "application/xml",
    "application/x-www-form-urlencoded",
    "multipart/form-data",
    "text/plain",
    "text/html",
}

---@type table<string, string[]>
local headers = {
    ["Accept"] = vim.list_extend({ "*/*" }, media_types),
    ["Accept-Encoding"] = { "gzip, deflate, br", "identity" },
    ["Accept-Language"] = { "en-US,en;q=0.9" },
    ["Authorization"] = { "Bearer ", "Basic " },
    ["Cache-Control"] = { "no-cache", "no-store", "max-age=0" },
    ["Connection"] = { "keep-alive", "close" },
    ["Content-Length"] = {},
    ["Content-Type"] = media_types,
    ["Cookie"] = {},
    ["Host"] = {},
    ["If-Match"] = {},
    ["If-None-Match"] = {},
    ["Origin"] = {},
    ["Referer"] = {},
    ["User-Agent"] = { "curl" },
    ["X-Api-Key"] = {},
    ["X-Requested-With"] = { "XMLHttpRequest" },
}

-- What `handler.lua` understands in a script: the JetBrains API only. The
-- third field marks what only a pre-request script (`<`) or a response handler (`>`) has.
local script_items = {
    { "client.global.set", 'client.global.set("${1:key}", ${0})' },
    { "client.global.secret", 'client.global.secret("${1:key}", ${0})' },
    { "client.global.get", 'client.global.get("${1:key}")' },
    { "request.headers.set", 'request.headers.set("${1:Header}", ${0})', "<" },
    { "response.body", "response.body", ">" },
    { "response.status", "response.status", ">" },
    { "response.headers.valueOf", 'response.headers.valueOf("${1:Header}")', ">" },
    { "response.cookies", "response.cookies()", ">" },
    { "response.cookiesByName", 'response.cookiesByName("${1:name}")', ">" },
    { "decodeURIComponent", "decodeURIComponent(${1})" },
    { "encodeURIComponent", "encodeURIComponent(${1})" },
}

--- A dynamic variable as a snippet: `$` escaped, arguments as placeholders.
---@param name string
---@return string
local function dynamic_snippet(name)
    local args = dynamic.variables[name].args
    return "\\" .. name .. (args and "(" .. args .. ")" or "")
end

for _, name in ipairs(vim.fn.sort(vim.tbl_keys(dynamic.variables))) do
    table.insert(script_items, { name, dynamic_snippet(name) })
end

---@param line integer 0-based
---@param from integer 0-based byte column
---@param to integer
---@param text string
local function edit(line, from, to, text)
    return {
        range = { start = { line = line, character = from }, ["end"] = { line = line, character = to } },
        newText = text,
    }
end

--- A variable's value as text, masked when secret like in the panel.
---@param var EnvVar
---@return string
local function shown_value(var)
    if var.type == "secret" then
        return "********"
    end
    return type(var.value) == "string" and var.value or vim.json.encode(var.value)
end

--- Enabled environment variables, as `{{key}}` would use them, and the dynamic variables when `with_dynamic`.
local function env_items(row, from, col, closed, with_dynamic)
    local items = {}
    for _, var in ipairs(state.env) do
        if var.enabled ~= false then
            table.insert(items, {
                label = var.key,
                kind = kind.Variable,
                detail = shown_value(var),
                textEdit = edit(row, from, col, var.key .. (closed and "" or "}}")),
            })
        end
    end
    -- `{{$name}}`: a new value each time
    for name, variable in pairs(with_dynamic and dynamic.variables or {}) do
        table.insert(items, {
            label = name,
            kind = kind.Function,
            detail = variable.doc,
            insertTextFormat = snippet_format,
            textEdit = edit(row, from, col, dynamic_snippet(name) .. (closed and "" or "}}")),
        })
    end
    return items
end

--- Cookies of the jar, one per name; `with_value` inserts `name=value`, for a `Cookie:` header.
local function cookie_items(row, from, col, with_value)
    local items, seen = {}, {}
    for _, cookie in ipairs(cookies.list()) do
        if not seen[cookie.name] then
            seen[cookie.name] = true
            table.insert(items, {
                label = cookie.name,
                kind = kind.Variable,
                detail = cookies.mask(cookie.value) .. "  " .. cookie.domain .. cookie.path,
                textEdit = edit(row, from, col, with_value and cookie.name .. "=" .. cookie.value or cookie.name),
            })
        end
    end
    return items
end

--- The script `row` is inside, which starts on an earlier line: `<` for a
--- `< {% ... %}` pre-request script, `>` for a `> {% ... %}` response handler.
---@param lines string[]
---@param row integer 1-based
---@return "<"|">"|nil
local function script_at(lines, row)
    local open
    for i = 1, row - 1 do
        local line = lines[i]
        local mark = line:match("^%s*([<>])%s*{%%")
        if mark then
            open = not line:match("%%}%s*$") and mark or nil
        elseif line:match("%%}") then
            open = nil
        end
    end
    return open
end

--- Rows of the section holding `row`: its request line, the end of its headers.
---@param lines string[]
---@param row integer 1-based
---@return integer|nil request_row, integer header_end Last header row
local function section_rows(lines, row)
    local start = 1
    for i = row, 1, -1 do
        if lines[i]:match("^###") then
            start = i + 1
            break
        end
    end
    local request_row
    for i = start, #lines do
        local line = lines[i]
        if line:match("^###") then
            break
        end
        local text = vim.trim(line)
        if text ~= "" and not text:match("^#") and not text:match("^//") then
            request_row = i
            break
        end
    end
    if not request_row then
        return nil, 0
    end
    local header_end = #lines
    for i = request_row + 1, #lines do
        if vim.trim(lines[i]) == "" or lines[i]:match("^###") then
            header_end = i - 1
            break
        end
    end
    return request_row, header_end
end

---@param params lsp.CompletionParams
---@return lsp.CompletionItem[]
local function complete(params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        return {}
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local row0, col = params.position.line, params.position.character
    local row = row0 + 1
    local line = lines[row] or ""
    local before, after = line:sub(1, col), line:sub(col + 1)

    local key = before:match("{{%s*([%w_%-%.%$]*)$")
    if key then
        return env_items(row0, col - #key, col, after:match("^%s*}}") ~= nil, true)
    end

    local script = script_at(lines, row)
    if script then
        local name = before:match("client%.global%.get%(%s*[\"']([^\"']*)$")
        if name then
            return env_items(row0, col - #name, col, true)
        end
        local cookie = script == ">" and (before:match("response%.cookiesByName%(%s*[\"']([^\"']*)$")
            or before:match("response%.cookies%(%s*%)%.([%w_]*)$"))
        if cookie then
            return cookie_items(row0, col - #cookie, col, false)
        end
        local word = before:match("[%w_%.%$]*$")
        local items = {}
        for _, item in ipairs(script_items) do
            if not item[3] or item[3] == script then
                table.insert(items, {
                    label = item[1],
                    kind = item[2]:find("%(") and kind.Function or kind.Property,
                    insertTextFormat = snippet_format,
                    textEdit = edit(row0, col - #word, col, item[2]),
                })
            end
        end
        return items
    end
    -- A scripts buffer holds nothing else
    if vim.b[bufnr].http_nvim_scripts then
        return {}
    end

    local request_row, header_end = section_rows(lines, row)
    if line:match("^###") or line:match("^%s*#") or line:match("^%s*//") then
        return {}
    end

    -- The method, at the start of the request line or of the line that becomes it
    if (not request_row or request_row == row) and before:match("^%S*$") then
        -- Replace the rest of a method being edited, and keep one space before the URL
        local rest = after:match("^%a*")
        local space = after:sub(#rest + 1):match("^%s") and "" or " "
        return vim.tbl_map(function(method)
            return { label = method, kind = kind.Keyword, textEdit = edit(row0, 0, col + #rest, method .. space) }
        end, methods)
    end

    if not request_row or row <= request_row or row > header_end then
        return {}
    end

    local name, gap, value = before:match("^([%w%-]+)(:%s*)(.*)$")
    if name and name:lower() == "cookie" then
        -- After `Cookie:` or a `; ` between cookies
        local word = value:match("[^;%s]*$")
        local items = cookie_items(row0, col - #word, col, true)
        if gap == ":" then
            for _, item in ipairs(items) do
                item.textEdit.newText = " " .. item.textEdit.newText
            end
        end
        return items
    end
    if name then
        local values = {}
        for header, list in pairs(headers) do
            if header:lower() == name:lower() then
                values = list
            end
        end
        local space = gap == ":" and " " or ""
        return vim.tbl_map(function(text)
            return { label = text, kind = kind.Value, textEdit = edit(row0, col - #value, col, space .. text) }
        end, values)
    end
    if before:match("^[%w%-]*$") then
        local items = {}
        for header in pairs(headers) do
            table.insert(items, { label = header, kind = kind.Field, textEdit = edit(row0, 0, col, header .. ": ") })
        end
        return items
    end
    return {}
end

--- The variable of the `{{key}}` under the cursor: its value, masked when secret.
---@param params lsp.HoverParams
---@return lsp.Hover|nil
local function hover(params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        return nil
    end
    local row, col = params.position.line, params.position.character
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local init = 1
    while true do
        local from, to, key = line:find("{{%s*([^{}]-)%s*}}", init)
        if not from then
            return nil
        end
        -- `from`/`to` are 1-based and inclusive, `col` 0-based
        if col >= from - 1 and col < to then
            local text = "`{{" .. key .. "}}` is not set"
            local name = key:match("^(%$[%w_%.]+)")
            if name then
                local variable = dynamic.variables[name]
                text = variable and "`" .. name .. "`: " .. variable.doc .. ", made anew on each send"
                    or "`" .. name .. "` is not a dynamic variable"
            end
            for _, var in ipairs(state.env) do
                if var.key == key then
                    text = "`" .. key .. "` = `" .. shown_value(var) .. "`"
                    if var.type == "secret" then
                        text = text .. " (secret)"
                    end
                    if var.enabled == false then
                        text = text .. "\n\nDisabled: `{{" .. key .. "}}` is left as is"
                    end
                    break
                end
            end
            return {
                contents = { kind = "markdown", value = text },
                range = {
                    start = { line = row, character = from - 1 },
                    ["end"] = { line = row, character = to },
                },
            }
        end
        init = to + 1
    end
end

--- The `cmd` of the client: an in-process server.
---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
local function server(dispatchers)
    local closing = false
    local id = 0
    return {
        request = function(method, params, callback)
            id = id + 1
            if method == "initialize" then
                callback(nil, {
                    capabilities = {
                        positionEncoding = "utf-8",
                        completionProvider = { triggerCharacters = { "{", ":", " ", ".", '"', "$" } },
                        hoverProvider = true,
                    },
                    serverInfo = { name = "http-nvim" },
                })
            elseif method == "textDocument/completion" then
                local ok, items = pcall(complete, params)
                callback(nil, { isIncomplete = false, items = ok and items or {} })
            elseif method == "textDocument/hover" then
                local ok, result = pcall(hover, params)
                callback(nil, ok and result or nil)
            elseif method == "shutdown" then
                callback(nil, nil)
            else
                callback({ code = vim.lsp.protocol.ErrorCodes.MethodNotFound, message = method }, nil)
            end
            return true, id
        end,
        notify = function(method)
            if method == "exit" then
                closing = true
                dispatchers.on_exit(0, 15)
            end
            return true
        end,
        is_closing = function()
            return closing
        end,
        terminate = function()
            closing = true
        end,
    }
end

--- Attach the server to a request or scripts edit buffer, unless `setup({ lsp = false })`.
---@param bufnr integer
local function attach(bufnr)
    if not state.lsp then
        return
    end
    local client_id = vim.lsp.start({ name = "http-nvim", cmd = server }, { bufnr = bufnr })
    if client_id and state.lsp.autotrigger then
        vim.lsp.completion.enable(true, client_id, bufnr, { autotrigger = true })
    end
end

return {
    attach = attach,
}
