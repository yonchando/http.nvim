--- Keymaps, customizable with `setup({ keymaps = { ... } })`. Each action maps to a
--- key, a list of keys, or `false` to leave it unmapped.

---@alias HttpNvimKeys string|string[]|false

---@type table<string, HttpNvimKeys>
local defaults = {
    -- Global
    open = "<leader>ho",
    preview_last = "<leader>hrp",
    run_last = "<leader>hre",
    -- Panel and request edit buffers
    send = "<leader>hrr",
    -- Panel
    help = "g?",
    toggle = { "<CR>", "=" },
    add = "a",
    cut = "x",
    copy = "y",
    paste = "p",
    cancel_clipboard = "<Esc>",
    move_down = "]m",
    move_up = "[m",
    edit = "e",
    edit_scripts = "S",
    rename = "r",
    delete = "D",
    undo = "u",
    -- Response layout
    close = "q",
    focus_headers = "<C-l>",
    focus_response = "<C-h>",
}

local descriptions = {
    open = "Open the collection panel",
    preview_last = "Show the last request again",
    run_last = "Send the last request again",
    send = "Send the request",
    help = "Help",
    toggle = "Expand or collapse",
    add = "Add a request or folder",
    cut = "Cut",
    copy = "Copy",
    paste = "Paste",
    cancel_clipboard = "Clear the clipboard",
    move_down = "Move down",
    move_up = "Move up",
    edit = "Edit",
    edit_scripts = "Edit the scripts of the collection or folder",
    rename = "Rename",
    delete = "Delete",
    undo = "Undo delete",
    close = "Close",
    focus_headers = "Go to the headers",
    focus_response = "Go to the response",
}

local current = vim.deepcopy(defaults)

--- Global keys set by `apply_global`, removed before setting new ones.
---@type string[]
local global_lhs = {}

---@param keys HttpNvimKeys
---@return string[]
local function lhs_list(keys)
    if not keys then
        return {}
    end
    return type(keys) == "table" and keys or { keys }
end

--- Merge user keymaps over the defaults; an action given replaces its default keys.
---@param user table<string, HttpNvimKeys>|nil
local function configure(user)
    vim.validate("keymaps", user, "table", true)
    for action, keys in pairs(user or {}) do
        if defaults[action] == nil then
            error("http-nvim: unknown keymap '" .. tostring(action) .. "'")
        end
        local ok = keys == false or type(keys) == "string"
            or (type(keys) == "table" and vim.iter(keys):all(function(k) return type(k) == "string" end))
        if not ok then
            error("http-nvim: keymaps." .. action .. " must be a key, a list of keys, or false")
        end
        current[action] = keys
    end
end

--- Map `action`'s keys in normal mode.
---@param action string
---@param rhs function
---@param bufnr integer|nil Buffer-local when given
local function map(action, rhs, bufnr)
    for _, lhs in ipairs(lhs_list(current[action])) do
        vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = "http-nvim: " .. descriptions[action] })
    end
end

--- (Re)set the global keymaps. Keys set by an earlier call are removed first, so a
--- `setup()` after the plugin file loaded replaces them.
---@param actions table<string, function>
local function apply_global(actions)
    for _, lhs in ipairs(global_lhs) do
        pcall(vim.keymap.del, "n", lhs)
    end
    global_lhs = {}
    for action, rhs in pairs(actions) do
        map(action, rhs)
        vim.list_extend(global_lhs, lhs_list(current[action]))
    end
end

return {
    defaults = defaults,
    configure = configure,
    map = map,
    apply_global = apply_global,
}
