local collections = require("http-nvim.collections")
local keymaps = require("http-nvim.keymaps")
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

--- Set the global keymaps (`open`, `preview_last`, `run_last`). Called by the plugin
--- file, and again by `setup()` so that keymaps given there replace them.
M.map_global_keys = function()
    keymaps.apply_global({
        open = M.open,
        preview_last = M.preview_last,
        run_last = M.run_last,
    })
end

---@class HttpNvimOptions
---@field collection_dir string|nil Folder holding one folder per collection; defaults to `stdpath("data")/http-nvim/collections`
---@field keymaps table<string, HttpNvimKeys>|nil Keys per action, replacing the defaults in `keymaps.lua`; `false` unmaps
---@field lsp { autotrigger: boolean|nil }|false|nil Completion in request edit buffers; `autotrigger` opens Neovim's own menu while typing, `false` turns it off

--- Configure the plugin. `collection_dir` may use `~` and environment variables.
---@param opts HttpNvimOptions|nil
M.setup = function(opts)
    opts = opts or {}
    vim.validate("collection_dir", opts.collection_dir, "string", true)
    vim.validate("lsp", opts.lsp, { "table", "boolean" }, true)
    if opts.collection_dir then
        state.collection_dir = (vim.fn.fnamemodify(vim.fn.expand(opts.collection_dir), ":p"):gsub("/$", ""))
    end
    if opts.lsp ~= nil then
        state.lsp = opts.lsp and { autotrigger = type(opts.lsp) == "table" and opts.lsp.autotrigger == true } or false
    end
    if opts.keymaps then
        keymaps.configure(opts.keymaps)
        M.map_global_keys()
    end
end

return M
