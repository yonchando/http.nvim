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

---@alias Node PostmanCollection|PostmanItem

---@class DeletedItem
---@field list PostmanItem[]|nil The list it was removed from; nil when loaded from the undo file
---@field parent string[] Names of the folders that held it, from the top level
---@field index integer
---@field node PostmanItem

---@class State
---@field split NuiSplit|nil
---@field collection PostmanCollection|nil The loaded collection, written back to `collection_path` on save
---@field items PostmanItem[]|nil Top-level items of the loaded collection
---@field expanded table<Node, boolean>
---@field line_nodes table<integer, Node>
---@field line_paths table<integer, string> Slash-separated item names, e.g. `auth/login`
---@field line_lists table<integer, PostmanItem[]> The list that holds the item on each line
---@field deleted DeletedItem[] Deleted folders and requests, most recent last, for `u`
---@field edit_bufs table<PostmanItem, integer> Edit buffer of each request opened with `e`
---@field clipboard { node: PostmanItem, mode: "cut"|"copy" }|nil Item marked with `x` (cut) or `y` (copy), pasted by `p`
local state = {
    split = nil,
    collection = nil,
    items = nil,
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
    local list = state.items
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

---@param node Node
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

---@param nodes Node[]
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
            local name = node.info and node.info.name or node.name
            table.insert(lines, indent .. marker .. "(" .. count_requests(node) .. ") " .. name)
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
    local lines = {
        "Help: g?",
        "",
        "Environment variables (0)",
        "",
        "Collection (" .. #state.items .. ")",
    }
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

---@param node Node
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

local edit

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
            move_cursor_to(last)
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
    local node = state.line_nodes[line]
    if not node or not node.request then
        return
    end

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

M.open = function()
    if not state.collection then
        state.collection = load_collection(collection_path)
        state.items = state.collection.item
        state.deleted = load_deleted()
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
    vim.keymap.set("n", "e", edit, { buffer = state.split.bufnr })
    vim.keymap.set("n", "r", rename_item, { buffer = state.split.bufnr })
    vim.keymap.set("n", "D", delete_item, { buffer = state.split.bufnr })
    vim.keymap.set("n", "u", undo_delete, { buffer = state.split.bufnr })
end

M.setup = function(opts)

end

return M
