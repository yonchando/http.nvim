# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

http.nvim is a Neovim plugin (pure Lua, LuaJIT) for browsing a Postman collection and editing its requests as `.http` (JetBrains HTTP Client format) buffers. This branch is a **rewrite in progress**: the v1 implementation (Go helper binary + `cmd.lua`/`ui.lua`/`log.lua`/`floating/window.lua`, `plugin/load_http.lua`) has been removed but is still available in git history (the `main` branch) for reference. `README.md` documents the rewrite; keep it in sync with the help file. The rewrite sends a request with `curl` from the panel or an edit buffer (`<leader>hrr`), replacing `{{key}}` with environment values.

## Architecture

- `plugin/http.lua`: the auto-loaded entrypoint. It registers `:Http` / `:Http create {name}`, sets the global keymaps with `map_global_keys()` (`<leader>ho` open, `<leader>hrp`/`<leader>hre` show or resend the last request from anywhere), and runs `helptags` on VimEnter for a hardcoded path (`stdpath("data")/site/pack/chando/start/http.nvim/doc`).
- `lua/http-nvim/init.lua`: the public API only (`open`, `preview_last`, `run_last`, `setup`), forwarding to the modules below.
- `lua/http-nvim/state.lua`: the one shared `state` table (class `State`). Every module requires it and reads or writes it directly. It also holds the options: `collection_dir` (set by `setup({ collection_dir })`, default `stdpath("data")/http-nvim/collections`), `selected` (the chosen collection's folder name) and the derived `collection_path`/`env_path`.
- `lua/http-nvim/config.lua`: only the `ns` extmark namespace.
- `lua/http-nvim/keymaps.lua`: every keymap, by action name (`defaults`). `setup({ keymaps })` calls `configure` (an action given replaces its default keys; `false` unmaps). Buffers map with `keymaps.map(action, rhs, bufnr)`; the global ones (`open`, `preview_last`, `run_last`) go through `apply_global`, which `plugin/http.lua` calls via `map_global_keys()` and `setup()` calls again so the order of the two doesn't matter. Never call `vim.keymap.set` directly.
- `lua/http-nvim/collections.lua`: one folder per collection in `collection_dir`. `create(name)` (`:Http create`), `list()`, `pick(on_done)` (`vim.ui.select`, used by `:Http` and by `open()` when nothing is selected) and `select(name)`. Switching closes the panel and the old edit buffers (`edit.close_edit_bufs`, which refuses if one is modified) and resets `state.collection`.
- `lua/http-nvim/collection.lua`: the Postman types, loading and writing the collection, the undo file for deletions, and tree helpers (`locate`, `ensure_folders`, `count_requests`, ...).
- `lua/http-nvim/env.lua`: loading, writing and parsing environment variables, and `expand_env` for `{{key}}`.
- `lua/http-nvim/request.lua`: curl (`send_request`), the response layout, `preview_last`/`run_last`.
- `lua/http-nvim/edit.lua`: request and environment edit buffers (`e`). It requires `panel` lazily, inside `render()`, because `panel` requires it.
- `lua/http-nvim/panel.lua`: rendering the panel and its keymaps (`open`).

How the panel and edit buffers work:
  - **Loading:** the collection is loaded once into `state.collection`, with `state.items` set to `collection.item`. The path is `state.collection_path`, i.e. `<collection_dir>/<selected>/collection.json`; a missing file starts an empty collection, created on the first save. Edits survive closing and reopening the panel because the collection isn't reloaded. Environment variables are loaded at the same time from `state.env_path`, a Postman environment, into `state.env`: its `values` list of `EnvVar` (`key`, `value`, `type`, `enabled`; other fields are kept). The older `{ "values": { key = value } }` map is still read and saved in Postman's shape. They are listed in file order as `KEY = value` lines under "Environment variables", disabled ones as `# KEY = value`, which `expand_env` skips.
  - **Panel:** a nui.nvim `Split`, filetype `http-nvim`.
  - **Rendering:** `render()` rebuilds the lines and fills `state.line_nodes` and `state.line_paths` (both keyed by line number). Keymaps use them to find the item under the cursor. Folder expansion is kept in `state.expanded`, keyed by node table.
  - **`e` (`edit()`):** opens the request in an `aboveleft split` of the panel. The buffer is named `http-nvim://<path> (edit)` and uses `buftype=acwrite`, `filetype=http`.
    - Closing that window moves focus back to the panel (a `WinClosed` autocmd).
    - An unloaded leftover buffer with the same name is wiped and rebuilt.
  - **Saving an edit buffer (`BufWriteCmd`):**
    - It parses the buffer with `jetbrains.from_lines` and deletes every section except the first named one.
    - The `### name` line renames the item, and the buffer is renamed to match.
    - It then rewrites the whole collection file with `vim.json.encode` (4-space indent, sorted keys).
- `lua/http-nvim/jetbrains.lua`: converts between Postman requests and JetBrains HTTP format.
  - `to_lines` writes a request out. Disabled headers become `# Key: value` comments. A non-raw body becomes a comment saying it is kept as is.
  - `from_lines(lines, original)` parses with **tree-sitter** (the `http` grammar). It uses only the first `(section (request_separator) (request))` and returns `request, err, { name, start_row, end_row }`.
  - Fields the HTTP format can't express are copied from `original`. A non-raw body is left untouched.
  - Grammar quirks: a header with a one-letter name (`A: 1`) is parsed as a new request, and disabled headers arrive as `comment` nodes.
- `syntax/http-nvim.vim`: highlight groups for the panel (documented in the help file).
- `doc/http-nvim.txt`: the vim help file. Keep it in sync with keymaps and behavior; `doc/tags` is generated by `:helptags`.

Postman v2.1 shapes to handle: `request` may be a bare URL string (method defaults to GET), and `url` may be a string or `{ raw = ... }`. JSON is decoded with `luanil` for objects and arrays, so `null` fields disappear.

## Development

There is no build step, test suite, or linter config beyond `.luarc.json` (lua-language-server: LuaJIT runtime, `vim` global, strict table shapes). Runtime requirements: Neovim with the tree-sitter `http` parser (`:TSInstall http`) and nui.nvim.

Run the plugin locally:

```sh
nvim --cmd "set rtp+=." --cmd "set rtp+=/path/to/nui.nvim" test.http
```

To check behavior without a UI, write a Lua script and run it headless. Drive keymaps with `nvim_feedkeys(..., "x", false)`.

```sh
nvim --headless --cmd "set rtp+=. rtp+=/path/to/nui.nvim" -c "luafile script.lua" -c "qa!"
```

The test fixtures are `tests/collection.json` and `tests/env.json`, i.e. the collection `tests` with the repo root as `collection_dir`. Load them in a headless script with `require("http-nvim").setup({ collection_dir = vim.fn.getcwd() })` then `require("http-nvim.collections").select("tests")`. Saving rewrites them, so back them up before testing saves and restore them afterwards. To keep a headless test away from the real `stdpath("data")`, set `XDG_DATA_HOME` to a scratch folder and run with `--clean` (otherwise the user config reinstalls its plugins there), adding `~/.local/share/nvim/site` to `rtp` for the tree-sitter `http` parser and running `runtime plugin/http.lua` for the commands and keymaps. `*.http` files are gitignored, so scratch request files can live in the repo root.
