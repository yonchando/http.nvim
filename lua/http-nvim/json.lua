--- A small JSON checker and formatter for request bodies. Unlike `vim.json`, it
--- keeps the text as written: key order, number and string spelling, comments.
--- `{{key}}` outside a string is a value, since it is replaced before sending,
--- e.g. `{ "id": {{id}} }`.

---@class JsonToken
---@field type string `{`, `}`, `[`, `]`, `:`, `,`, `string`, `number`, `literal`, `placeholder` or `comment`
---@field s integer Byte offset of its first character, 1-based
---@field e integer Byte offset of its last character
---@field text string

---@class JsonProblem
---@field s integer Byte offset where it starts, 1-based
---@field e integer Byte offset where it ends, inclusive
---@field message string
---@field warning boolean|nil Valid enough to send, but servers may reject it (comments, duplicate keys)

---@param text string
---@param i integer At the opening quote
---@return integer|nil e The closing quote, string|nil err, integer|nil at Where the error is
local function scan_string(text, i)
    local j = i + 1
    while j <= #text do
        local c = text:sub(j, j)
        if c == '"' then
            return j, nil, nil
        elseif c == "\n" then
            return nil, "the string is not closed on this line", i
        elseif c == "\\" then
            local next = text:sub(j + 1, j + 1)
            if next == "u" then
                if not text:sub(j + 2, j + 5):match("^%x%x%x%x$") then
                    return nil, "'\\u' needs 4 hex digits", j
                end
                j = j + 6
            elseif next ~= "" and ('"\\/bfnrt'):find(next, 1, true) then
                j = j + 2
            else
                return nil, "invalid escape '\\" .. next .. "'", j
            end
        else
            j = j + 1
        end
    end
    return nil, "the string is not closed", i
end

--- Whether `word` is a JSON number: no leading zeros, digits after `.` and `e`.
---@param word string
---@return boolean
local function is_number(word)
    local rest = word:match("^%-?0(.*)$") or word:match("^%-?[1-9]%d*(.*)$")
    if not rest then
        return false
    end
    rest = rest:match("^%.%d+(.*)$") or rest
    rest = rest:match("^[eE][%+%-]?%d+(.*)$") or rest
    return rest == ""
end

