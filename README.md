# http.nvim

Keep your API requests in Postman collections and browse, edit and send them without leaving Neovim.

- Browse a collection's folders and requests in a side panel
- Edit a request as a `.http` file (JetBrains HTTP Client format) and save it back to the collection
- Keep environment variables per collection and use them in requests as `{{key}}`
- Send a request with curl and see the status, response and headers in a floating window

> [!CAUTION]
> **Breaking changes.** This is a rewrite. Requests now live in Postman collections browsed from a panel, instead of being run from any `.http` file. The `:HttpRun`, `:HttpResult`, `:HttpRerun`, `:HttpClose` and `:HttpHistory` commands are gone, and so are `http.last_result` and the old keymaps.
>
> To keep the old version, pin the `v0.1.0` branch:
>
> ```lua
> -- lazy.nvim
> { "yonchando/http.nvim", branch = "v0.1.0" }
>
> -- vim.pack
> vim.pack.add({ { src = "https://github.com/yonchando/http.nvim", version = "v0.1.0" } })
> ```

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
    -- Completion in request edit buffers from a built-in language server, or false.
    -- autotrigger opens Neovim's own completion menu while typing; leave it off
    -- with a completion plugin (blink.cmp, nvim-cmp), which picks the server up itself.
    lsp = { autotrigger = false },
})
```

Each collection is a folder in `collection_dir` holding:

- `collection.json`: a Postman v2.1 collection, which Postman can import
- `env.json`: a Postman environment with its variables

Each collection also gets a `cookie` file, its curl cookie jar: cookies set by responses are saved there and sent with its next requests. Manage it with the `:HttpCookies*` commands.

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

A request can end with a response handler that sets environment variables from the response, saved to `env.json` after each send (see `:h http-nvim-response-handler` for the supported values):

```http
### login
POST {{url}}/login
Content-Type: application/json

{ "user": "me" }

> {%
  client.global.set("token", response.body.data.token)
  client.global.set("auth", "Bearer " + response.body.data.token)
%}
```

In an edit buffer, a built-in language server completes `{{key}}` with the environment variables, the method, header names and common values, cookie names from the collection's jar (in a `Cookie:` header and in `response.cookiesByName("")`), and the response handler API inside `> {% %}`. `K` on a `{{key}}` shows its value (masked when secret), or that it is disabled or not set. A completion plugin shows it like any LSP source; without one, use `<C-x><C-o>` or set `lsp = { autotrigger = true }`.

Press `e` on the environment variables in the panel to edit them as `KEY=value` lines, like a `.env` file. `# KEY=value` is a disabled variable, which `{{key}}` doesn't use. `KEY=value # secret` marks a secret variable (Postman type `secret`), whose value the panel shows as `********`.

### Commands

| Command | Description |
|---|---|
| `:Http` | Choose a collection and open it in the panel |
| `:Http create {name}` | Create a collection |
| `:HttpCookies` | Show the collection's cookies in a floating window, values masked (`abc1…`) |
| `:HttpCookiesClear` | Delete the collection's cookie jar, like logging out of everything |
| `:HttpCookiesDelete {name}` | Remove one cookie |
| `:HttpCookiesEdit` | Open the cookie jar file in a buffer |

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

## Roadmap

- [x] List collections and environments from Postman
- [x] Add new requests and folders
- [x] Send a request and show the result
- [x] Read the response in `.http` and set environment variables from it
- [x] Support cookie sessions
- [ ] Support WebSocket requests
- [ ] Support HTML and other content types in the response
