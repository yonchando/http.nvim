--- Edit buffers opened with `e`: a request in JetBrains HTTP format, the
--- environment variables as `KEY=value` lines, or the scripts of the collection
--- or a folder (`S`) as `< {% %}` and `> {% %}` blocks.
local collection = require("http-nvim.collection")
local env = require("http-nvim.env")
local jetbrains = require("http-nvim.jetbrains")
local keymaps = require("http-nvim.keymaps")
local lsp = require("http-nvim.lsp")
local request = require("http-nvim.request")
local state = require("http-nvim.state")

local write_collection = collection.write_collection
local env_line = env.env_line
local parse_env_lines = env.parse_env_lines
local write_env = env.write_env
local send_request = request.send_request
local scripts_for = request.scripts_for

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
    local scripts_buf = state.script_bufs[item]
    if scripts_buf and vim.api.nvim_buf_is_valid(scripts_buf) then
        pcall(vim.api.nvim_buf_set_name, scripts_buf, "http-nvim-scripts://" .. path)
    end
    local bufnr = state.edit_bufs[item]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_set_name, bufnr, "http-nvim://" .. path)
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

--- Edit buffers still open for `node` or any item inside it: requests and folder scripts.
---@param node PostmanItem
---@return integer[]
local function edit_bufs_under(node)
    local bufs = {}
    local function collect(item)
        for _, bufnr in pairs({ state.edit_bufs[item], state.script_bufs[item] }) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                table.insert(bufs, bufnr)
            end
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

--- Fire `BufWritePre` or `BufWritePost` for an edit buffer. Its `BufWriteCmd`
--- replaces Vim's own write, which then skips both, so without this
--- format-on-save (e.g. conform.nvim) and other write hooks would not run.
---@param bufnr integer
---@param event "BufWritePre"|"BufWritePost"
local function fire_write(bufnr, event)
    vim.api.nvim_exec_autocmds(event, { buffer = bufnr, modeline = false })
end

--- A new listed `acwrite` buffer named `name`. A leftover buffer of that name
--- that isn't a tracked edit buffer is wiped first. Returns nil, after a message,
--- when the name is taken: setting it would fail and leave a nameless buffer
--- behind, which `:wa` and `:bd` then trip over.
---@param name string
---@param filetype string
---@return integer|nil
local function create_edit_buf(name, filetype)
    local tracked = {}
    for _, bufnr in pairs(state.edit_bufs) do
        tracked[bufnr] = true
    end
    for _, bufnr in pairs(state.script_bufs) do
        tracked[bufnr] = true
    end
    if state.env_buf then
        tracked[state.env_buf] = true
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(bufnr) == name then
            if tracked[bufnr] then
                vim.notify("http-nvim: '" .. name .. "' is already open for another item with the same name",
                    vim.log.levels.ERROR)
                return nil
            elseif vim.bo[bufnr].modified then
                vim.notify("http-nvim: buffer '" .. name .. "' has unsaved changes", vim.log.levels.ERROR)
                return nil
            end
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end

    local bufnr = vim.api.nvim_create_buf(true, false)
    local ok, err = pcall(vim.api.nvim_buf_set_name, bufnr, name)
    if not ok then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        vim.notify("http-nvim: " .. tostring(err), vim.log.levels.ERROR)
        return nil
    end
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = filetype
    return bufnr
end

--- Edit the environment variables as `KEY=value` lines, like a `.env` file.
local function edit_env()
    local key = state.line_env[vim.api.nvim_win_get_cursor(0)[1]]

    local bufnr = state.env_buf
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        state.env_buf = nil
        local lines = vim.tbl_map(function(var)
            return env_line(var, "=")
        end, state.env)

        bufnr = create_edit_buf("http-nvim-env://" .. vim.fn.fnamemodify(state.env_path, ":t"),
            vim.filetype.match({ filename = ".env" }) or "sh")
        if not bufnr then
            return
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modified = false
        state.env_buf = bufnr

        vim.api.nvim_create_autocmd("BufWriteCmd", {
            buffer = bufnr,
            callback = function()
                fire_write(bufnr, "BufWritePre")
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
                fire_write(bufnr, "BufWritePost")
                if state.split and state.split.bufnr and vim.api.nvim_buf_is_valid(state.split.bufnr) then
                    render()
                end
            end,
        })
    end
    open_edit_window()
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

local scripts_ns = vim.api.nvim_create_namespace("http-nvim-scripts")
vim.api.nvim_set_hl(0, "httpNvimScriptsMarker", { link = "PreProc", default = true })
vim.api.nvim_set_hl(0, "httpNvimScriptsComment", { link = "Comment", default = true })

