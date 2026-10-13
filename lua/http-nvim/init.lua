local Layout = require("nui.layout")
local Popup = require("nui.popup")
local Split = require("nui.split")
local jetbrains = require("http-nvim.jetbrains")

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

--- Postman collection format v2.1.
---@class PostmanCollection
---@field info { name: string, schema: string|nil }
---@field item PostmanItem[]

---@class DeletedItem
---@field list PostmanItem[]|nil The list it was removed from; nil when loaded from the undo file
---@field parent string[] Names of the folders that held it, from the top level
---@field index integer
---@field node PostmanItem

---@class State
---@field split NuiSplit|nil
---@field collection PostmanCollection|nil The loaded collection, written back to `collection_path` on save
---@field items PostmanItem[]|nil Top-level items of the loaded collection
---@field env table<string, any> Environment variables loaded from `env_path`
---@field env_file table The whole decoded environment file, written back with new `values` on save
---@field env_buf integer|nil Edit buffer of the environment variables, opened with `e`
---@field line_env table<integer, string> Lines of the environment section: the variable name, or "" for the heading
---@field last_view ResponseView|nil The last request sent, for `<leader>hp` and `<leader>hl`
---@field expanded table<PostmanItem, boolean>
---@field line_nodes table<integer, PostmanItem>
---@field line_paths table<integer, string> Slash-separated item names, e.g. `auth/login`
---@field line_lists table<integer, PostmanItem[]> The list that holds the item on each line
---@field deleted DeletedItem[] Deleted folders and requests, most recent last, for `u`
---@field edit_bufs table<PostmanItem, integer> Edit buffer of each request opened with `e`
---@field clipboard { node: PostmanItem, mode: "cut"|"copy" }|nil Item marked with `x` (cut) or `y` (copy), pasted by `p`
---@field view vim.fn.winsaveview.ret|nil Cursor and scroll of the panel when it was last closed, restored on open
local state = {
    split = nil,
    collection = nil,
    items = nil,
    env = {},
    env_file = {},
    env_buf = nil,
    line_env = {},
    last_view = nil,
    expanded = {},
    line_nodes = {},
    line_paths = {},
    line_lists = {},
    edit_bufs = {},
    clipboard = nil,
    deleted = {},
}

local M = {}

local ns = vim.api.nvim_create_namespace("http-nvim")

-- TODO: let users choose collection files; for now load the test fixture
local collection_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/tests/api.json"
local env_path = vim.fn.fnamemodify(collection_path, ":h") .. "/env.json"

---@param path string
---@return PostmanCollection
local function load_collection(path)
    local ok, collection = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })
    end)
    if not ok or type(collection) ~= "table" then
        vim.notify("http-nvim: failed to load collection " .. path, vim.log.levels.ERROR)
        return { info = { name = vim.fn.fnamemodify(path, ":t:r") }, item = {} }
    end
    collection.item = collection.item or {}
    return collection
