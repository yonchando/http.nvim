--- Environment variables: loading and saving the environment file, and replacing
--- `{{key}}` with their values.
local state = require("http-nvim.state")


--- Read an environment file. A missing file means no variables.
---@param path string
---@return table<string, any> values, table file The whole decoded file
local function load_env(path)
    if vim.fn.filereadable(path) == 0 then
        return {}, {}
    end
    local ok, env = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })
    end)
    if not ok or type(env) ~= "table" or (env.values ~= nil and type(env.values) ~= "table") then
        vim.notify("http-nvim: failed to load environment " .. path, vim.log.levels.ERROR)
        return {}, {}
    end
    return env.values or {}, env
end

---@return boolean
local function write_env()
    local ok, err = pcall(function()
        local file = vim.tbl_extend("force", state.env_file, { values = state.env })
        local json = vim.json.encode(file, { indent = "    ", sort_keys = true })
        vim.fn.mkdir(vim.fn.fnamemodify(state.env_path, ":h"), "p")
        if vim.fn.writefile(vim.split(json, "\n", { plain = true }), state.env_path) ~= 0 then
            error("cannot write file")
        end
    end)
    if not ok then
        vim.notify("http-nvim: failed to write environment " .. state.env_path .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
    return ok
end

--- How a value shows in the panel and the edit buffer: strings as is, anything else as JSON.
---@param value any
---@return string
local function env_text(value)
    return type(value) == "string" and value or vim.json.encode(value)
end

--- Parse `KEY=value` lines. Blank lines and `#` comments are skipped, and a value
--- wrapped in matching quotes loses them. A value that reads back as the JSON of a
--- non-string original keeps that original.
---@param lines string[]
---@return table<string, any>|nil values, string|nil err
local function parse_env_lines(lines)
    local values = {}
    for i, line in ipairs(lines) do
        local text = vim.trim(line)
        if text ~= "" and text:sub(1, 1) ~= "#" then
            local key, value = text:match("^([^=%s]+)%s*=%s*(.*)$")
            if not key then
                return nil, "line " .. i .. ": expected KEY=value"
            end
            if values[key] ~= nil then
                return nil, "line " .. i .. ": duplicate variable '" .. key .. "'"
            end
            local quote = value:sub(1, 1)
            if #value >= 2 and (quote == '"' or quote == "'") and value:sub(-1) == quote then
                value = value:sub(2, -2)
            end
            local original = state.env[key]
            if original ~= nil and type(original) ~= "string" and env_text(original) == value then
                value = original
            end
            values[key] = value
        end
    end
    return values, nil
end

--- Floating layout with two stacked boxes: 10% on top, 90% below.
--- Replace every `{{key}}` with its environment value; unknown keys are left as is.
---@param text string
---@return string
local function expand_env(text)
    return (text:gsub("{{%s*([^{}%s]+)%s*}}", function(key)
        local value = state.env[key]
        if value == nil then
            return nil
        end
        return env_text(value)
    end))
end

return {
    load_env = load_env,
    write_env = write_env,
    env_text = env_text,
    parse_env_lines = parse_env_lines,
    expand_env = expand_env,
}
