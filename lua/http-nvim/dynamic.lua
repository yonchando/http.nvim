--- Dynamic variables: values made anew each time they are read, named after the
--- JetBrains HTTP Client ones. They work in scripts (`$random.email`) and in a
--- request as `{{$random.email}}`.

math.randomseed(vim.uv.hrtime())

local lower = "abcdefghijklmnopqrstuvwxyz"
local letters = lower .. lower:upper()
local digits = "0123456789"

--- `length` characters picked from `chars`.
---@param chars string
---@param length integer
---@return string
local function pick(chars, length)
    local out = {}
    for i = 1, length do
        local n = math.random(1, #chars)
        out[i] = chars:sub(n, n)
    end
    return table.concat(out)
end

--- A random version 4 UUID.
---@return string
local function uuid()
    return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
        local n = math.random(0, 15)
        return ("%x"):format(c == "x" and n or 8 + n % 4)
    end))
end

---@param args number[]
---@param kind string What the error message calls the value
---@return integer|nil length, string|nil err
local function length_of(args, kind)
    local length = args[1] or 10
    if #args > 1 or length < 0 or math.floor(length) ~= length then
        return nil, "expected $random." .. kind .. "(length) with a whole number"
    end
    return length, nil
end

---@param args number[]
---@param whole boolean
---@return number|nil from, number|nil to, string|nil err
local function range_of(args, whole)
    local from, to = args[1] or 0, args[2] or 1000
    if #args > 2 or from > to or (whole and (math.floor(from) ~= from or math.floor(to) ~= to)) then
        return nil, nil, "expected (from, to) with from <= to" .. (whole and ", whole numbers" or "")
    end
    return from, to, nil
end

--- Each variable: how it is made from its arguments, and a description.
---@type table<string, { make: fun(args: number[]): (string|number|nil, string|nil), args: string|nil, doc: string }>
local variables = {
    ["$uuid"] = { make = uuid, doc = "A random UUID (version 4)" },
    ["$random.uuid"] = { make = uuid, doc = "A random UUID (version 4)" },
    ["$timestamp"] = {
        make = function()
            return os.time()
        end,
        doc = "The Unix time, in seconds",
    },
    ["$isoTimestamp"] = {
        make = function()
            return os.date("!%Y-%m-%dT%H:%M:%SZ")
        end,
        doc = "The UTC time, e.g. 2026-10-17T09:30:00Z",
    },
    ["$randomInt"] = {
        make = function()
            return math.random(0, 1000)
        end,
        doc = "A random integer from 0 to 1000",
    },
    ["$random.integer"] = {
        make = function(args)
            local from, to, err = range_of(args, true)
            if not from then
                return nil, "$random.integer: " .. err
            end
            return math.random(from, to), nil
        end,
        args = "${1:0}, ${2:1000}",
        doc = "A random integer from `from` to `to` (0 and 1000 by default)",
    },
    ["$random.float"] = {
        make = function(args)
            local from, to, err = range_of(args, false)
            if not from then
                return nil, "$random.float: " .. err
            end
            return from + math.random() * (to - from), nil
        end,
        args = "${1:0}, ${2:1000}",
        doc = "A random number from `from` to `to` (0 and 1000 by default)",
    },
    ["$random.alphabetic"] = {
        make = function(args)
            local length, err = length_of(args, "alphabetic")
            return length and pick(letters, length), err
        end,
        args = "${1:10}",
        doc = "`length` random letters (10 by default)",
    },
    ["$random.alphanumeric"] = {
        make = function(args)
            local length, err = length_of(args, "alphanumeric")
            return length and pick(letters .. digits .. "_", length), err
        end,
        args = "${1:10}",
        doc = "`length` random letters, digits and `_` (10 by default)",
    },
    ["$random.hexadecimal"] = {
        make = function(args)
            local length, err = length_of(args, "hexadecimal")
            return length and pick(digits .. "abcdef", length), err
        end,
        args = "${1:10}",
        doc = "`length` random hexadecimal digits (10 by default)",
    },
    ["$random.email"] = {
        make = function()
            return pick(lower, 8) .. math.random(10, 99) .. "@example.com", nil
        end,
        doc = "A random email address at example.com",
    },
}

--- The value of `$name` or `$name(args)`, the arguments being numbers.
---@param text string
---@return string|number|nil value, string|nil err, boolean known Whether `text` names a dynamic variable
local function eval(text)
    text = vim.trim(text)
    local name, inner = text:match("^(%$[%w_%.]+)%s*%((.*)%)$")
    name = name or text
    local variable = variables[name]
    if not variable then
        return nil, "unknown dynamic variable '" .. name .. "'", false
    end
    local args = {}
    if inner and vim.trim(inner) ~= "" then
        for part in (inner .. ","):gmatch("([^,]*),") do
            local n = tonumber(vim.trim(part))
            if not n then
                return nil, name .. ": '" .. vim.trim(part) .. "' is not a number", true
            end
            table.insert(args, n)
        end
    end
    if inner and not variable.args then
        return nil, name .. " takes no arguments", true
    end
    local value, err = variable.make(args)
    return value, err, true
end

return {
    variables = variables,
    eval = eval,
}