end

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
        if vim.fn.writefile(vim.split(json, "\n", { plain = true }), env_path) ~= 0 then
            error("cannot write file")
        end
    end)
    if not ok then
        vim.notify("http-nvim: failed to write environment " .. env_path .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
    return ok
end

--- How a value shows in the panel and the edit buffer: strings as is, anything else as JSON.
---@param value any
---@return string
local function env_text(value)
    return type(value) == "string" and value or vim.json.encode(value)
end

---@param path string
---@return boolean
local function write_collection(path)
    -- Keys come out sorted: the decoded tables do not keep the file's key order
    local ok, err = pcall(function()
        local json = vim.json.encode(state.collection, { indent = "    ", sort_keys = true })
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
        dir = vim.fn.fnamemodify(collection_path, ":h") .. dir:sub(2)
    end
    dir = vim.fn.expand(dir):gsub("/+$", "")
    local name = vim.fn.fnamemodify(collection_path, ":p"):gsub("/", "%%")
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

---@param nodes PostmanItem[]
---@param depth integer
---@param lines string[]
---@param parent_path string
local function render_items(nodes, depth, lines, parent_path)
    for _, node in ipairs(nodes) do
        local path = parent_path .. "/" .. node.name
        local indent = string.rep("  ", depth)
        if node.request then
            -- `request` may be a bare URL string; Postman defaults the method to GET
            local method = type(node.request) == "table" and node.request.method or "GET"
            table.insert(lines, indent .. "  " .. method .. " " .. node.name)
        else
            local marker = "  "
            if node.item and #node.item > 0 then
                marker = state.expanded[node] and "▾ " or "▸ "
            end
            table.insert(lines, indent .. marker .. "(" .. count_requests(node) .. ") " .. node.name)
        end
        state.line_nodes[#lines] = node
        state.line_paths[#lines] = path:sub(2)
        state.line_lists[#lines] = nodes
        if state.expanded[node] then
            render_items(node.item, depth + 1, lines, path)
        end
    end
end

local function render()
    local keys = vim.tbl_keys(state.env)
    table.sort(keys)
    local lines = {
        "Help: g?",
        "",
        "Environment variables (" .. #keys .. ")",
    }
    state.line_env = { [#lines] = "" }
    for _, key in ipairs(keys) do
        table.insert(lines, key .. " = " .. env_text(state.env[key]))
        state.line_env[#lines] = key
    end
    table.insert(lines, "")
    table.insert(lines, "Collection (" .. count_requests({ item = state.items }) .. ")")
    state.line_nodes = {}
    state.line_paths = {}
    state.line_lists = {}
    render_items(state.items, 0, lines, "")

    local bufnr = state.split.bufnr
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    -- Underline the item marked with `x` or `y`
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local clip = state.clipboard
    for line, node in pairs(state.line_nodes) do
        if clip and node == clip.node then
            local text = lines[line]
            vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, #text:match("^%s*"), {
                end_col = #text,
                hl_group = clip.mode == "cut" and "httpNvimCut" or "httpNvimCopy",
            })
            break
        end
    end
end

---@param node PostmanItem
local function move_cursor_to(node)
    for line, line_node in pairs(state.line_nodes) do
        if line_node == node then
            vim.api.nvim_win_set_cursor(state.split.winid, { line, 0 })
            return
        end
    end
end

--- Ask for an item name that is unique within `siblings`.
---@param kind "folder"|"request"
---@param prompt string
---@param default string|nil
---@param siblings PostmanItem[]
---@param on_name fun(name: string)
local function input_item_name(kind, prompt, default, siblings, on_name)
    vim.ui.input({ prompt = prompt, default = default }, function(input)
        local name = input and vim.trim(input) or ""
        if name == "" or name == default then
            return
        end
        -- Item paths (and edit buffer names) are slash-separated names
        if name:find("/", 1, true) then
            vim.notify("http-nvim: " .. kind .. " name cannot contain '/'", vim.log.levels.ERROR)
            return
        end
        for _, sibling in ipairs(siblings) do
            if sibling.name == name then
                vim.notify("http-nvim: '" .. name .. "' already exists here", vim.log.levels.ERROR)
                return
            end
        end
        on_name(name)
    end)
end

--- Keep open edit buffers in step with a renamed item: buffer names carry the item
--- path, and a request's own buffer carries its name on the `### name` line.
---@param item PostmanItem
---@param path string The item's new slash-separated path
---@param renamed boolean Whether `item` itself is the renamed item
local function rename_edit_bufs(item, path, renamed)
    local bufnr = state.edit_bufs[item]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_set_name, bufnr, "http-nvim://" .. path .. " (edit)")
        if renamed and vim.api.nvim_buf_is_loaded(bufnr) then
            local modified = vim.bo[bufnr].modified
            for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
                if line:match("^###") then
                    vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { "### " .. item.name })
                    break
                end
            end
            vim.bo[bufnr].modified = modified
        end
    end
    for _, child in ipairs(item.item or {}) do
        rename_edit_bufs(child, path .. "/" .. child.name, false)
    end
end

local function rename_item()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local node = state.line_nodes[line]
    if not node then
        return
    end
    local kind = node.request and "request" or "folder"
    input_item_name(kind, "Rename " .. kind .. ": ", node.name, state.line_lists[line], function(name)
        node.name = name
        rename_edit_bufs(node, (state.line_paths[line]:match("^(.*/)") or "") .. name, true)
        write_collection(collection_path)
        render()
        move_cursor_to(node)
    end)
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

---@param mode "cut"|"copy"
local function clip_item(mode)
    local node = state.line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if not node then
        return
    end
    state.clipboard = { node = node, mode = mode }
    render()
    vim.notify("http-nvim: " .. node.name .. " added to clipboard")
end

local function cancel_clipboard()
    if not state.clipboard then
        return
    end
    state.clipboard = nil
    render()
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

--- Paste the item from `x` (move it) or `y` (copy it) into the folder under the
--- cursor, or to the top level on any other line.
local function paste_item()
    local clip = state.clipboard
    if not clip then
        vim.notify("http-nvim: Clipboard empty! nothing to paste")
        return
    end
    local node = clip.node

    local target = state.line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if target and target.request then
        target = nil
    end
    local to = state.items
    local target_path = ""
    if target then
        local _, _, path = locate(target)
        target.item = target.item or {}
        to, target_path = target.item, path .. "/"
    end

    if clip.mode == "copy" then
        -- The clipboard is kept so the same item can be pasted again
        local copy = vim.deepcopy(node)
        copy.name = unique_name(to, copy.name)
        table.insert(to, copy)
        if target then
            state.expanded[target] = true
        end
        write_collection(collection_path)
        render()
        move_cursor_to(copy)
        return
    end

    local from, index = locate(node)
    if not from or not index then
        state.clipboard = nil
        render()
        vim.notify("http-nvim: '" .. node.name .. "' no longer exists", vim.log.levels.ERROR)
        return
    end
    if to == from then
        state.clipboard = nil
        render()
        return
    end
    -- A folder cannot go inside itself or one of its own folders
    local _, _, node_path = locate(node)
    if not node.request and target_path:sub(1, #node_path + 1) == node_path .. "/" then
        vim.notify("http-nvim: cannot move '" .. node.name .. "' into itself", vim.log.levels.ERROR)
        return
    end
    for _, sibling in ipairs(to) do
        if sibling.name == node.name then
            vim.notify("http-nvim: '" .. node.name .. "' already exists there", vim.log.levels.ERROR)
            return
        end
    end

    table.remove(from, index)
    table.insert(to, node)
    state.clipboard = nil
    if target then
        state.expanded[target] = true
    end
    rename_edit_bufs(node, target_path .. node.name, false)
    write_collection(collection_path)
    render()
    move_cursor_to(node)
end

--- Move the item under the cursor among its siblings: `delta` -1 is up, 1 is down,
--- repeated [count] times and stopping at either end.
---@param delta integer
local function move_sibling(delta)
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local node = state.line_nodes[line]
    if not node then
        return
    end
    local list = state.line_lists[line]
    local from
    for i, item in ipairs(list) do
        if item == node then
            from = i
            break
        end
    end
    local to = math.max(1, math.min(#list, from + delta * vim.v.count1))
    if to == from then
        return
    end
    table.insert(list, to, table.remove(list, from))
    write_collection(collection_path)
    render()
    move_cursor_to(node)
end

--- Where a new item goes: inside the folder under the cursor, next to the request
--- under the cursor, or at the top level elsewhere.
---@return PostmanItem[] list, PostmanItem|nil folder The folder to expand, if any
local function new_item_target()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local node = state.line_nodes[line]
    if node and not node.request then
        node.item = node.item or {}
        return node.item, node
    elseif node then
        return state.line_lists[line], nil
    end
    return state.items, nil
end

---@param item PostmanItem
---@param list PostmanItem[]
---@param folder PostmanItem|nil
local function add_item(item, list, folder)
    table.insert(list, item)
    if folder then
        state.expanded[folder] = true
    end
    write_collection(collection_path)
    render()
    vim.api.nvim_set_current_win(state.split.winid)
    move_cursor_to(item)
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

--- Edit buffers still open for `node` or any request inside it.
---@param node PostmanItem
---@return integer[]
local function edit_bufs_under(node)
    local bufs = {}
    local function collect(item)
        local bufnr = state.edit_bufs[item]
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            table.insert(bufs, bufnr)
        end
        for _, child in ipairs(item.item or {}) do
            collect(child)
        end
    end
    collect(node)
    return bufs
end

local function delete_item()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local node = state.line_nodes[line]
    if not node then
        return
    end
    local message = node.request and "Delete request '" .. node.name .. "'?"
        or "Delete folder '" .. node.name .. "' and its " .. count_requests(node) .. " request(s)?"
    local bufs = edit_bufs_under(node)
    for _, bufnr in ipairs(bufs) do
        if vim.bo[bufnr].modified then
            message = message .. "\nUnsaved changes in its edit buffer will be lost."
            break
        end
    end
    if vim.fn.confirm(message, "&Yes\n&No", 2) ~= 1 then
        return
    end
    -- Writing them would no longer reach the collection, so close them
    for _, bufnr in ipairs(bufs) do
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    local siblings = state.line_lists[line]
    for i, sibling in ipairs(siblings) do
        if sibling == node then
            table.remove(siblings, i)
            local parent = vim.split(state.line_paths[line], "/", { plain = true })
            table.remove(parent)
            table.insert(state.deleted, { list = siblings, parent = parent, index = i, node = node })
            break
        end
    end
    state.expanded[node] = nil
    write_collection(collection_path)
    write_deleted()
    render()
    vim.api.nvim_win_set_cursor(state.split.winid, { math.min(line, vim.api.nvim_buf_line_count(state.split.bufnr)), 0 })
end

local function undo_delete()
    local deleted = table.remove(state.deleted)
    if not deleted then
        vim.notify("http-nvim: nothing to undo")
        return
    end
    local list, folders = resolve_parent(deleted.parent)
    list = deleted.list or list
    if not list then
        -- The parent folder was renamed or deleted since: fall back to the top level
        list = state.items
        vim.notify("http-nvim: folder '" .. table.concat(deleted.parent, "/") .. "' not found, restored '"
            .. deleted.node.name .. "' at the top level", vim.log.levels.WARN)
    end
    -- Later edits may have shortened the list; clamp to keep it a sequence
    table.insert(list, math.min(deleted.index, #list + 1), deleted.node)
    -- Expand the folders that hold it so the cursor can land on it
    for _, folder in ipairs(folders) do
        state.expanded[folder] = true
    end
    write_collection(collection_path)
    write_deleted()
    render()
    move_cursor_to(deleted.node)
end

local function toggle()
    local node = state.line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if not node or not node.item or #node.item == 0 then
        return
    end
    state.expanded[node] = not state.expanded[node] or nil
    render()
end

--- Split above the panel for an edit buffer; closing it returns to the panel.
local function open_edit_window()
    vim.cmd("aboveleft split")

    local edit_win = vim.api.nvim_get_current_win()
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(edit_win),
        once = true,
        callback = function()
            -- Only move focus if the user was in the edit window, not when it is closed from elsewhere
            if vim.api.nvim_get_current_win() ~= edit_win then
                return
            end
            vim.schedule(function()
                local panel_win = state.split and state.split.winid
                if panel_win and vim.api.nvim_win_is_valid(panel_win) then
                    vim.api.nvim_set_current_win(panel_win)
                end
            end)
        end,
    })
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

--- Edit the environment variables as `KEY=value` lines, like a `.env` file.
local function edit_env()
    local key = state.line_env[vim.api.nvim_win_get_cursor(0)[1]]
    open_edit_window()

    local bufnr = state.env_buf
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        local keys = vim.tbl_keys(state.env)
        table.sort(keys)
        local lines = vim.tbl_map(function(k)
            return k .. "=" .. env_text(state.env[k])
        end, keys)

        bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(bufnr, "http-nvim-env://" .. vim.fn.fnamemodify(env_path, ":t") .. " (edit)")
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].buftype = "acwrite"
        vim.bo[bufnr].swapfile = false
        vim.bo[bufnr].modified = false
        vim.bo[bufnr].filetype = vim.filetype.match({ filename = ".env" }) or "sh"
        state.env_buf = bufnr

        vim.api.nvim_create_autocmd("BufWriteCmd", {
            buffer = bufnr,
            callback = function()
                local values, err = parse_env_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
                if not values then
                    vim.notify("http-nvim: " .. err, vim.log.levels.ERROR)
                    return
                end
                local previous = state.env
                state.env = values
                -- On failure the buffer stays modified so the edit is not silently lost
                if not write_env() then
                    state.env = previous
                    return
                end
                vim.bo[bufnr].modified = false
                if state.split and state.split.bufnr and vim.api.nvim_buf_is_valid(state.split.bufnr) then
                    render()
                end
            end,
        })
    end
    vim.api.nvim_set_current_buf(bufnr)

    -- Land on the variable that was under the cursor in the panel
    if key and key ~= "" then
        for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
            if vim.trim(line):match("^([^=%s]+)") == key then
                vim.api.nvim_win_set_cursor(0, { i, 0 })
                break
            end
        end
    end
end

local edit
---@type fun(request: PostmanRequest|string)
local send_request

--- Add a GET request with an empty URL and open it with `e` to fill it in.
--- `a/b/name` creates the request inside folders `a/b`; a trailing `/` (`a/b/`)
--- creates only the folders.
local function create_item()
    local list, folder = new_item_target()
    vim.ui.input({ prompt = "Add new request or folder: " }, function(input)
        local names = split_path(input)
        if vim.trim(input or ""):sub(-1) == "/" then
            if #names == 0 then
                return
            end
            local _, last, created = ensure_folders(list, folder, names)
            if created then
                write_collection(collection_path)
            end
            render()
            vim.api.nvim_set_current_win(state.split.winid)
            if last then
                move_cursor_to(last)
            end
            return
        end
        local name = table.remove(names)
        if not name then
            return
        end
        -- A clash is only possible when every folder already existed, so nothing is left behind
        local target, parent = ensure_folders(list, folder, names)
        for _, sibling in ipairs(target) do
            if sibling.name == name then
                vim.notify("http-nvim: '" .. name .. "' already exists here", vim.log.levels.ERROR)
                return
            end
        end
        add_item({ name = name, request = { method = "GET", url = { raw = "" } } }, target, parent)
        edit()
    end)
end

edit = function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    if state.line_env[line] then
        edit_env()
        return
    end
    local node = state.line_nodes[line]
    if not node or not node.request then
        return
    end

    open_edit_window()

    local name = "http-nvim://" .. state.line_paths[line] .. " (edit)"
    local bufnr = state.edit_bufs[node]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        if vim.api.nvim_buf_is_loaded(bufnr) then
            vim.api.nvim_set_current_buf(bufnr)
            return
        end
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end

    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, jetbrains.to_lines(node.name, node.request))
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modified = false
    vim.bo[bufnr].filetype = "http"
    vim.api.nvim_set_current_buf(bufnr)
    state.edit_bufs[node] = bufnr

    -- Send what the buffer holds now, saved or not
    vim.keymap.set("n", "<leader>hr", function()
        local request, err = jetbrains.from_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), node.request)
        if not request then
            vim.notify("http-nvim: " .. err, vim.log.levels.ERROR)
            return
        end
        send_request(request)
    end, { buffer = bufnr })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local request, err, section = jetbrains.from_lines(lines, node.request)
            if not request or not section then
                vim.notify("http-nvim: " .. err, vim.log.levels.ERROR)
                return
            end
            if section.start_row > 0 or section.end_row < #lines then
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
                    vim.list_slice(lines, section.start_row + 1, section.end_row))
                vim.notify("http-nvim: only the first section '### " ..
                    section.name .. "' keep, other sections were removed in edit buf")
            end
            if section.name ~= node.name then
                node.name = section.name
                -- Read the path from the buffer name: `r` may have renamed a parent folder since
                local path = vim.api.nvim_buf_get_name(bufnr):match("^http%-nvim://(.*) %(edit%)$") or ""
                path = (path:match("^(.*/)") or "") .. section.name
                pcall(vim.api.nvim_buf_set_name, bufnr, "http-nvim://" .. path .. " (edit)")
            end
            node.request = request
            -- On failure the buffer stays modified so the edit is not silently lost
            if write_collection(collection_path) then
                vim.bo[bufnr].modified = false
            end
            if state.split and state.split.bufnr and vim.api.nvim_buf_is_valid(state.split.bufnr) then
                render()
            end
        end,
    })
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