--- Where the code of each `< {% %}` / `> {% %}` block is (one tree-sitter
--- region each), and the markers and `#` comment lines around them.
---@param lines string[]
---@return Range4[][] regions, Range4[] markers, Range4[] comments 0-based, end-exclusive columns
local function script_regions(lines)
    local regions, markers, comments = {}, {}, {}
    local i = 1
    while i <= #lines do
        local line = lines[i]
        local _, open_end = line:find("^%s*[<>]%s*{%%")
        if open_end then
            table.insert(markers, { i - 1, 0, i - 1, open_end })
            local close = line:find("%}", open_end + 1, true)
            if close then
                table.insert(regions, { { i - 1, open_end, i - 1, close - 1 } })
                table.insert(markers, { i - 1, close - 1, i - 1, close + 1 })
            else
                local start = i
                i = i + 1
                while i <= #lines and not lines[i]:find("%}", 1, true) do
                    i = i + 1
                end
                if i <= #lines then
                    close = lines[i]:find("%}", 1, true)
                    table.insert(regions, { { start, 0, i - 1, close - 1 } })
                    table.insert(markers, { i - 1, close - 1, i - 1, close + 1 })
                else
                    -- Not closed yet: up to the end of the buffer
                    table.insert(regions, { { start, 0, #lines - 1, #lines[#lines] } })
                end
            end
        elseif line:match("^%s*#") then
            table.insert(comments, { i - 1, 0, i - 1, #line })
        end
        i = i + 1
    end
    return regions, markers, comments
end

--- Highlight a scripts buffer: the http grammar only reads a `> {% %}` block
--- after a request line, so tree-sitter JavaScript parses the code of the
--- blocks instead (kept in step with edits), and extmarks mark the rest.
--- Without a JavaScript parser, `syntax/http-nvim-scripts.vim` does it.
---@param bufnr integer
local function highlight_scripts(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "javascript", { error = false })
    if not ok or not parser then
        vim.treesitter.stop(bufnr)
        vim.bo[bufnr].syntax = "http-nvim-scripts"
        return
    end
    local function update()
        if not vim.api.nvim_buf_is_loaded(bufnr) then
            return
        end
        local regions, markers, comments = script_regions(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        -- No block: parse nothing rather than the whole buffer
        parser:set_included_regions(#regions > 0 and regions or { { { 0, 0, 0, 0 } } })
        vim.api.nvim_buf_clear_namespace(bufnr, scripts_ns, 0, -1)
        for group, ranges in pairs({ httpNvimScriptsMarker = markers, httpNvimScriptsComment = comments }) do
            for _, range in ipairs(ranges) do
                vim.api.nvim_buf_set_extmark(bufnr, scripts_ns, range[1], range[2], {
                    end_row = range[3],
                    end_col = range[4],
                    hl_group = group,
                })
            end
        end
    end
    update()
    -- Replaces the http highlighter that the filetype may have started
    vim.treesitter.highlighter.new(parser)
    local pending = false
    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function()
            if not pending then
                pending = true
                vim.schedule(function()
                    pending = false
                    update()
                end)
            end
        end,
    })
end

--- Lines of a scripts buffer: both blocks, empty ones too, each after a comment.
---@param owner PostmanCollection|PostmanItem
---@param where string
---@return string[]
local function scripts_lines(owner, where)
    local lines = {
        "# Before each request in " .. where .. ": the collection's first, then each folder's, then the request's",
        "< {%",
    }
    vim.list_extend(lines, jetbrains.script_of(owner, "prerequest") or {})
    vim.list_extend(lines, { "%}", "", "# After each response in " .. where .. ", in the same order", "> {%" })
    vim.list_extend(lines, jetbrains.script_of(owner, "test") or {})
    table.insert(lines, "%}")
    return lines
end

--- Edit the scripts of the collection (`path` "") or of a folder, which run
--- around every request in it: Postman's `prerequest` and `test` events.
---@param owner PostmanCollection|PostmanItem
---@param path string
local function edit_scripts(owner, path)
    local bufnr = state.script_bufs[owner]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        if vim.api.nvim_buf_is_loaded(bufnr) then
            open_edit_window()
            vim.api.nvim_set_current_buf(bufnr)
            return
        end
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    state.script_bufs[owner] = nil

    bufnr = create_edit_buf("http-nvim-scripts://" .. path, "http")
    if not bufnr then
        return
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
        scripts_lines(owner, path == "" and "the collection" or "'" .. path .. "'"))
    vim.bo[bufnr].modified = false
    vim.b[bufnr].http_nvim_scripts = true
    highlight_scripts(bufnr)
    open_edit_window()
    vim.api.nvim_set_current_buf(bufnr)
    state.script_bufs[owner] = bufnr
    lsp.attach(bufnr)

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
            fire_write(bufnr, "BufWritePre")
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local scripts, err, stray = jetbrains.script_blocks(lines, 1, #lines)
            if not scripts or stray then
                vim.notify("http-nvim: " .. (err or "line " .. stray .. ": expected '< {%' or '> {%'"),
                    vim.log.levels.ERROR)
                return
            end
            jetbrains.set_script(owner, scripts.prerequest, "prerequest")
            jetbrains.set_script(owner, scripts.test, "test")
            -- On failure the buffer stays modified so the edit is not silently lost
            if write_collection(state.collection_path) then
                vim.bo[bufnr].modified = false
                fire_write(bufnr, "BufWritePost")
            end
            if state.split and state.split.bufnr and vim.api.nvim_buf_is_valid(state.split.bufnr) then
                render()
            end
        end,
    })
end

local edit

--- `S`: the scripts of the collection (on its line) or of the folder under the
--- cursor. A request's own scripts are in its edit buffer, which opens instead.
local function edit_scripts_at_cursor()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    if state.line_scripts[line] then
        edit_scripts(state.collection, "")
        return
    end
    local node = state.line_nodes[line]
    if not node then
        return
    end
    if node.request then
        edit()
        return
    end
    edit_scripts(node, state.line_paths[line])
end

edit = function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    if state.line_env[line] then
        edit_env()
        return
    end
    if state.line_scripts[line] then
        edit_scripts(state.collection, "")
        return
    end
    local node = state.line_nodes[line]
    if not node or not node.request then
        return
    end

    local name = "http-nvim://" .. state.line_paths[line]
    local bufnr = state.edit_bufs[node]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        if vim.api.nvim_buf_is_loaded(bufnr) then
            open_edit_window()
            vim.api.nvim_set_current_buf(bufnr)
            return
        end
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    state.edit_bufs[node] = nil

    bufnr = create_edit_buf(name, "http")
    if not bufnr then
        return
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, jetbrains.to_lines(node.name, node.request,
        jetbrains.script_of(node), jetbrains.script_of(node, "prerequest")))
    vim.bo[bufnr].modified = false
    open_edit_window()
    vim.api.nvim_set_current_buf(bufnr)
    state.edit_bufs[node] = bufnr
    lsp.attach(bufnr)

    -- Send what the buffer holds now, saved or not
    keymaps.map("send", function()
        local request, err, _, script, pre_script = jetbrains.from_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
            node.request)
        if not request then
            vim.notify("http-nvim: " .. err, vim.log.levels.ERROR)
            return
        end
        send_request(request, scripts_for(node, { prerequest = pre_script, test = script }), node)
    end, bufnr)

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
            fire_write(bufnr, "BufWritePre")
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local request, err, section, script, pre_script = jetbrains.from_lines(lines, node.request)
            if not request or not section then
                vim.notify("http-nvim: " .. err, vim.log.levels.ERROR)
                return
            end
            -- Only once the request reads fine: a failed save leaves the buffer as it was
            if state.format_on_save then
                lsp.format_bodies(bufnr)
                lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                request, err, section, script, pre_script = jetbrains.from_lines(lines, node.request)
                if not request or not section then
                    vim.notify("http-nvim: " .. err, vim.log.levels.ERROR)
                    return
                end
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
                local path = vim.api.nvim_buf_get_name(bufnr):match("^http%-nvim://(.*)$") or ""
                path = (path:match("^(.*/)") or "") .. section.name
                pcall(vim.api.nvim_buf_set_name, bufnr, "http-nvim://" .. path)
            end
            node.request = request
            jetbrains.set_script(node, script)
            jetbrains.set_script(node, pre_script, "prerequest")
            -- On failure the buffer stays modified so the edit is not silently lost
            if write_collection(state.collection_path) then
                vim.bo[bufnr].modified = false
                fire_write(bufnr, "BufWritePost")
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
    local bufs = vim.list_extend(vim.tbl_values(state.edit_bufs), vim.tbl_values(state.script_bufs))
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
    state.script_bufs = {}
    state.env_buf = nil
    return true, nil
end

return {
    close_edit_bufs = close_edit_bufs,
    edit = edit,
    edit_scripts_at_cursor = edit_scripts_at_cursor,
    edit_bufs_under = edit_bufs_under,
    rename_edit_bufs = rename_edit_bufs,
}
