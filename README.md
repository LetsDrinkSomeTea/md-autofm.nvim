# md-autofm.nvim

**md-autofm** is a lightweight Neovim plugin that automatically manages YAML
frontmatter and H1 headers in Markdown files.  Every operation is
**idempotent** – opening the same file many times always produces the same
result with no duplicates.

---

## Features

| What | When |
|---|---|
| Insert missing YAML frontmatter (`created_at`, `modified_at`) | On open |
| Add missing keys to an existing frontmatter block | On open |
| Never overwrite `created_at` once set | Always |
| Insert `# <filename>` H1 when none exists | On open |
| Update `modified_at` only when the buffer was genuinely edited | On save |

---

## Architecture

```
lua/md-autofm/
└── init.lua          ← all logic; exposes M.setup(opts)

plugin/md-autofm.lua  ← auto-sourced stub (no auto-setup; users call setup())

tests/
└── test_md_autofm.lua  ← pure-Lua unit tests (no Neovim required)
```

### Key design decisions

**Two autocommands, one augroup:**

* `BufReadPost` + `BufNewFile` on `*.md` → `ensure_frontmatter()`  
  Handles files opened from an external file manager as well as files
  created inside Neovim.
* `BufWritePre` on `*.md` → `update_modified_at()`

**Frontmatter parsing is line-based.**  
No external YAML parser is needed.  The parser only needs to locate
`--- … ---` blocks and key-value lines; complex YAML is left untouched.

**`nvim_buf_set_lines` for all mutations.**  
Changes are limited to the exact lines being added or replaced; the rest of
the document is never touched.

---

## Why idempotent / why no save-loops

### Idempotency on open

`ensure_frontmatter` always reads the current buffer before acting:

1. If frontmatter exists **and** has both `created_at` / `modified_at` **and**
   an H1 is already present → **nothing is inserted**.
2. Only the missing pieces are added, one at a time.

Because every guard condition is checked from the current buffer state, running
`ensure_frontmatter` twice produces the same result as running it once.

### No save-loops on write

After `ensure_frontmatter` finishes, a **changedtick snapshot** is stored for
the buffer:

```
_buf_ticks[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
```

`update_modified_at` (called from `BufWritePre`) compares the current
`changedtick` against that snapshot.  If the tick has not advanced, it means
the user made no edits and `modified_at` is left alone.

When `update_modified_at` *does* rewrite the `modified_at` line, it
immediately refreshes the snapshot to the new tick.  The `BufWritePre` event
has already fired for this write cycle, so no recursive write is triggered.

---

## Installation

### lazy.nvim (recommended)

```lua
{
  "LetsDrinkSomeTea/md-autofm.nvim",
  ft = "markdown",   -- load only for Markdown files
  opts = {},         -- use defaults (calls setup({}) automatically with lazy)
}
```

Or with full custom options:

```lua
{
  "LetsDrinkSomeTea/md-autofm.nvim",
  ft = "markdown",
  config = function()
    require("md-autofm").setup({
      keys = {
        created_at  = "date",        -- use "date" instead of "created_at"
        modified_at = "lastmod",     -- use "lastmod" instead of "modified_at"
      },
      update_on_save = true,
      ensure_h1 = true,
      insert_blank_line_after_frontmatter = true,
      date_format = "iso8601",       -- or a function: function() return os.date(...) end
      only_for_patterns = { "*.md", "*.markdown" },
    })
  end,
}
```

### packer.nvim

```lua
use {
  "LetsDrinkSomeTea/md-autofm.nvim",
  config = function()
    require("md-autofm").setup()
  end,
}
```

### Manual / vim-plug

```vim
Plug 'LetsDrinkSomeTea/md-autofm.nvim'
```

Then in your `init.lua`:

```lua
require("md-autofm").setup()
```

---

## Configuration

`setup(opts)` accepts the following keys (all optional):

```lua
require("md-autofm").setup({
  -- Names of the frontmatter keys to manage.
  keys = {
    created_at  = "created_at",
    modified_at = "modified_at",
  },

  -- Update `modified_at` in BufWritePre when the buffer was edited.
  update_on_save = true,

  -- Insert `# <filename>` after the frontmatter when no H1 exists.
  ensure_h1 = true,

  -- Add a blank line between the closing "---" and the H1 / content.
  insert_blank_line_after_frontmatter = true,

  -- Timestamp format.
  --   "iso8601" → os.date("%Y-%m-%d %H:%M:%S")  (local time)
  --   function   → called with no args, must return a string.
  date_format = "iso8601",

  -- Glob patterns that activate the plugin.
  only_for_patterns = { "*.md" },
})
```

---

## Behaviour examples

### Empty file → full block inserted

```
(before)

(after)
---
created_at: 2026-03-27 14:06:00
modified_at: 2026-03-27 14:06:00
---

# my-note
```

### File with frontmatter, missing keys → only missing keys added

```
(before)            (after)
---                 ---
title: Draft        created_at: 2026-03-27 14:06:00
---                 modified_at: 2026-03-27 14:06:00
                    title: Draft
# Draft             ---
                    
                    # Draft
```

### File already complete → untouched

```
---
created_at: 2026-01-01 09:00:00
modified_at: 2026-03-20 17:45:00
---

# my-note

Content here…
```

Opening this file again changes nothing.

---

## Running the tests

The test suite only requires a standard Lua 5.4 interpreter (or LuaJIT) – no
Neovim is needed for the pure-helper tests:

```sh
lua5.4 tests/test_md_autofm.lua
```

Or with Neovim (headless):

```sh
nvim --headless -u NONE -l tests/test_md_autofm.lua
```

Expected output: all lines starting with `PASS`, exit code `0`.

Save-behavior regression test (requires headless Neovim):

```sh
nvim --headless -u NONE -l tests/test_save_behavior.lua
```

This verifies:

* `:w` without edits does **not** update `modified_at`
* `:w` after a real edit **does** update `modified_at`
* a second `:w` without further edits does **not** update it again

---

## License

MIT