--- curl arguments for a request, with `{{key}}` replaced from the environment.
--- Only a raw body is sent; other body modes are skipped.
---@param request PostmanRequest|string
---@return string[] args, string method, string url
local function curl_args(request)
    local method = type(request) == "table" and request.method or "GET"
    -- Postman URLs may hold spaces and `[]` (e.g. `?q=["a", "b"]`): encode the spaces, and
    -- `--globoff` stops curl reading `[...]` as a range
    local url = expand_env(jetbrains.url_of(request)):gsub(" ", "%%20")
    -- The status code goes on a last line of its own, after the body
    local args = {
        "curl", "--silent", "--show-error", "--verbose", "--globoff",
        "--request", method, "--write-out", "\n%{http_code}",
    }
    if type(request) == "table" then
        for _, header in ipairs(request.header or {}) do
            if not header.disabled then
                table.insert(args, "--header")
                table.insert(args, expand_env(header.key) .. ": " .. expand_env(header.value or ""))
            end
        end
        local body = request.body
        if body and body.mode == "raw" and body.raw and body.raw ~= "" then
            table.insert(args, "--data-binary")
            table.insert(args, expand_env(body.raw))
        end
    end
    table.insert(args, "--")
    table.insert(args, url)
    return args, method, url
end

--- Split curl's `--verbose` stderr into the request and response headers (`> ` and
--- `< ` lines, a blank line between them) and the other lines, e.g. its error message.
--- Connection details (`* ` lines) and curl's `Note:` hints are dropped.
---@param stderr string
---@return string[] headers, string[] others
local function split_verbose(stderr)
    local headers, others = {}, {}
    local last
    for _, line in ipairs(vim.split(stderr, "\n", { plain = true })) do
        line = line:gsub("\r$", "")
        local prefix = line:sub(1, 2)
        if line == "> " or line == "< " then
            -- Blank line ending the headers
        elseif prefix == "> " or prefix == "< " then
            if last and last ~= prefix then
                table.insert(headers, "")
            end
            last = prefix
            table.insert(headers, line)
        elseif line:sub(1, 1) ~= "*" and line:sub(1, 5) ~= "Note:" and line ~= "" then
            table.insert(others, line)
        end
    end
    return headers, others
