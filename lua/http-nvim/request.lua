--- Sending requests with curl and showing the response in a floating layout.
local Layout = require("nui.layout")
local Popup = require("nui.popup")
local collection = require("http-nvim.collection")
local config = require("http-nvim.config")
local env = require("http-nvim.env")
local handler = require("http-nvim.handler")
local json = require("http-nvim.json")
local jetbrains = require("http-nvim.jetbrains")
local keymaps = require("http-nvim.keymaps")
local state = require("http-nvim.state")

local ns = config.ns
local expand_env = env.expand_env

-- Also used outside the panel, whose syntax file defines it, e.g. by `<leader>hre` before the panel opens
vim.api.nvim_set_hl(0, "httpNvimMethod", { link = "Keyword", default = true })

---@class ResponseBoxes
---@field header NuiPopup Method, URL and status
---@field content NuiPopup The response body, or curl's error
---@field sidebar_right NuiPopup Request and response headers

--- What a sent request shows, kept so `<leader>hrp` can show it again.
---@class ResponseView
---@field request PostmanRequest|string The request as sent, before `{{key}}` replacement
---@field scripts RequestScripts|nil Scripts run around it, sent again with it
---@field node PostmanItem|nil The collection item it came from, re-read by `<leader>hre`
---@field request_line string
---@field status string
---@field content string[]
---@field content_filetype string
---@field sidebar_right string[]
---@field boxes ResponseBoxes[] Open layouts showing this view, filled in when the response arrives

--- Scripts run around a request, in order.
---@class RequestScripts
---@field prerequest string[][] Before it is sent
---@field test string[][] After its response

--- The scripts around a request: the collection's, then each folder's from the
--- outermost, then the request's own: `own`, or else the item's saved ones.
---@param node PostmanItem|nil
---@param own { prerequest: string[]|nil, test: string[]|nil }|nil
---@return RequestScripts
local function scripts_for(node, own)
    own = own or (node and {
        prerequest = jetbrains.script_of(node, "prerequest"),
        test = jetbrains.script_of(node, "test"),
    }) or {}
    local scripts = { prerequest = {}, test = {} }
    local owners = node and collection.ancestors(node) or {}
    for listen, list in pairs(scripts) do
        for _, owner in ipairs(owners) do
            local script = jetbrains.script_of(owner, listen)
            if script then
                table.insert(list, script)
            end
        end
        if own[listen] then
            table.insert(list, own[listen])
        end
    end
    return scripts
end

--- curl arguments for a request, with `{{key}}` replaced from the environment.
--- Only a raw body is sent; other body modes are skipped.
---@param request PostmanRequest|string
---@return string[] args, string method, string url, string|nil body The body as sent
local function curl_args(request)
    local method = type(request) == "table" and request.method or "GET"
    local sent_body
    -- Postman URLs may hold spaces and `[]` (e.g. `?q=["a", "b"]`): encode the spaces, and
    -- `--globoff` stops curl reading `[...]` as a range
    local url = expand_env(jetbrains.url_of(request)):gsub(" ", "%%20")
    -- The status code goes on a last line of its own, after the body
    local args = {
        "curl", "--silent", "--show-error", "--verbose", "--globoff",
        "--request", method, "--write-out", "\n%{http_code}",
    }
    -- Cookies are kept between requests, in a jar per collection
    if state.cookie_path then
        vim.list_extend(args, { "--cookie", state.cookie_path, "--cookie-jar", state.cookie_path })
    end
    if type(request) == "table" then
        for _, header in ipairs(request.header or {}) do
            if not header.disabled then
                table.insert(args, "--header")
                table.insert(args, expand_env(header.key) .. ": " .. expand_env(header.value or ""))
            end
        end
        local body = request.body
        if body and body.mode == "raw" and body.raw and body.raw ~= "" then
            sent_body = expand_env(body.raw)
            table.insert(args, "--data-binary")
            table.insert(args, sent_body)
        end
    end
    table.insert(args, "--")
    table.insert(args, url)
    return args, method, url, sent_body
end

--- Warn when the request says its body is JSON (`Content-Type: application/json`
--- or `...+json`) but the body as sent does not parse: servers then read no body.
---@param args string[] From `curl_args`
---@param body string|nil
local function check_json_body(args, body)
    if not body or vim.trim(body) == "" then
        return
    end
    local content_type
    for i, arg in ipairs(args) do
        if arg == "--header" then
            local name, value = (args[i + 1] or ""):match("^([^:]+):%s*(.*)$")
            if name and vim.trim(name):lower() == "content-type" then
                content_type = value:lower()
            end
        end
    end
    -- The media type, without parameters such as `; charset=utf-8`
    if not content_type or not vim.trim(content_type:match("^[^;]*")):match("[/+]json$") then
        return
    end
    local err = json.first_error(json.check(body))
    if err then
        local line, col = json.position(body, err.s)
        vim.notify(("http-nvim: the body is not valid JSON, though Content-Type is %s: line %d, column %d: %s")
            :format(content_type, line + 1, col + 1, err.message), vim.log.levels.WARN)
    end
end

