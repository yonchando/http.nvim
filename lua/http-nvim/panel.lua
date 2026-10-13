--- The collection panel: rendering it and its keymaps.
local Split = require("nui.split")
local collection = require("http-nvim.collection")
local collections = require("http-nvim.collections")
local config = require("http-nvim.config")
local edit_mod = require("http-nvim.edit")
local env = require("http-nvim.env")
local keymaps = require("http-nvim.keymaps")
local request = require("http-nvim.request")
local state = require("http-nvim.state")

local ns = config.ns
local load_collection = collection.load_collection
local write_collection = collection.write_collection
local load_deleted = collection.load_deleted
local write_deleted = collection.write_deleted
local resolve_parent = collection.resolve_parent
local count_requests = collection.count_requests
local locate = collection.locate
local unique_name = collection.unique_name
local split_path = collection.split_path
local ensure_folders = collection.ensure_folders
local edit = edit_mod.edit
local edit_bufs_under = edit_mod.edit_bufs_under
local rename_edit_bufs = edit_mod.rename_edit_bufs
local load_env = env.load_env
local env_line = env.env_line
local send_request = request.send_request

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
    local lines = {
        "Help: g?",
        "",
        "Environment variables (" .. #state.env .. ")",
    }
    state.line_env = { [#lines] = "" }
    for _, var in ipairs(state.env) do
        table.insert(lines, env_line(var, " = "))
        state.line_env[#lines] = var.key
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
        write_collection(state.collection_path)
        render()
        move_cursor_to(node)
    end)
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
        write_collection(state.collection_path)
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
    write_collection(state.collection_path)
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
    write_collection(state.collection_path)
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
    write_collection(state.collection_path)
    render()
    vim.api.nvim_set_current_win(state.split.winid)
    move_cursor_to(item)
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
    write_collection(state.collection_path)
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
    write_collection(state.collection_path)
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
                write_collection(state.collection_path)
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

--- Send the request under the cursor in the panel.
local function make_request()
    local node = state.line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if node and node.request then
        send_request(node.request)
    end
end

local function open()
    if not state.selected then
        collections.pick(open)
        return
    end
    if not state.collection then
        state.collection = load_collection(state.collection_path)
        state.items = state.collection.item
        state.deleted = load_deleted()
        state.env, state.env_file = load_env(state.env_path)
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

    local bufnr = state.split.bufnr
    keymaps.map("help", function() vim.cmd("help http-nvim") end, bufnr)
    keymaps.map("toggle", toggle, bufnr)
    keymaps.map("add", create_item, bufnr)
    keymaps.map("cut", function() clip_item("cut") end, bufnr)
    keymaps.map("copy", function() clip_item("copy") end, bufnr)
    keymaps.map("paste", paste_item, bufnr)
    keymaps.map("cancel_clipboard", cancel_clipboard, bufnr)
    keymaps.map("move_down", function() move_sibling(1) end, bufnr)
    keymaps.map("move_up", function() move_sibling(-1) end, bufnr)
    keymaps.map("edit", edit, bufnr)
    keymaps.map("send", make_request, bufnr)
    keymaps.map("rename", rename_item, bufnr)
    keymaps.map("delete", delete_item, bufnr)
    keymaps.map("undo", undo_delete, bufnr)
end

return {
    open = open,
    render = render,
}
