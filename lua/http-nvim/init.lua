local collections = require("http-nvim.collections")
local panel = require("http-nvim.panel")
local request = require("http-nvim.request")
local state = require("http-nvim.state")

local M = {}

--- Open the collection panel, asking which collection to use if none is selected.
M.open = panel.open

--- Ask which collection to use, then open it in the panel.
M.pick = function()
    collections.pick(panel.open)
end

--- Create a collection folder in `collection_dir`.
---@param name string
M.create = function(name)
    collections.create(name)
end

--- Show the last request and its response again, without sending it.
M.preview_last = request.preview_last

--- Send the last request again, with the current environment values.
M.run_last = request.run_last

---@class HttpNvimOptions
---@field collection_dir string|nil Folder holding one folder per collection; defaults to `stdpath("data")/http-nvim/collections`

--- Configure the plugin. `collection_dir` may use `~` and environment variables.
---@param opts HttpNvimOptions|nil
M.setup = function(opts)
    opts = opts or {}
    vim.validate("collection_dir", opts.collection_dir, "string", true)
    if opts.collection_dir then
        state.collection_dir = (vim.fn.fnamemodify(vim.fn.expand(opts.collection_dir), ":p"):gsub("/$", ""))
    end
end

return M