end

--- Does nothing once the box is closed: nui clears `bufnr` on unmount.
---@param bufnr integer|nil
---@param lines string[]
local function set_readonly_lines(bufnr, lines)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
end

---@class ResponseBoxes
---@field header NuiPopup Method, URL and status
---@field content NuiPopup The response body, or curl's error
---@field sidebar_right NuiPopup Request and response headers

--- What a sent request shows, kept so `<leader>hp` can show it again.
---@class ResponseView
---@field request PostmanRequest|string The request as sent, before `{{key}}` replacement
---@field request_line string
---@field status string
---@field content string[]
---@field content_filetype string
---@field sidebar_right string[]
---@field boxes ResponseBoxes[] Open layouts showing this view, filled in when the response arrives

--- Floating layout: a header box on top, the content box below on the left with
--- a sidebar on its right. `q` in any box closes it.
---@return ResponseBoxes
local function open_response_layout()
    local buf_options = { modifiable = false, readonly = true }
    -- Padding left and right only: 2 rows above and below would hide the short header box
    local border = { style = "rounded", padding = { 0, 1 } }
    local header = Popup({
        border = border,
        buf_options = buf_options
    })
    local content = Popup({ border = border, enter = true, buf_options = buf_options })
    -- Header lines are long for a narrow box: wrap them
    local sidebar_right = Popup({ border = border, buf_options = buf_options, win_options = { wrap = true } })

    local layout = Layout(
        {
            relative = "editor",
            position = "50%",
            size = { width = "80%", height = "80%" },
        },
        Layout.Box({
            Layout.Box(header, { size = "10%" }),
            Layout.Box({
                Layout.Box(content, { size = "70%" }),
                Layout.Box(sidebar_right, { size = "30%" }),
            }, { dir = "row", size = "90%" }),
        }, { dir = "col" })
    )

    layout:mount()

    for _, popup in ipairs({ header, content, sidebar_right }) do
        vim.keymap.set("n", "q", function()
            layout:unmount()
        end, { buffer = popup.bufnr })
    end

    return { header = header, content = content, sidebar_right = sidebar_right }
