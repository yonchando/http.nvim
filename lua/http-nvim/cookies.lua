--- The selected collection's cookie jar (`state.cookie_path`), which curl reads and
--- writes on each request: showing, clearing, deleting and editing its cookies.
local Popup = require("nui.popup")
local keymaps = require("http-nvim.keymaps")
local state = require("http-nvim.state")

--- A cookie line of curl's jar (Netscape format).
---@class Cookie
---@field domain string
---@field path string
---@field secure boolean
---@field http_only boolean
---@field expires integer Unix time, 0 for a session cookie
---@field name string
---@field value string

---@return string|nil
local function jar_path()
    if not state.cookie_path then
        vim.notify("http-nvim: no collection selected, choose one with :Http", vim.log.levels.ERROR)
    end
    return state.cookie_path
end

--- A cookie of a jar line, or nil for comments and blank lines.
---@param line string
---@return Cookie|nil
local function parse_line(line)
    local http_only = false
    if line:match("^#HttpOnly_") then
        http_only = true
        line = line:sub(#"#HttpOnly_" + 1)
    elseif line:match("^#") then
        return nil
    end
    local fields = vim.split(line, "\t", { plain = true })
    if #fields < 7 then
        return nil
    end
    return {
        domain = fields[1],
        path = fields[3],
        secure = fields[4] == "TRUE",
        http_only = http_only,
        expires = tonumber(fields[5]) or 0,
        name = fields[6],
        value = table.concat(fields, "\t", 7),
    }
end

---@param path string
---@return string[]
local function read_lines(path)
    if vim.fn.filereadable(path) == 0 then
        return {}
    end
    return vim.fn.readfile(path)
end

--- Cookies in the jar, in file order.
---@return Cookie[]
local function list()
    local cookies = {}
    for _, line in ipairs(read_lines(state.cookie_path or "")) do
        table.insert(cookies, parse_line(line))
    end
    return cookies
end

--- The first 4 characters, enough to tell cookies apart without showing them.
---@param value string
---@return string
local function mask(value)
    return #value > 4 and value:sub(1, 4) .. "…" or "…"
end

--- Show the cookies in a floating window, values masked.
local function show()
    local path = jar_path()
    if not path then
        return
    end
    local lines = { state.selected .. ": " .. path, "" }
    local cookies = list()
    if #cookies == 0 then
        table.insert(lines, "No cookies")
    end
    for _, cookie in ipairs(cookies) do
        local flags = (cookie.secure and " secure" or "") .. (cookie.http_only and " httponly" or "")
        local expires = cookie.expires == 0 and "session" or os.date("%Y-%m-%d %H:%M", cookie.expires)
        table.insert(lines, ("%s = %s"):format(cookie.name, mask(cookie.value)))
        table.insert(lines, ("    %s%s  expires %s%s"):format(cookie.domain, cookie.path, expires, flags))
    end

    local popup = Popup({
        enter = true,
        relative = "editor",
        position = "50%",
        size = { width = "60%", height = math.min(#lines, math.floor(vim.o.lines * 0.6)) },
        border = { style = "rounded", text = { top = " Cookies " } },
        buf_options = { modifiable = true, readonly = false },
    })
    popup:mount()
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
    vim.bo[popup.bufnr].modifiable = false
    keymaps.map("close", function() popup:unmount() end, popup.bufnr)
    popup:on("BufLeave", function() popup:unmount() end, { once = true })
end

--- Delete the jar, ending every session of the selected collection.
local function clear()
    local path = jar_path()
    if not path then
        return
    end
    if vim.fn.filereadable(path) == 0 then
        vim.notify("http-nvim: no cookies for " .. state.selected)
        return
    end
    if vim.fn.delete(path) ~= 0 then
        vim.notify("http-nvim: failed to delete " .. path, vim.log.levels.ERROR)
        return
    end
    vim.notify("http-nvim: cleared the cookies of " .. state.selected)
end

--- Remove the cookies named `name`, for every domain.
---@param name string
local function delete(name)
    local path = jar_path()
    if not path then
        return
    end
    local kept, removed = {}, 0
    for _, line in ipairs(read_lines(path)) do
        local cookie = parse_line(line)
        if cookie and cookie.name == name then
            removed = removed + 1
        else
            table.insert(kept, line)
        end
    end
    if removed == 0 then
        vim.notify("http-nvim: no cookie named '" .. name .. "'", vim.log.levels.WARN)
        return
    end
    if vim.fn.writefile(kept, path) ~= 0 then
        vim.notify("http-nvim: failed to write " .. path, vim.log.levels.ERROR)
        return
    end
    vim.notify("http-nvim: deleted cookie '" .. name .. "'")
end

--- Cookie names, for completing `:HttpCookiesDelete`.
---@return string[]
local function names()
    local seen, result = {}, {}
    for _, cookie in ipairs(list()) do
        if not seen[cookie.name] then
            seen[cookie.name] = true
            table.insert(result, cookie.name)
        end
    end
    return result
end

--- Open the jar file itself.
local function edit()
    local path = jar_path()
    if not path then
        return
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
end

return {
    list = list,
    mask = mask,
    names = names,
    show = show,
    clear = clear,
    delete = delete,
    edit = edit,
}
