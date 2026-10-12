if exists("b:current_syntax")
  finish
endif

syn sync fromstart
syn spell notoplevel

" Header lines:  "Help: g?", later e.g. "Env: dev", "File: api.http"
syn match httpNvimHeader     /^[A-Z][a-z][^:]*:/
syn match httpNvimHelpHeader /^Help:/ nextgroup=httpNvimHelpTag skipwhite
syn match httpNvimHelpTag    /\S\+/ contained

" Sections:  "Environment variables (2)", "Collection (3)" ... until blank line
syn region httpNvimSection start=/^\%(.*(\d\+)$\)\@=/ end=/^$/ contains=httpNvimHeading,httpNvimEntry,httpNvimFold,httpNvimItemCount,httpNvimMethod
syn match httpNvimHeading /^[A-Z][a-z][^:]*\ze (\d\+)$/ contained nextgroup=httpNvimCount skipwhite
syn match httpNvimCount   /(\d\+)/hs=s+1,he=e-1 contained

" Section entries:  "KEY = value"
syn match httpNvimEntry  /^\S\+\ze\s*=/ contained nextgroup=httpNvimEquals skipwhite
syn match httpNvimEquals /=/ contained nextgroup=httpNvimValue skipwhite
syn match httpNvimValue  /.*$/ contained

" Section items:  "(3) auth", nested as "  ▸ (1) profile"
syn match httpNvimFold      /^\s*\zs[▸▾]/ contained nextgroup=httpNvimFoldCount skipwhite
syn match httpNvimItemCount /^\s*\zs(\d\+)/hs=s+1,he=e-1 contained nextgroup=httpNvimItem skipwhite
syn match httpNvimFoldCount /(\d\+)/hs=s+1,he=e-1 contained nextgroup=httpNvimItem skipwhite

" Requests:  "    GET list users"
syn match httpNvimMethod /^\s*\zs\%(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\)\ze\s\+[^=[:space:]]/ contained nextgroup=httpNvimRequest skipwhite
syn match httpNvimRequest /.*$/ contained
syn match httpNvimItem      /.*$/ contained

hi def link httpNvimHelpHeader httpNvimHeader
hi def link httpNvimHeader     Label
hi def link httpNvimHelpTag    Tag
hi def link httpNvimHeading    PreProc
hi def link httpNvimCount      Number
hi def link httpNvimEntry      Identifier
hi def link httpNvimEquals     Operator
hi def link httpNvimValue      String
hi def link httpNvimItemCount  httpNvimCount
hi def link httpNvimFoldCount  httpNvimItemCount
hi def link httpNvimItem       Directory
hi def link httpNvimFold       Special
hi def link httpNvimMethod     Keyword
hi def httpNvimCut gui=underline cterm=underline
hi def link httpNvimCopy httpNvimCut

let b:current_syntax = "http-nvim"
