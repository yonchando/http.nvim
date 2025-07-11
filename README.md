# http.nvim

Simple http request for api json response in neovim

> Noted POST request doesn't work when cursor in body content

## Setup
This plugins required `sudo apt install -y curl` and `:TSInstall http`

Installation with your favorite package management

### lazy pack
```lua
return {
    "yonchando/http.nvim",
    config = function()
        local http = require("http-nvim")

        http.setup()

        vim.keymap.set("n", "<leader>hrl", http.run_last, { desc = "[HttpRun] re-run recently" })

        vim.keymap.set("n", "<leader>hrp", http.last_result, { desc = "[HttpRun] Preview recently run" })

        vim.keymap.set("n", "<leader>hrc", ":HttpRun<CR>")
    end
}
```

## Usage

Create file or buffer with filetype `http`

```http
### comment for separator
GET http://localhost:8000/api/posts?query=search
Accept: application/json

### comment for separator
POST http://localhost:8000/api/post
Accept: application/json
Content-Type: application/json

{
    "title": "foo",
    "description": "bar"
}

```

`:HttpRun` run http request under cursor

`:HttpResult` view recently request

`:HttpRerun` re-run recently run

`:HttpClose` close buffer popup

`:HttpHistory` View all request
