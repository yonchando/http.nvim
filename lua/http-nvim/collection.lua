--- The Postman collection: loading and saving it, the undo file for deletions,
--- and helpers to find and add items in its tree.
local state = require("http-nvim.state")

---@class PostmanRequest
---@field method string
---@field url string|{ raw: string }
---@field header { key: string, value: string }[]|nil
---@field body { mode: string, raw: string }|nil

--- A folder (has `item`) or a request (has `request`).
---@class PostmanItem
---@field name string
---@field item PostmanItem[]|nil
---@field request PostmanRequest|string|nil
---@field event { listen: string, script: { type: string, exec: string[]|string } }[]|nil Postman scripts; the `test` one is the response handler

--- Postman collection format v2.1.
---@class PostmanCollection
---@field info { name: string, schema: string|nil }
---@field item PostmanItem[]

---@class DeletedItem
---@field list PostmanItem[]|nil The list it was removed from; nil when loaded from the undo file
---@field parent string[] Names of the folders that held it, from the top level
---@field index integer
---@field node PostmanItem

--- A collection with no items.
---@param name string
---@return PostmanCollection
local function empty(name)
    return {
        info = {
            name = name,
            schema = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        },
        item = {},
    }
end

---@param path string
---@return PostmanCollection
local function load_collection(path)
    -- Named after the collection's folder
    local fallback = empty(vim.fn.fnamemodify(path, ":h:t"))
    -- A new collection: the file is created on the first save
    if vim.fn.filereadable(path) == 0 then
        return fallback
    end
    local ok, collection = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })
    end)
    if not ok or type(collection) ~= "table" then
        vim.notify("http-nvim: failed to load collection " .. path, vim.log.levels.ERROR)
        return fallback
    end
    collection.item = collection.item or {}
    return collection
end

---@param path string
---@return boolean
local function write_collection(path)
    -- Keys come out sorted: the decoded tables do not keep the file's key order
    local ok, err = pcall(function()
        local json = vim.json.encode(state.collection, { indent = "    ", sort_keys = true })
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        if vim.fn.writefile(vim.split(json, "\n", { plain = true }), path) ~= 0 then
            error("cannot write file")
        end
    end)
    if not ok then
        vim.notify("http-nvim: failed to write collection " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
    return ok
end

--- File in the first 'undodir' entry that keeps folder deletions across sessions,
--- or nil when 'undofile' is off. Named like Vim's own undo files (full path with
--- `%` for `/`) plus a suffix, so it never clashes with the collection file's undo file.
---@return string|nil
local function undo_path()
    if not vim.go.undofile then
        return nil
    end
    local dir = vim.split(vim.go.undodir, ",", { plain = true })[1] or ""
    if dir == "" or dir == "." or dir:sub(1, 2) == "./" then
        -- "." means next to the file, as for Vim's own undo files
        dir = vim.fn.fnamemodify(state.collection_path, ":h") .. dir:sub(2)
    end
    dir = vim.fn.expand(dir):gsub("/+$", "")
    local name = vim.fn.fnamemodify(state.collection_path, ":p"):gsub("/", "%%")
    return dir .. "/" .. name .. ".http-nvim.json"
end

local function load_deleted()
    local path = undo_path()
    if not path or vim.fn.filereadable(path) == 0 then
        return {}
    end
    local ok, deleted = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })
    end)
    if not ok or type(deleted) ~= "table" then
        vim.notify("http-nvim: ignoring unreadable undo file " .. path, vim.log.levels.WARN)
        return {}
    end
    return deleted
end

local function write_deleted()
    local path = undo_path()
    if not path then
        return
    end
    local ok, err = pcall(function()
        local entries = vim.tbl_map(function(deleted)
            return { parent = deleted.parent, index = deleted.index, node = deleted.node }
        end, state.deleted)
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        if vim.fn.writefile({ vim.json.encode(entries) }, path) ~= 0 then
            error("cannot write file")
        end
    end)
    if not ok then
        vim.notify("http-nvim: failed to write undo file " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
end

--- Find the item list a deleted item goes back into by its parent folder names.
---@param parent string[]
---@return PostmanItem[]|nil list, PostmanItem[] folders The folders along the way, outermost first
local function resolve_parent(parent)
    local list = state.items or {}
    local folders = {}
    for _, name in ipairs(parent) do
        local folder
        for _, item in ipairs(list) do
            if item.name == name and not item.request then
                folder = item
                break
            end
        end
        if not folder then
            return nil, folders
        end
        folder.item = folder.item or {}
        table.insert(folders, folder)
        list = folder.item
    end
    return list, folders
end

---@param node { item: PostmanItem[]|nil, request: PostmanRequest|string|nil }
---@return integer
local function count_requests(node)
    if node.request then
        return 1
    end
    local total = 0
    for _, child in ipairs(node.item or {}) do
        total = total + count_requests(child)
    end
    return total
end

--- Find where `node` currently sits in the collection.
---@param node PostmanItem
---@return PostmanItem[]|nil list, integer|nil index, string|nil path Slash-separated, ending with the node's name
local function locate(node)
    local function search(list, prefix)
        for i, item in ipairs(list) do
            local path = prefix .. item.name
            if item == node then
                return list, i, path
            end
            if item.item then
                local found_list, found_index, found_path = search(item.item, path .. "/")
                if found_list then
                    return found_list, found_index, found_path
                end
            end
        end
    end
    return search(state.items, "")
end

--- `name`, or `name copy`, `name copy 2`, ... when `list` already has it.
---@param list PostmanItem[]
---@param name string
---@return string
local function unique_name(list, name)
    local taken = {}
    for _, item in ipairs(list) do
        taken[item.name] = true
    end
    local candidate, n = name, 1
    while taken[candidate] do
        candidate = name .. " copy" .. (n > 1 and " " .. n or "")
        n = n + 1
    end
    return candidate
end

--- Split `a/b/c` into trimmed, non-empty names.
---@param input string|nil
---@return string[]
local function split_path(input)
    local names = {}
    for _, name in ipairs(vim.split(input or "", "/", { plain = true })) do
        name = vim.trim(name)
        if name ~= "" then
            table.insert(names, name)
        end
    end
    return names
end

--- Walk `names` from `list` like `mkdir -p`: folders that already exist along the
--- path are reused, missing ones are created. Every folder on the way is expanded.
---@param list PostmanItem[]
---@param folder PostmanItem|nil The folder holding `list`, if any
---@param names string[]
---@return PostmanItem[] list, PostmanItem|nil folder, boolean created
local function ensure_folders(list, folder, names)
    local created = false
    for _, name in ipairs(names) do
        if folder then
            state.expanded[folder] = true
        end
        local existing
        for _, item in ipairs(list) do
            if item.name == name and not item.request then
                existing = item
                break
            end
        end
        if not existing then
            existing = { name = name, item = {} }
            table.insert(list, existing)
            created = true
        end
        existing.item = existing.item or {}
        folder, list = existing, existing.item
    end
    return list, folder, created
end

return {
    empty = empty,
    load_collection = load_collection,
    write_collection = write_collection,
    load_deleted = load_deleted,
    write_deleted = write_deleted,
    resolve_parent = resolve_parent,
    count_requests = count_requests,
    locate = locate,
    unique_name = unique_name,
    split_path = split_path,
    ensure_folders = ensure_folders,
}
