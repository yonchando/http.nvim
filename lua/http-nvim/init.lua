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

---@class State
---@field split NuiSplit|nil
---@field collection PostmanCollection|nil The loaded collection, written back to `collection_path` on save
---@field items PostmanItem[]|nil Top-level items of the loaded collection
---@field expanded table<Node, boolean>
---@field line_nodes table<integer, Node>
---@field line_paths table<integer, string> Slash-separated item names, e.g. `auth/login`
---@field edit_bufs table<PostmanItem, integer> Edit buffer of each request opened with `e`
local state = {
    split = nil,
    collection = nil,
    items = nil,
    expanded = {},
    line_nodes = {},
    line_paths = {},
    edit_bufs = {},
}

local M = {}

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
    render_items(state.items, 0, lines, "")

    local bufnr = state.split.bufnr
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
end

local function toggle()
    local node = state.line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if not node or not node.item or #node.item == 0 then
        return
    end
    state.expanded[node] = not state.expanded[node] or nil
    render()
end

local function edit()
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
    vim.keymap.set("n", "e", edit, { buffer = state.split.bufnr })
end

M.setup = function(opts)

end

return M
