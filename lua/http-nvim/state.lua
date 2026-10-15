---@class State
---@field collection_dir string Folder holding one folder per collection, set by `setup({ collection_dir })`
---@field selected string|nil Name of the chosen collection, a folder in `collection_dir`
---@field collection_path string|nil `collection.json` of the selected collection
---@field env_path string|nil `env.json` of the selected collection
---@field cookie_path string|nil `cookie` of the selected collection: curl's cookie jar
---@field split NuiSplit|nil
---@field collection PostmanCollection|nil The loaded collection, written back to `collection_path` on save
---@field items PostmanItem[]|nil Top-level items of the loaded collection
---@field env EnvVar[] Environment variables loaded from `env_path`, in file order
---@field env_file table The whole decoded environment file, written back with new `values` on save
---@field env_buf integer|nil Edit buffer of the environment variables, opened with `e`
---@field line_env table<integer, string> Lines of the environment section: the variable name, or "" for the heading
---@field last_view ResponseView|nil The last request sent, for `<leader>hrp` and `<leader>hre`
---@field expanded table<PostmanItem, boolean>
---@field line_nodes table<integer, PostmanItem>
---@field line_paths table<integer, string> Slash-separated item names, e.g. `auth/login`
---@field line_lists table<integer, PostmanItem[]> The list that holds the item on each line
---@field deleted DeletedItem[] Deleted folders and requests, most recent last, for `u`
---@field edit_bufs table<PostmanItem, integer> Edit buffer of each request opened with `e`
---@field clipboard { node: PostmanItem, mode: "cut"|"copy" }|nil Item marked with `x` (cut) or `y` (copy), pasted by `p`
---@field lsp { autotrigger: boolean }|false Completion server for edit buffers, set by `setup({ lsp })`; false when off
---@field view vim.fn.winsaveview.ret|nil Cursor and scroll of the panel when it was last closed, restored on open
local state = {
    collection_dir = vim.fn.stdpath("data") .. "/http-nvim/collections",
    selected = nil,
    collection_path = nil,
    env_path = nil,
    cookie_path = nil,
    split = nil,
    collection = nil,
    items = nil,
    env = {},
    env_file = {},
    env_buf = nil,
    line_env = {},
    last_view = nil,
    expanded = {},
    line_nodes = {},
    line_paths = {},
    line_lists = {},
    edit_bufs = {},
    clipboard = nil,
    deleted = {},
    lsp = { autotrigger = false },
}

return state