--- Put the body as sent below the request headers (the first `> ` block): curl's
--- `--verbose` only says how many bytes it sent.
---@param headers string[] From `split_verbose`
---@param body string|nil
---@return string[]
local function with_sent_body(headers, body)
    if not body or body == "" then
        return headers
    end
    local lines = vim.split((body:gsub("\r\n", "\n")), "\n", { plain = true })
    local at = 0
    for i, line in ipairs(headers) do
        if line:sub(1, 2) ~= "> " then
            break
        end
        at = i
    end
    local out = vim.list_slice(headers, 1, at)
    table.insert(out, ">")
    for _, line in ipairs(lines) do
        table.insert(out, "> " .. line)
    end
    return vim.list_extend(out, headers, at + 1)
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
                Layout.Box(content, { size = "60%" }),
                Layout.Box(sidebar_right, { size = "40%" }),
            }, { dir = "row", size = "90%" }),
        }, { dir = "col" })
    )

    layout:mount()

    for _, popup in ipairs({ header, content, sidebar_right }) do
        keymaps.map("close", function() layout:unmount() end, popup.bufnr)
    end
    keymaps.map("focus_headers", function() vim.api.nvim_set_current_win(sidebar_right.winid) end, content.bufnr)
    keymaps.map("focus_response", function() vim.api.nvim_set_current_win(content.winid) end, sidebar_right.bufnr)

    return { header = header, content = content, sidebar_right = sidebar_right }
end

---@param view ResponseView
local function show_view(view)
    for _, boxes in ipairs(view.boxes) do
        set_readonly_lines(boxes.header.bufnr, { view.request_line, view.status })
        local header = boxes.header.bufnr
        if header and vim.api.nvim_buf_is_valid(header) then
            -- Redrawn when the response arrives: drop the previous highlight
            vim.api.nvim_buf_clear_namespace(header, ns, 0, -1)
            vim.api.nvim_buf_set_extmark(header, ns, 0, 0, {
                end_col = #view.request_line:match("^%S*"),
                hl_group = "httpNvimMethod",
            })
        end
        set_readonly_lines(boxes.content.bufnr, view.content)
        set_readonly_lines(boxes.sidebar_right.bufnr, view.sidebar_right)
        local bufnr = boxes.content.bufnr
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.bo[bufnr].filetype = view.content_filetype
        end
    end
end

--- A copy of `request` with the headers a pre-request script set: each replaces
--- the enabled headers of its name (case-insensitive), or else is added.
---@param request PostmanRequest|string
---@param headers { key: string, value: string }[]
---@return PostmanRequest|string
local function with_headers(request, headers)
    if #headers == 0 then
        return request
    end
    -- A bare URL string is a GET request
    request = type(request) == "table" and vim.deepcopy(request) or { method = "GET", url = { raw = request } }
    local list = request.header or {}
    for _, header in ipairs(headers) do
        local name = header.key:lower()
        local replaced = false
        list = vim.tbl_filter(function(existing)
            if existing.disabled or existing.key:lower() ~= name then
                return true
            end
            -- The first one keeps its place, the others go
            if replaced then
                return false
            end
            existing.value = header.value
            replaced = true
            return true
        end, list)
        if not replaced then
            table.insert(list, { key = header.key, value = header.value })
        end
    end
    request.header = list
    return request
end

--- Send a request with curl and show it in a floating layout:
--- method, URL and status on top, the response below. The pre-request scripts
--- run first, so `{{key}}` gets the variables they set and the request the
--- headers they set (only for this send); after the response,
--- the response handlers set environment variables from it.
---@param request PostmanRequest|string
---@param scripts RequestScripts|nil See `scripts_for`
---@param node PostmanItem|nil The item the request comes from, so `run_last` can read it again
local function send_request(request, scripts, node)
    local sent = request
    if scripts and #scripts.prerequest > 0 then
        sent = with_headers(request, handler.run(scripts.prerequest, nil))
    end
    local args, method, url, body = curl_args(sent)
    check_json_body(args, body)
    ---@type ResponseView
    local view = {
        request = request,
        scripts = scripts,
        node = node,
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
        view.sidebar_right = with_sent_body(headers, body)
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

        local text = response
        local ok, decoded = pcall(vim.json.decode, response)
        if ok and type(decoded) == "table" then
            response = vim.json.encode(decoded, { indent = "  ", sort_keys = true })
            view.content_filetype = "json"
        end
        view.content = vim.split((response:gsub("\r\n", "\n")), "\n", { plain = true })
        show_view(view)

        if scripts and #scripts.test > 0 then
            handler.run(scripts.test, {
                status = tonumber(status),
                headers = handler.parse_headers(headers),
                cookies = handler.parse_cookies(headers),
                body = ok and decoded or text,
                text = text,
            })
        end
    end))
end

--- Show the last request and its response again, without sending it.
local function preview_last()
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

--- Send the last request again, with the current environment values. The request
--- is read again from its item: its edit buffer as it is now, saved or not, or
--- else the item as saved. A request with no item is sent as it was.
local function run_last()
    local view = state.last_view
    if not view then
        vim.notify("http-nvim: no request sent yet")
        return
    end
    local node = view.node
    if not node or not node.request then
        send_request(view.request, view.scripts)
        return
    end
    local bufnr = state.edit_bufs[node]
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        local request, err, _, script, pre_script = jetbrains.from_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
            node.request)
        if not request then
            vim.notify("http-nvim: " .. err, vim.log.levels.ERROR)
            return
        end
        send_request(request, scripts_for(node, { prerequest = pre_script, test = script }), node)
        return
    end
    send_request(node.request, scripts_for(node), node)
end

return {
    send_request = send_request,
    scripts_for = scripts_for,
    preview_last = preview_last,
    run_last = run_last,
}