--- Split `text` into tokens; stops at the first character that can't start one.
---@param text string
---@return JsonToken[] tokens, JsonProblem|nil err
local function scan(text)
    local tokens = {}
    local i = 1
    local function add(type, s, e)
        table.insert(tokens, { type = type, s = s, e = e, text = text:sub(s, e) })
    end
    while i <= #text do
        local c = text:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == "{" and text:sub(i + 1, i + 1) == "{" then
            local close = text:find("}}", i + 2, true)
            if not close then
                return tokens, { s = i, e = i + 1, message = "'{{' is not closed with '}}'" }
            end
            add("placeholder", i, close + 1)
            i = close + 2
        elseif ("{}[]:,"):find(c, 1, true) then
            add(c, i, i)
            i = i + 1
        elseif c == '"' then
            local e, err, at = scan_string(text, i)
            if not e then
                return tokens, { s = at, e = at, message = err }
            end
            add("string", i, e)
            i = e + 1
        elseif text:sub(i, i + 1) == "//" then
            local e = (text:find("\n", i, true) or #text + 1) - 1
            add("comment", i, e)
            i = e + 1
        elseif text:sub(i, i + 1) == "/*" then
            local _, e = text:find("*/", i + 2, true)
            if not e then
                return tokens, { s = i, e = i + 1, message = "'/*' is not closed with '*/'" }
            end
            add("comment", i, e)
            i = e + 1
        elseif c:match("[%-%d]") then
            local word = text:match("^[%w%.%+%-]+", i)
            if not is_number(word) then
                return tokens, { s = i, e = i + #word - 1, message = "invalid number '" .. word .. "'" }
            end
            add("number", i, i + #word - 1)
            i = i + #word
        elseif c:match("[%a_$]") then
            local word = text:match("^[%w_$]+", i)
            if word ~= "true" and word ~= "false" and word ~= "null" then
                return tokens, {
                    s = i,
                    e = i + #word - 1,
                    message = "unexpected '" .. word .. "': keys and strings need double quotes",
                }
            end
            add("literal", i, i + #word - 1)
            i = i + #word
        elseif c == "'" then
            return tokens, { s = i, e = i, message = "strings use double quotes, not '" }
        else
            return tokens, { s = i, e = i, message = "unexpected character '" .. c .. "'" }
        end
    end
    return tokens, nil
end

local values = { string = true, number = true, literal = true, placeholder = true }

--- Problems with `text` as JSON: the first error, and warnings for comments and
--- duplicate keys. Blank text has none.
---@param text string
---@return JsonProblem[]
local function check(text)
    local all, scan_err = scan(text)
    local problems = {}
    local tokens = {}
    for _, token in ipairs(all) do
        if token.type == "comment" then
            table.insert(problems, {
                s = token.s,
                e = token.e,
                message = "comments are not JSON: the server may reject the body",
                warning = true,
            })
        else
            table.insert(tokens, token)
        end
    end
    if scan_err then
        table.insert(problems, scan_err)
        return problems
    end
    if #tokens == 0 then
        return problems
    end

    local pos = 1
    -- Raised as `{ problem = ... }` to stop at the first error
    local function fail(token, message)
        error({ problem = { s = token.s, e = token.e, message = message } })
    end
    local function at_end(open)
        fail(open, "'" .. open.type .. "' is not closed with '" .. (open.type == "{" and "}" or "]") .. "'")
    end
    local value
    local function list(open, close, item)
        local token = tokens[pos]
        if token and token.type == close then
            pos = pos + 1
            return
        end
        while true do
            item()
            token = tokens[pos]
            if not token then
                at_end(open)
            elseif token.type == close then
                pos = pos + 1
                return
            elseif token.type ~= "," then
                fail(token, "expected ',' or '" .. close .. "' before '" .. token.text .. "'")
            end
            pos = pos + 1
            if tokens[pos] and tokens[pos].type == close then
                fail(token, "trailing comma before '" .. close .. "'")
            end
        end
    end
    value = function()
        local token = tokens[pos]
        if not token then
            fail(tokens[#tokens], "expected a value after '" .. tokens[#tokens].text .. "'")
        end
        pos = pos + 1
        if values[token.type] then
            return
        elseif token.type == "{" then
            local seen = {}
            list(token, "}", function()
                local key = tokens[pos]
                if not key then
                    at_end(token)
                elseif key.type ~= "string" then
                    fail(key, "expected a key in double quotes, found '" .. key.text .. "'")
                end
                if seen[key.text] then
                    table.insert(problems, {
                        s = key.s,
                        e = key.e,
                        message = "duplicate key " .. key.text .. ": the server keeps only one",
                        warning = true,
                    })
                end
                seen[key.text] = true
                pos = pos + 1
                local colon = tokens[pos]
                if not colon or colon.type ~= ":" then
                    fail(colon or key, "expected ':' after the key " .. key.text)
                end
                pos = pos + 1
                value()
            end)
        elseif token.type == "[" then
            list(token, "]", value)
        else
            fail(token, "expected a value, found '" .. token.text .. "'")
        end
    end

    local ok, err = pcall(function()
        value()
        local extra = tokens[pos]
        if extra then
            fail(extra, "unexpected '" .. extra.text .. "' after the end of the JSON value")
        end
    end)
    if not ok then
        if type(err) ~= "table" or not err.problem then
            error(err, 0)
        end
        table.insert(problems, err.problem)
    end
    return problems
end

--- The first error of `check`, if any.
---@param problems JsonProblem[]
---@return JsonProblem|nil
local function first_error(problems)
    for _, problem in ipairs(problems) do
        if not problem.warning then
            return problem
        end
    end
end

--- `text` laid out with one key or item per line, indented by `indent`. Keys
--- stay in order, values and comments as written; empty `{}` and `[]` stay on
--- one line. Nil, with the error, when `text` is not valid JSON.
---@param text string
---@param indent string
---@return string|nil formatted, JsonProblem|nil err
local function format(text, indent)
    local err = first_error(check(text))
    if err then
        return nil, err
    end
    local tokens = scan(text)
    local out, depth, pending = {}, 0, false
    local function emit(s)
        if pending then
            table.insert(out, "\n" .. indent:rep(depth))
            pending = false
        end
        table.insert(out, s)
    end
    local i = 1
    while i <= #tokens do
        local token = tokens[i]
        local type = token.type
        if type == "{" or type == "[" then
            local next = tokens[i + 1]
            if next and next.type == (type == "{" and "}" or "]") then
                emit(type .. next.type)
                i = i + 1
            else
                emit(type)
                depth = depth + 1
                pending = true
            end
        elseif type == "}" or type == "]" then
            depth = depth - 1
            pending = true
            emit(type)
        elseif type == "," then
            emit(",")
            pending = true
        elseif type == ":" then
            emit(": ")
        elseif type == "comment" then
            -- A comment on the same line as the token before it stays there
            local before = tokens[i - 1]
            if before and not text:sub(before.e + 1, token.s - 1):find("\n") then
                pending = false
                emit(" ")
            end
            emit(token.text)
            pending = true
        else
            emit(token.text)
        end
        i = i + 1
    end
    return table.concat(out), nil
end

--- Line and column (both 0-based, the column in bytes) of byte offset `offset` in `text`.
---@param text string
---@param offset integer 1-based
---@return integer line, integer col
local function position(text, offset)
    local line, start = 0, 1
    for nl in text:sub(1, offset - 1):gmatch("()\n") do
        line = line + 1
        start = nl + 1
    end
    return line, offset - start
end

return {
    check = check,
    first_error = first_error,
    format = format,
    position = position,
}
