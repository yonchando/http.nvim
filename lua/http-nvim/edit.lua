--- Edit buffers opened with `e`: a request in JetBrains HTTP format, or the
--- environment variables as `KEY=value` lines.
local collection = require("http-nvim.collection")
local env = require("http-nvim.env")
local jetbrains = require("http-nvim.jetbrains")
local keymaps = require("http-nvim.keymaps")
local request = require("http-nvim.request")
local state = require("http-nvim.state")

local write_collection = collection.write_collection
local env_line = env.env_line
local parse_env_lines = env.parse_env_lines
local write_env = env.write_env
local send_request = request.send_request

--- The panel requires this module, so it is only required here once needed.
local function render()
    require("http-nvim.panel").render()
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

--- Edit the environment variables as `KEY=value` lines, like a `.env` file.
local function edit_env()
    local key = state.line_env[vim.api.nvim_win_get_cursor(0)[1]]
    open_edit_window()

    local bufnr = state.env_buf
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        local lines = vim.tbl_map(function(var)
            return env_line(var, "=")
        end, state.env)

        bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(bufnr, "http-nvim-env://" .. vim.fn.fnamemodify(state.env_path, ":t") .. " (edit)")
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
            if vim.trim(line):gsub("^#%s*", ""):match("^([^=%s]+)") == key then
                vim.api.nvim_win_set_cursor(0, { i, 0 })
                break
            end
        end
    end
end

local function edit()
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
    keymaps.map("send", function()
        local request, err = jetbrains.from_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), node.request)
        if not request then
            vim.notify("http-nvim: " .. err, vim.log.levels.ERROR)
            return
        end
        send_request(request)
    end, bufnr)

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
            if write_collection(state.collection_path) then
                vim.bo[bufnr].modified = false
            end
            if state.split and state.split.bufnr and vim.api.nvim_buf_is_valid(state.split.bufnr) then
                render()
            end
        end,
    })
end

--- Close every edit buffer, e.g. before switching to another collection. Closes
--- nothing when one has unsaved changes.
---@return boolean closed, string|nil modified Name of a buffer with unsaved changes
local function close_edit_bufs()
    local bufs = vim.tbl_values(state.edit_bufs)
    table.insert(bufs, state.env_buf)
    bufs = vim.tbl_filter(vim.api.nvim_buf_is_valid, bufs)
    for _, bufnr in ipairs(bufs) do
        if vim.bo[bufnr].modified then
            return false, vim.api.nvim_buf_get_name(bufnr)
        end
    end
    for _, bufnr in ipairs(bufs) do
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    state.edit_bufs = {}
    state.env_buf = nil
    return true, nil
end

return {
    close_edit_bufs = close_edit_bufs,
    edit = edit,
    edit_bufs_under = edit_bufs_under,
    rename_edit_bufs = rename_edit_bufs,
}