end

---@param view ResponseView
local function show_view(view)
    for _, boxes in ipairs(view.boxes) do
        set_readonly_lines(boxes.header.bufnr, { view.request_line, view.status })
        set_readonly_lines(boxes.content.bufnr, view.content)
        set_readonly_lines(boxes.sidebar_right.bufnr, view.sidebar_right)
        local bufnr = boxes.content.bufnr
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.bo[bufnr].filetype = view.content_filetype
        end
    end
end

--- Send a request with curl and show it in a floating layout:
--- method, URL and status on top, the response below.
send_request = function(request)
    local args, method, url = curl_args(request)
    ---@type ResponseView
    local view = {
        request = request,
        request_line = method .. " " .. url,
        status = "Sending...",
        content = {},
        content_filetype = "",
        sidebar_right = {},
        boxes = { open_response_layout() },
    }
    state.last_view = view
    show_view(view)

    local started = vim.uv.hrtime()
    vim.system(args, { text = true }, vim.schedule_wrap(function(result)
        local elapsed = string.format("%d ms", (vim.uv.hrtime() - started) / 1e6)
        local headers, others = split_verbose(result.stderr or "")
        view.sidebar_right = headers
        if result.code ~= 0 then
            view.status = "curl failed (exit " .. result.code .. ") " .. elapsed
            view.content = others
            show_view(view)
            return
        end
        local output = result.stdout or ""
        local response, status = output:match("^(.*)\n(%d+)$")
        response = response or output
        view.status = "HTTP " .. (status or "?") .. " " .. elapsed

        local ok, decoded = pcall(vim.json.decode, response)
        if ok and type(decoded) == "table" then
            response = vim.json.encode(decoded, { indent = "  ", sort_keys = true })
            view.content_filetype = "json"
        end
        view.content = vim.split((response:gsub("\r\n", "\n")), "\n", { plain = true })
        show_view(view)
    end))
