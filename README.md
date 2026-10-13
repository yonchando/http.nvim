# http.nvim

Keep your API requests in Postman collections and browse, edit and send them without leaving Neovim.

- Browse a collection's folders and requests in a side panel
- Edit a request as a `.http` file (JetBrains HTTP Client format) and save it back to the collection
- Keep environment variables per collection and use them in requests as `{{key}}`
- Send a request with curl and see the status, response and headers in a floating window

## Requirements

- Neovim with the tree-sitter `http` parser (`:TSInstall http`)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- curl (`sudo apt install -y curl`)

## Installation

### lazy.nvim

```lua
return {
    "yonchando/http.nvim",
    dependencies = { "MunifTanjim/nui.nvim" },
    config = function()
        require("http-nvim").setup()
    end,
}
```

### vim.pack

```lua
vim.pack.add({
    "https://github.com/MunifTanjim/nui.nvim",
    "https://github.com/yonchando/http.nvim",
})
require("http-nvim").setup()
```

## Configuration

All options are optional; these are the defaults:

```lua
require("http-nvim").setup({
    -- Folder holding one folder per collection
    collection_dir = vim.fn.stdpath("data") .. "/http-nvim/collections",
    -- Keys per action: a key, a list of keys, or false to leave it unmapped.
    -- An action you set replaces its default keys; the others keep theirs.
    keymaps = {
        -- anywhere
        open = "<leader>ho",
        preview_last = "<leader>hrp",
        run_last = "<leader>hre",
        -- panel and request edit buffer
        send = "<leader>hrr",
        -- panel
        help = "g?",
        toggle = { "<CR>", "=" },
        edit = "e",
        rename = "r",
        add = "a",
        delete = "D",
        cut = "x",
        copy = "y",
        paste = "p",
        cancel_clipboard = "<Esc>",
        move_down = "]m",
        move_up = "[m",
        undo = "u",
        -- response window
        close = "q",
        focus_headers = "<C-l>",
        focus_response = "<C-h>",
    },
})
```

Each collection is a folder in `collection_dir` holding:

- `collection.json`: a Postman v2.1 collection, which Postman can import
- `env.json`: a Postman environment with its variables

Both can be imported into Postman, and Postman exports (a collection, and an environment saved as `env.json`) work here too.

## Usage

1. `:Http create my-api` to create a collection
2. `<leader>ho` to open the panel (it asks which collection to use the first time), then `a` to add a request
3. Fill in the request and save it with `:w`
4. `<leader>hrr` on the request to send it

A request in the edit buffer looks like this:

```http
### create post
POST {{url}}/api/posts
Accept: application/json
Content-Type: application/json

{
    "title": "foo",
    "description": "bar"
}
```

Press `e` on the environment variables in the panel to edit them as `KEY=value` lines, like a `.env` file. `# KEY=value` is a disabled variable, which `{{key}}` doesn't use.

### Commands

| Command | Description |
|---|---|
| `:Http` | Choose a collection and open it in the panel |
| `:Http create {name}` | Create a collection |

### Keymaps

| Key | Action | Description |
|---|---|---|
| `<leader>ho` | `open` | Open the collection panel |
| `<leader>hrp` | `preview_last` | Show the last response again |
| `<leader>hre` | `run_last` | Send the last request again |
| `<leader>hrr` | `send` | Send the request (panel, edit buffer) |
| `g?` | `help` | Open the help |
| `<CR>` `=` | `toggle` | Expand or collapse a folder |
| `e` | `edit` | Edit a request or the variables |
| `r` | `rename` | Rename a request or folder |
| `a` | `add` | Add a request or folder (`a/b/name` also creates the folders) |
| `D` | `delete` | Delete a request or folder |
| `x` / `y` / `p` | `cut` / `copy` / `paste` | Move or duplicate a request or folder |
| `<Esc>` | `cancel_clipboard` | Cancel a cut or copy |
| `]m` / `[m` | `move_down` / `move_up` | Move among its siblings |
| `u` | `undo` | Undo the last delete |
| `q` | `close` | Close the response window |
| `<C-l>` / `<C-h>` | `focus_headers` / `focus_response` | Switch between the response and headers |

See `:help http-nvim` for details.
