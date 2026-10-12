-- Convert Postman requests to and from the JetBrains HTTP Client format:
--
--   ### name
--   POST {{url}}/v1/login
--   Content-Type: application/json
--   # X-Disabled: header
--
--   { "body": true }

local M = {}

---@param request PostmanRequest|string
---@return string
local function url_of(request)
    local url = type(request) == "table" and request.url or request
    if type(url) == "table" then
        return url.raw or ""
    end
    return url or ""
end

---@param name string
---@param request PostmanRequest|string
---@return string[]
M.to_lines = function(name, request)
    local method = type(request) == "table" and request.method or "GET"
    local lines = {
        "### " .. name,
        method .. " " .. url_of(request),
    }

    if type(request) ~= "table" then
        return lines
    end

    for _, header in ipairs(request.header or {}) do
        local prefix = header.disabled and "# " or ""
        table.insert(lines, prefix .. header.key .. ": " .. (header.value or ""))
    end

    local body = request.body
    if body and body.mode == "raw" and body.raw and body.raw ~= "" then
        table.insert(lines, "")
        for _, line in ipairs(vim.split((body.raw:gsub("\r\n", "\n")), "\n", { plain = true })) do
            table.insert(lines, line)
        end
    elseif body and body.mode and body.mode ~= "raw" then
        table.insert(lines, "")
        table.insert(lines, "# body mode '" .. body.mode .. "' is not editable here and is kept as is")
    end

    return lines
end

--- Parse lines written by `to_lines` back into a Postman request, keeping the
--- fields the HTTP format cannot express from `original`.
---@param lines string[]
---@param original PostmanRequest|string
---@return PostmanRequest|nil, string|nil
M.from_lines = function(lines, original)
    local i = 1
    -- Skip the `### name` separator, comments and blank lines before the request line
    while lines[i] and (lines[i]:match("^%s*$") or lines[i]:match("^%s*#") or lines[i]:match("^%s*//")) do
        i = i + 1
    end
    if not lines[i] then
        return nil, "missing request line"
    end

    local method, url = lines[i]:match("^%s*(%u+)%s+(.-)%s*$")
    if not method then
        method, url = "GET", vim.trim(lines[i])
    end
    url = url:gsub("%s+HTTP/[%d.]+$", "")
    if url == "" then
        return nil, "missing url"
    end
    i = i + 1

    local headers = {}
    while lines[i] and not lines[i]:match("^%s*$") do
        local disabled, key, value = lines[i]:match("^(#?)%s*([^:%s][^:]*):%s*(.*)$")
        if not key then
            return nil, "invalid header line " .. i .. ": " .. lines[i]
        end
        local header = { key = vim.trim(key), value = value }
        if disabled == "#" then
            header.disabled = true
        end
        table.insert(headers, header)
        i = i + 1
    end

    local body_lines = vim.list_slice(lines, i + 1)
    while #body_lines > 0 and body_lines[#body_lines]:match("^%s*$") do
        table.remove(body_lines)
    end

    local request = type(original) == "table" and vim.deepcopy(original) or {}
    request.method = method
    request.header = headers
    if url ~= url_of(original) then
        request.url = { raw = url }
    end

    local body = request.body
    if body and body.mode and body.mode ~= "raw" then
        -- Not representable in the HTTP format: leave the original body untouched
        return request, nil
    end
    if #body_lines > 0 then
        request.body = vim.tbl_extend("force", body or {}, { mode = "raw", raw = table.concat(body_lines, "\n") })
    else
        request.body = nil
    end
    return request, nil
end

return M
