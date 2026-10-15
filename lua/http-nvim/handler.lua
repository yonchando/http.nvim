--- Response handler scripts (`> {% ... %}`), with the JetBrains HTTP Client API
--- only: there is no JavaScript engine, so only the calls that set a variable are
--- read, and their values are taken from the response:
---
---   client.global.set("token", response.body.data.token)
---   client.global.set("auth", "Bearer " + response.body.token)
---   client.global.secret("password", response.body.password)
---
--- `secret(key, value)` works like `set` and also makes the variable a secret
--- one (Postman type `secret`), masked in the panel; `set` keeps the type.
--- A value is `+`-joined terms: string or number literals, `response.body`
--- followed by `.key`, `["key"]` and `[0]` accessors, `response.status`,
--- `response.headers.valueOf("Name")`, `response.cookies()` (an object of the
--- cookies the response set, accessors allowed) or `response.cookiesByName("name")`.
--- `decodeURIComponent(value)` and `encodeURIComponent(value)` wrap any value.
--- Each variable is set in the environment and saved.

---@class HandlerResponse
---@field status integer|nil
---@field headers table<string, string> Keyed by lowercase name
---@field cookies table<string, string> Cookies set by `Set-Cookie`, keyed by name
---@field body any Decoded JSON, or the text when it is not JSON
---@field text string

-- The object whose `set(key, value)` and `secret(key, value)` set an environment variable
local setter = "client.global"

local escapes = { n = "\n", t = "\t", r = "\r" }

--- Read the string literal whose opening quote is at `i`.
---@param s string
---@param i integer
---@return string|nil value, integer next Index after the closing quote
local function read_string(s, i)
    local quote = s:sub(i, i)
    local out = {}
    i = i + 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" then
            local next = s:sub(i + 1, i + 1)
            table.insert(out, escapes[next] or next)
            i = i + 2
        elseif c == quote then
            return table.concat(out), i + 1
        else
            table.insert(out, c)
            i = i + 1
        end
    end
    return nil, i
end

--- Split `s` at each `separator` outside quotes and brackets, stopping at the
--- `)` that closes the call (depth below 0).
---@param s string
---@param i integer
---@param separator string
---@return string[] parts, integer next Index after the closing `)`, or past the end
local function split_top(s, i, separator)
    local parts, start, depth = {}, i, 0
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' or c == "'" or c == "`" then
            local _, next = read_string(s, i)
            i = next
        else
            if c == "(" or c == "[" or c == "{" then
                depth = depth + 1
            elseif c == ")" or c == "]" or c == "}" then
                depth = depth - 1
                if depth < 0 then
                    break
                end
            elseif c == separator and depth == 0 then
                table.insert(parts, vim.trim(s:sub(start, i - 1)))
                start = i + 1
            end
            i = i + 1
        end
    end
    table.insert(parts, vim.trim(s:sub(start, i - 1)))
    return parts, i + 1
end

--- Every `client.global.set("key", expression)` and `client.global.secret(...)` call in the script.
---@param script string[]
---@return { key: string, expr: string, secret: boolean }[] calls, string[] errors
local function parse_set_calls(script)
    local text = table.concat(script, "\n")
    local calls, errors = {}, {}
    local pos = 1
    while true do
        local start, finish, owner, method = text:find("([%w_%.]+)%.(%a+)%s*%(", pos)
        if not start then
            break
        end
        if not (owner == setter and (method == "set" or method == "secret")) then
            -- Not a setter: look inside its arguments too
            pos = finish + 1
        else
            local args, next = split_top(text, finish + 1, ",")
            pos = next
            local quote = args[1]:sub(1, 1)
            local key = (quote == '"' or quote == "'" or quote == "`") and read_string(args[1], 1)
            if not key or #args ~= 2 then
                table.insert(errors, owner .. "." .. method .. "(" .. table.concat(args, ", ") ..
                    "): expected a string key and a value")
            else
                table.insert(calls, { key = key, expr = args[2], secret = method == "secret" })
            end
        end
    end
    return calls, errors
end

--- Follow `.key`, `["key"]` and `[0]` accessors from `value`.
---@param value any
---@param chain string
---@return any|nil value, string|nil err
local function access(value, chain)
    local rest = chain
    while rest ~= "" do
        local key, after = rest:match("^%.([%a_$][%w_$]*)()")
        if not key then
            local index
            index, after = rest:match("^%[%s*(%d+)%s*%]()")
            if index then
                key = tonumber(index) + 1
            else
                local _, quoted
                _, quoted, after = rest:match("^%[%s*([\"'])(.-)%1%s*%]()")
                key = quoted
            end
        end
        if not key then
            return nil, "cannot read '" .. rest .. "'"
        end
        if key == "length" and type(value) == "table" and vim.islist(value) then
            value = #value
        elseif type(value) ~= "table" then
            return nil, "no '" .. tostring(key) .. "' in a " .. type(value)
        else
            value = value[key]
        end
        if value == nil or value == vim.NIL then
            return nil, "'" .. chain .. "' is undefined"
        end
        rest = rest:sub(after)
    end
    return value, nil
