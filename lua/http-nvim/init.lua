local ts_utils = require("nvim-treesitter.ts_utils")
local cmd = require('http-nvim.cmd')
local ui = require('http-nvim.ui')
local log = require("http-nvim.log")

local M = {}

local state = {
    open_request = false,
    command = "",
    curl = {
        method = "",
        url = "",
        header = {},
        data = {},
    },
    response = {},
    history = {},
}

---@param node TSNode|nil
local get_request = function(node)
    if node == nil then
        return nil
    end

    local result = node ---@type TSNode|nil

    while result and result:type() ~= "request" do
        result = result:parent()
    end

    return result
end

M.make_request = function()
    local node = ts_utils.get_node_at_cursor(0)

    if node == nil then
        log.error("No treesitter parser, Please use :TSInstall http")
        return
    end

    local request = nil

    if node:type() == 'request_separator' then
        request = node:next_sibling()
    elseif node:type() == 'value' and node:parent():type() == 'request_separator' then
        request = node:parent():next_sibling()
    else
        request = get_request(node)
    end

    if request == nil or request:type() == 'document' then
        log.warn("Try again with cursor outside body")
        return
    end

    state.curl = cmd.get_curl(request)
    state.command = cmd.build_curl({ curl = state.curl })
    ui:create_output_ui(state)
    cmd.run_command(state.command, {
        on_exit = function(response)
            state.response = response
            table.insert(state.history, {
                [state.curl.url] = response,
            })

            local ok, body = pcall(vim.json.encode, response.body)
            if ok then
                ui.set_content({ body })
            else
                ui.set_content({ response })
            end
        end
    })
end

M.rerun = function()
    ui:create_output_ui(state)
    cmd.run_command(state.command, {
        on_exit = function(response)
            state.output = response
            ui.set_content({ vim.json.encode(response.body) })
        end
    })
end

M.last_result = function()
    ui:create_output_ui(state)
    ui.set_content({ vim.json.encode(state.response.body) })
end

M.history = function()
    ui:create_output_ui(state)
    ui.set_content({ vim.json.encode(state.history) })
end

M.close = function()
    ui.quit()
end

M.setup = function()
    vim.filetype.add({
        extension = {
            http = 'http'
        }
    })

    local cmd_path = vim.fn.stdpath("data") .. "/lazy/http.nvim/http"
    local clone_cmd_path = vim.fn.stdpath("data") .. "/http.nvim"

    ---@diagnostic disable-next-line: undefined-field
    local fs_stat = vim.loop.fs_stat(clone_cmd_path)

    if fs_stat == nil then
        vim.cmd("silent !rm -rf " .. clone_cmd_path)
        vim.cmd("silent !mkdir -p " .. clone_cmd_path)
        vim.cmd("silent !cp " .. cmd_path .. " " .. clone_cmd_path .. "/http")
        vim.cmd("silent !chmod +x " .. clone_cmd_path .. "/http")
    end
end

return M
