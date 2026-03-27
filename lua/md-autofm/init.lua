---@mod md-autofm Automatic YAML frontmatter management for Markdown files.
---
--- On open  (BufReadPost / BufNewFile):
---   * Inserts a YAML frontmatter block at the top when none is present.
---   * Adds missing `created_at` / `modified_at` keys to an existing block.
---   * `created_at` is NEVER overwritten once set.
---   * `modified_at` is only written when the key is absent on open.
---   * Optionally inserts an H1 header (# <filename>) after the frontmatter.
---
--- On save (BufWritePre):
---   * Updates `modified_at` only when the buffer was genuinely changed by the
---     user since the last open/save.  No change → no touch → no save-loop.

local M = {}

--- Default configuration (merged with user opts in setup()).
M.config = {
  --- Key names used inside the YAML frontmatter.
  keys = {
    created_at = "created_at",
    modified_at = "modified_at",
  },
  --- Update `modified_at` before writing the buffer.
  update_on_save = true,
  --- Insert `# <filename>` after the frontmatter when no H1 exists.
  ensure_h1 = true,
  --- Insert a blank line between the closing `---` and the H1 (or content).
  insert_blank_line_after_frontmatter = true,
  --- Timestamp format.  "iso8601" → "YYYY-MM-DD HH:MM:SS" (local time).
  --- Alternatively supply a function() → string.
  date_format = "iso8601",
  --- File patterns that trigger the plugin.
  only_for_patterns = { "*.md" },
}

-- Per-buffer changedtick snapshot taken after our own modifications.
-- Used to distinguish user edits from our own programmatic edits.
local _buf_ticks = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Return a formatted timestamp string.
---@param fmt string|function
---@return string
local function get_timestamp(fmt)
  if type(fmt) == "function" then
    return fmt()
  end
  -- "iso8601" (and any other string value) → local time with space separator
  return os.date("%Y-%m-%d %H:%M:%S")
end

--- Parse YAML frontmatter from a list of buffer lines (1-indexed Lua table).
---
--- A valid frontmatter block must start on the very first line with `---`
--- and have a closing `---` somewhere further down.
---
---@param lines string[]  Lines as returned by nvim_buf_get_lines.
---@return table  {
---   exists   = bool,
---   fm_start = int,          -- 1-indexed line of the opening "---"
---   fm_end   = int,          -- 1-indexed line of the closing "---"
---   keys     = table<string,int>, -- key name → 1-indexed line number
--- }
local function parse_frontmatter(lines)
  if #lines == 0 or lines[1] ~= "---" then
    return { exists = false }
  end

  local fm_end = nil
  for i = 2, #lines do
    if lines[i] == "---" then
      fm_end = i
      break
    end
  end

  if not fm_end then
    return { exists = false }
  end

  local keys = {}
  for i = 2, fm_end - 1 do
    -- Match "key:" or "key :" at start of line; ignore list items, comments, etc.
    local k = lines[i]:match("^([%w_%-]+)%s*:")
    if k then
      keys[k] = i -- 1-indexed
    end
  end

  return {
    exists = true,
    fm_start = 1,
    fm_end = fm_end,
    keys = keys,
  }
end

--- Return true when any line matches a bare H1 (`# ...`).
---@param lines string[]
---@return boolean
local function has_h1(lines)
  for _, line in ipairs(lines) do
    if line:match("^# ") or line == "#" then
      return true
    end
  end
  return false
end

--- Basename without extension for the buffer's file.
---@param bufnr integer
---@return string
local function get_filename(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return vim.fn.fnamemodify(name, ":t:r")
end

-- ---------------------------------------------------------------------------
-- Core operations
-- ---------------------------------------------------------------------------

--- Ensure the buffer has a valid frontmatter block and (optionally) an H1.
--- All mutations are idempotent: repeated calls produce the same result.
---@param bufnr  integer
---@param config table   Resolved plugin config.
local function ensure_frontmatter(bufnr, config)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  if buf_name == "" then
    return -- unnamed/scratch buffer
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local now = get_timestamp(config.date_format)
  local created_key = config.keys.created_at
  local modified_key = config.keys.modified_at

  local fm = parse_frontmatter(lines)

  if not fm.exists then
    -- ── No frontmatter at all: prepend a complete block ─────────────────────
    local filename = get_filename(bufnr)
    local new_lines = {
      "---",
      created_key .. ": " .. now,
      modified_key .. ": " .. now,
      "---",
    }
    if config.insert_blank_line_after_frontmatter then
      table.insert(new_lines, "")
    end
    if config.ensure_h1 then
      table.insert(new_lines, "# " .. filename)
    end
    -- nvim_buf_set_lines: (bufnr, start, end, strict, lines)
    -- start==end → pure insert (no deletion).  start=0 → before first line.
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, new_lines)
  else
    -- ── Frontmatter exists: fill in missing keys ─────────────────────────────
    --
    -- We process modified_at first so that, if both keys are missing,
    -- created_at ends up on the line immediately after the opening "---"
    -- (because inserting at fm_start shifts modified_at down).
    --
    -- All insertions use the nvim 0-indexed API.
    -- Lua 1-indexed line N  →  nvim 0-indexed start=N (insert *before* line N,
    -- i.e. immediately *after* line N-1, i.e. *after* the 1-indexed line N-1).
    -- To insert right after the opening "---" (1-indexed line 1):
    --   start = fm_start = 1  (nvim inserts before 0-indexed line 1 = after 0-indexed line 0)

    if not fm.keys[modified_key] then
      vim.api.nvim_buf_set_lines(bufnr, fm.fm_start, fm.fm_start, false, {
        modified_key .. ": " .. now,
      })
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      fm = parse_frontmatter(lines)
    end

    if not fm.keys[created_key] then
      vim.api.nvim_buf_set_lines(bufnr, fm.fm_start, fm.fm_start, false, {
        created_key .. ": " .. now,
      })
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      fm = parse_frontmatter(lines)
    end

    -- ── Ensure H1 after frontmatter ──────────────────────────────────────────
    if config.ensure_h1 and not has_h1(lines) then
      local filename = get_filename(bufnr)
      local insert_lines = {}

      -- Optionally add a blank separator between the closing "---" and the H1.
      -- Only add when the line immediately after the closing "---" is not
      -- already blank (avoids duplicate blank lines on repeated opens).
      local after_fm = lines[fm.fm_end + 1] -- may be nil
      if config.insert_blank_line_after_frontmatter and after_fm ~= "" then
        table.insert(insert_lines, "")
      end
      table.insert(insert_lines, "# " .. filename)

      -- Insert right after the closing "---".
      -- Lua 1-indexed fm.fm_end → nvim 0-indexed start = fm.fm_end
      vim.api.nvim_buf_set_lines(bufnr, fm.fm_end, fm.fm_end, false, insert_lines)
    end
  end

  -- Snapshot changedtick *after* our own modifications so that
  -- update_modified_at can later distinguish user edits from our edits.
  _buf_ticks[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
end

--- Update the `modified_at` field in the frontmatter before the buffer is
--- written.  Only acts when the buffer has genuine user edits (changedtick
--- moved past our last snapshot).
---@param bufnr  integer
---@param config table
local function update_modified_at(bufnr, config)
  local current_tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local snapshot_tick = _buf_ticks[bufnr]

  -- No snapshot yet, or buffer hasn't been changed since last snapshot → skip.
  if snapshot_tick and current_tick <= snapshot_tick then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local fm = parse_frontmatter(lines)
  if not fm.exists then
    return
  end

  local modified_key = config.keys.modified_at
  local key_line = fm.keys[modified_key]
  if not key_line then
    return -- key absent; nothing to update
  end

  local now = get_timestamp(config.date_format)
  -- Replace line key_line (1-indexed) in-place.
  -- nvim 0-indexed: replace range [key_line-1, key_line).
  vim.api.nvim_buf_set_lines(bufnr, key_line - 1, key_line, false, {
    modified_key .. ": " .. now,
  })

  -- Re-snapshot so a subsequent save without further user edits is a no-op.
  _buf_ticks[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Set up the plugin with optional configuration overrides.
---
---@param opts table|nil  Partial config table; merged onto the defaults.
function M.setup(opts)
  opts = opts or {}
  -- Deep-merge opts onto a copy of the defaults so M.config stays pristine.
  local config = vim.tbl_deep_extend("force", vim.deepcopy(M.config), opts)

  local group = vim.api.nvim_create_augroup("MdAutofm", { clear = true })
  local patterns = config.only_for_patterns

  -- Trigger on both BufReadPost (existing files opened from explorer / shell)
  -- and BufNewFile (brand-new files created inside Neovim).
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = patterns,
    callback = function(ev)
      ensure_frontmatter(ev.buf, config)
    end,
  })

  if config.update_on_save then
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      pattern = patterns,
      callback = function(ev)
        update_modified_at(ev.buf, config)
      end,
    })
  end
end

-- Expose internals so tests can reach them without a running Neovim instance.
M._parse_frontmatter = parse_frontmatter
M._get_timestamp = get_timestamp
M._has_h1 = has_h1

return M