end

local eval

-- JavaScript's `encodeURIComponent` keeps these as is
local function encode_uri_component(text)
    return (text:gsub("[^%w%-_%.!~%*'%(%)]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

-- Functions that take one value and return text
local functions = {
    decodeURIComponent = vim.uri_decode,
    encodeURIComponent = encode_uri_component,
}

---@param term string
---@param response HandlerResponse
---@return any|nil value, string|nil err
local function eval_term(term, response)
    local fn, arg = term:match("^(%a+)%((.*)%)$")
    if fn and functions[fn] then
        local value, err = eval(arg, response)
        if value == nil then
            return nil, err
        end
        return functions[fn](type(value) == "table" and vim.json.encode(value) or value), nil
    end
    local quote = term:sub(1, 1)
    if quote == '"' or quote == "'" or quote == "`" then
        local value, next = read_string(term, 1)
        if value and next > #term then
            return value, nil
        end
    end
    if term:match("^%-?%d+%.?%d*$") then
        return tonumber(term), nil
    end
    if term == "response.status" then
        return response.status, nil
    end
    local _, name = term:match("^response%.headers%.valueOf%(%s*([\"'])(.-)%1%s*%)$")
    if name then
        local value = response.headers[name:lower()]
        if not value then
            return nil, "no header '" .. name .. "'"
        end
        return value, nil
    end
    local chain = term:match("^response%.body(.*)$")
    if chain then
        return access(response.body, chain)
    end
    chain = term:match("^response%.cookies%(%s*%)(.*)$")
    if chain then
        return access(response.cookies, chain)
    end
    _, name = term:match("^response%.cookiesByName%(%s*([\"'])(.-)%1%s*%)$")
    if name then
        local value = response.cookies[name]
        if not value then
            return nil, "no cookie '" .. name .. "'"
        end
        return value, nil
    end
    return nil, "unsupported value '" .. term .. "'"
end

--- A single term keeps its type (e.g. an object); joined terms make a string.
---@param expr string
---@param response HandlerResponse
---@return any|nil value, string|nil err
eval = function(expr, response)
    local terms = split_top(expr, 1, "+")
    local values = {}
    for _, term in ipairs(terms) do
        local value, err = eval_term(term, response)
        if value == nil then
            return nil, err
        end
        table.insert(values, value)
    end
    if #values == 1 then
        local value = values[1]
        return type(value) == "table" and value or tostring(value), nil
    end
    return table.concat(vim.tbl_map(function(value)
        return type(value) == "table" and vim.json.encode(value) or tostring(value)
    end, values)), nil
end

--- Response headers from curl's `--verbose` `< Name: value` lines, the last response's winning.
---@param header_lines string[]
---@return table<string, string>
local function parse_headers(header_lines)
    local headers = {}
    for _, line in ipairs(header_lines) do
        local name, value = line:match("^< ([^:%s]+):%s*(.-)%s*$")
        if name then
            headers[name:lower()] = value
        end
    end
    return headers
end

--- Cookies set by curl's `--verbose` `< Set-Cookie: name=value; ...` lines, over
--- every response (redirects too), a later one winning.
---@param header_lines string[]
---@return table<string, string>
local function parse_cookies(header_lines)
    local cookies = vim.empty_dict()
    for _, line in ipairs(header_lines) do
        local cookie = line:match("^< [Ss][Ee][Tt]%-[Cc][Oo][Oo][Kk][Ii][Ee]:%s*(.-)%s*$")
        local name, value = (cookie or ""):match("^([^=;%s]+)%s*=%s*([^;]*)")
        if name then
            value = vim.trim(value)
            cookies[name] = value:match('^"(.*)"$') or value
        end
    end
    return cookies
end

--- Run the script's `set` calls against the response and save the variables they set.
---@param script string[]
---@param response HandlerResponse
local function run(script, response)
    local calls, errors = parse_set_calls(script)
    local vars = {}
    for _, call in ipairs(calls) do
        local value, err = eval(call.expr, response)
        if value == nil then
            table.insert(errors, call.key .. ": " .. err)
        else
            table.insert(vars, { key = call.key, value = value, secret = call.secret })
        end
    end
    if #vars > 0 then
        require("http-nvim.env").set_vars(vars)
        vim.notify("http-nvim: set " .. table.concat(vim.tbl_map(function(var)
            return var.key
        end, vars), ", "))
    end
    if #errors > 0 then
        vim.notify("http-nvim: response handler: " .. table.concat(errors, "; "), vim.log.levels.WARN)
    end
end

return {
    parse_headers = parse_headers,
    parse_cookies = parse_cookies,
    run = run,
}
