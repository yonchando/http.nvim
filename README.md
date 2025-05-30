# http.nvim

Simple http request for api json response in neovim

## Setup
This plugins required `sudo apt install -y curl` and `:TSInstall http`

Installation with your favorite package management

### lazy pack
```lua
return {
    "yonchando/http.nvim",
}
```

## Usage

Create file or buffer with filetype `http`

Example: requests.http or `:set filetype=http`

inspiration from [IntelliJ Http Client](https://www.jetbrains.com/help/idea/http-client-in-product-code-editor.html)
> You can use autocmd to get filetype with file extension `.http`
```lua
vim.cmd [[
augroup HttpFiletypeRelated
  au BufNewFile,BufRead *.http set ft=http
augroup END
]]

```

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

`:HttpRun` it run http request under cursor

### Set keymap

```lua

    local http = require("http-nvim")

vim.keymap.set("n","<leader>rc",function()
    http.make_request()
end)
```

