--- Environment variables: loading and saving the environment file (Postman
--- environment format), and replacing `{{key}}` with their values.
local state = require("http-nvim.state")

--- A variable of a Postman environment. Other fields Postman writes are kept as is.
---@class EnvVar
---@field key string
---@field value any
---@field type string|nil `default` or `secret`
---@field enabled boolean|nil Disabled when false: listed, but not used for `{{key}}`

--- Read an environment file. A missing file means no variables. The older
--- `{ "values": { "key": "value" } }` shape is read too, and saved as Postman's.
---@param path string
---@return EnvVar[] vars, table file The whole decoded file
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
    local values = env.values or {}
    if vim.islist(values) then
        return values, env
    end
    local vars = {}
    for _, key in ipairs(vim.fn.sort(vim.tbl_keys(values))) do
        table.insert(vars, { key = key, value = values[key], type = "default", enabled = true })
    end
    return vars, env
end

---@return boolean
local function write_env()
    local ok, err = pcall(function()
        local file = vim.tbl_extend("force", state.env_file, {
            name = state.env_file.name or state.selected,
            values = state.env,
            _postman_variable_scope = "environment",
        })
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
    if value == nil then
        return ""
    end
    return type(value) == "string" and value or vim.json.encode(value)
end

-- What a secret value shows as in the panel
local mask = "********"

--- `KEY=value`, commented out with `# ` when the variable is disabled. A secret
--- variable (`type = "secret"`) has its value masked in the panel, and ends with
--- `# secret` in the edit buffer.
---@param var EnvVar
---@param separator string `=` in the edit buffer, ` = ` in the panel
---@param masked boolean|nil Mask a secret value, for the panel
---@return string
local function env_line(var, separator, masked)
    local secret = var.type == "secret"
    local value
    if secret and masked then
        value = mask
    else
        value = env_text(var.value) .. (secret and " # secret" or "")
    end
    return (var.enabled == false and "# " or "") .. var.key .. separator .. value
end

---@param key string
---@return EnvVar|nil
local function find(key)
    for _, var in ipairs(state.env) do
        if var.key == key then
            return var
        end
    end
end

--- Parse `KEY=value` lines; `# KEY=value` is a disabled variable. Other `#`
--- comments and blank lines are skipped. A line ending with `# secret` is a
--- secret variable, and without it a secret one becomes `default`. A value
--- wrapped in matching quotes loses them. Variables keep the other fields they had, and a value that reads
--- back as the JSON of a non-string original keeps that original.
---@param lines string[]
---@return EnvVar[]|nil vars, string|nil err
local function parse_env_lines(lines)
    local vars, seen = {}, {}
    for i, line in ipairs(lines) do
        local text = vim.trim(line)
        local key, value, enabled
        if text:sub(1, 1) == "#" then
            key, value = vim.trim(text:sub(2)):match("^([%w_%-%.]+)%s*=%s*(.*)$")
            enabled = false
        elseif text ~= "" then
            key, value = text:match("^([^=%s]+)%s*=%s*(.*)$")
            if not key then
                return nil, "line " .. i .. ": expected KEY=value"
            end
            enabled = true
        end
        if key then
            if seen[key] then
                return nil, "line " .. i .. ": duplicate variable '" .. key .. "'"
            end
            seen[key] = true
            local unmarked = value:match("^(.-)%s+#%s*secret%s*$") or (value:match("^#%s*secret%s*$") and "")
            value = unmarked or value
            local quote = value:sub(1, 1)
            if #value >= 2 and (quote == '"' or quote == "'") and value:sub(-1) == quote then
                value = value:sub(2, -2)
            end
            local original = find(key)
            local var = original and vim.deepcopy(original) or { key = key, type = "default" }
            if not (original and type(original.value) ~= "string" and env_text(original.value) == value) then
                var.value = value
            end
            var.enabled = enabled
            if unmarked then
                var.type = "secret"
            elseif var.type == "secret" then
                var.type = "default"
            end
            table.insert(vars, var)
        end
    end
    return vars, nil
end

--- Set variables (e.g. from a response handler) and save the environment: a
--- new key is added, an existing one gets the value and stays enabled or not.
--- `secret` makes the variable a secret one; otherwise an existing one keeps its type.
--- The panel and an unmodified environment edit buffer show the new values.
---@param vars { key: string, value: any, secret: boolean|nil }[]
local function set_vars(vars)
    for _, new in ipairs(vars) do
        local var = find(new.key)
        if var then
            var.value = new.value
            if new.secret then
                var.type = "secret"
            end
        else
            table.insert(state.env, {
                key = new.key,
                value = new.value,
                type = new.secret and "secret" or "default",
                enabled = true,
            })
        end
    end
    if not write_env() then
        return
    end
    local bufnr = state.env_buf
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        if vim.bo[bufnr].modified then
            vim.notify("http-nvim: the environment edit buffer has unsaved changes; saving it overwrites the new values",
                vim.log.levels.WARN)
        else
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.tbl_map(function(var)
                return env_line(var, "=")
            end, state.env))
            vim.bo[bufnr].modified = false
        end
    end
    if state.split and state.split.bufnr and vim.api.nvim_buf_is_valid(state.split.bufnr) then
        -- The panel requires this module
        require("http-nvim.panel").render()
    end
end

--- Replace every `{{key}}` with its environment value; unknown and disabled keys are left as is.
---@param text string
---@return string
local function expand_env(text)
    return (text:gsub("{{%s*([^{}%s]+)%s*}}", function(key)
        local var = find(key)
        if not var or var.enabled == false then
            return nil
        end
        return env_text(var.value)
    end))
end

return {
    load_env = load_env,
    write_env = write_env,
    env_line = env_line,
    parse_env_lines = parse_env_lines,
    set_vars = set_vars,
    find = find,
    expand_env = expand_env,
}
