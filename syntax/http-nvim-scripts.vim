" Scripts buffers of the collection or a folder (`S` in the panel): a
" `< {% %}` and a `> {% %}` block of JavaScript, and `#` comments. The http
" tree-sitter grammar only reads a `> {% %}` block after a request, so this
" highlights both blocks instead.
if exists("b:current_syntax")
  finish
endif

syn include @httpNvimScriptsJs syntax/javascript.vim
unlet! b:current_syntax

syn match httpNvimScriptsComment /^\s*#.*$/
syn region httpNvimScriptsBlock matchgroup=httpNvimScriptsMarker start=/^\s*[<>]\s*{%/ end=/%}/ keepend contains=@httpNvimScriptsJs

hi def link httpNvimScriptsComment Comment
hi def link httpNvimScriptsMarker  PreProc

let b:current_syntax = "http-nvim-scripts"