end

--- Send the request under the cursor in the panel.
local function make_request()
    local node = state.line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if node and node.request then
        send_request(node.request)
    end
end

M.open = function()
    if not state.collection then
        state.collection = load_collection(collection_path)
        state.items = state.collection.item
        state.deleted = load_deleted()
        state.env, state.env_file = load_env(env_path)
    end

    state.split = Split({
        enter = true,
        relative = "editor",
        size = "40%",
        buf_options = {
            modifiable = false,
            readonly = false
        }
    })

    render()

    vim.bo[state.split.bufnr].filetype = "http-nvim"

    state.split:mount()

    local winid = state.split.winid
    if state.view then
        -- Clamp in case the panel has fewer lines now
        local view = vim.deepcopy(state.view)

        if view then
            view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(state.split.bufnr))
            vim.api.nvim_win_call(winid, function()
                vim.fn.winrestview(view)
            end)
        end
    end
    -- Saved on leaving: by WinClosed the window is already invalid
    vim.api.nvim_create_autocmd("WinLeave", {
        group = vim.api.nvim_create_augroup("http-nvim-panel-view", { clear = true }),
        buffer = state.split.bufnr,
        callback = function()
            if vim.api.nvim_get_current_win() == winid then
                state.view = vim.fn.winsaveview()
            end
        end,
    })

    vim.keymap.set("n", "g?", function()
        vim.cmd("help http-nvim")
    end)
    vim.keymap.set("n", "<CR>", toggle, { buffer = state.split.bufnr })
    vim.keymap.set("n", "=", toggle, { buffer = state.split.bufnr })
    vim.keymap.set("n", "a", create_item, { buffer = state.split.bufnr })
    vim.keymap.set("n", "x", function() clip_item("cut") end, { buffer = state.split.bufnr })
    vim.keymap.set("n", "y", function() clip_item("copy") end, { buffer = state.split.bufnr })
    vim.keymap.set("n", "p", paste_item, { buffer = state.split.bufnr })
    vim.keymap.set("n", "<Esc>", cancel_clipboard, { buffer = state.split.bufnr })
    vim.keymap.set("n", "]m", function() move_sibling(1) end, { buffer = state.split.bufnr })
    vim.keymap.set("n", "[m", function() move_sibling(-1) end, { buffer = state.split.bufnr })
    vim.keymap.set("n", "e", edit, { buffer = state.split.bufnr })
    vim.keymap.set("n", "<leader>hr", make_request, { buffer = state.split.bufnr })
    vim.keymap.set("n", "r", rename_item, { buffer = state.split.bufnr })
    vim.keymap.set("n", "D", delete_item, { buffer = state.split.bufnr })
    vim.keymap.set("n", "u", undo_delete, { buffer = state.split.bufnr })
end

--- Show the last request and its response again, without sending it.
M.preview_last = function()
    local view = state.last_view
    if not view then
        vim.notify("http-nvim: no request sent yet")
        return
    end
    -- Layouts closed since are dropped; the new one also gets the response if it is still on its way
    view.boxes = vim.tbl_filter(function(boxes)
        local bufnr = boxes.content.bufnr
        return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
    end, view.boxes)
    table.insert(view.boxes, open_response_layout())
    show_view(view)
end

--- Send the last request again, with the current environment values.
M.run_last = function()
    if not state.last_view then
        vim.notify("http-nvim: no request sent yet")
        return
    end
    send_request(state.last_view.request)
end

M.setup = function(opts)

end

return M
