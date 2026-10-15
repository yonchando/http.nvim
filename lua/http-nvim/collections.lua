--- Named collections: one folder per collection in `state.collection_dir`, each
--- holding `collection.json` and `env.json`. Creating, listing and choosing them.
local collection = require("http-nvim.collection")
local edit = require("http-nvim.edit")
local state = require("http-nvim.state")

--- Folder names in `collection_dir`, sorted.
---@return string[]
local function list()
    local names = {}
    if vim.fn.isdirectory(state.collection_dir) == 0 then
        return names
    end
    for name, type in vim.fs.dir(state.collection_dir) do
        if type == "directory" then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

--- Write `value` as JSON unless `path` already exists.
---@param path string
---@param value table
---@return boolean written
local function write_new_json(path, value)
    if vim.fn.filereadable(path) == 1 then
        return false
    end
    local json = vim.json.encode(value, { indent = "    ", sort_keys = true })
    if vim.fn.writefile(vim.split(json, "\n", { plain = true }), path) ~= 0 then
        error("cannot write " .. path)
    end
    return true
end

--- Use the collection `name` from now on. What is open belongs to the previous
--- collection, so it is closed: saving it would write into the new one.
---@param name string
---@return boolean selected False when an edit buffer has unsaved changes
local function select(name)
    if state.selected == name then
        return true
    end
    if state.selected then
        local closed, modified = edit.close_edit_bufs()
        if not closed then
            vim.notify("http-nvim: save or discard " .. modified .. " before switching collections; keeping '"
                .. state.selected .. "'", vim.log.levels.ERROR)
            return false
        end
        if state.split and state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
            state.split:unmount()
        end
    end
    local dir = state.collection_dir .. "/" .. name
    state.selected = name
    state.collection_path = dir .. "/collection.json"
    state.env_path = dir .. "/env.json"
    state.cookie_path = dir .. "/cookie"
    -- Load the new files on the next `open()`
    state.collection = nil
    return true
end

--- Create the folder `name` with an empty `collection.json` and `env.json`. Existing
--- files are left as they are. The new collection is selected if none is yet.
---@param name string
local function create(name)
    name = vim.trim(name or "")
    if name == "" or name == "." or name == ".." or name:find("/", 1, true) then
        vim.notify("http-nvim: invalid collection name '" .. name .. "'", vim.log.levels.ERROR)
        return
    end
    local dir = state.collection_dir .. "/" .. name
    local ok, result = pcall(function()
        vim.fn.mkdir(dir, "p")
        local wrote_collection = write_new_json(dir .. "/collection.json", collection.empty(name))
        local wrote_env = write_new_json(dir .. "/env.json", {
            name = name,
            values = {},
            _postman_variable_scope = "environment",
        })
        return wrote_collection or wrote_env
    end)
    if not ok then
        vim.notify("http-nvim: failed to create collection " .. dir .. ": " .. tostring(result), vim.log.levels.ERROR)
        return
    end
    vim.notify("http-nvim: " .. (result and "created " or "already exists: ") .. dir)
    if not state.selected then
        select(name)
    end
end

--- Ask which collection to use, then call `on_done` once it is selected.
---@param on_done fun()
local function pick(on_done)
    local names = list()
    if #names == 0 then
        vim.notify("http-nvim: no collections in " .. state.collection_dir
            .. ", create one with :Http create <name>", vim.log.levels.WARN)
        return
    end
    vim.ui.select(names, { prompt = "http-nvim collection" }, function(choice)
        if choice and select(choice) then
            on_done()
        end
    end)
end

return {
    list = list,
    create = create,
    select = select,
    pick = pick,
}
