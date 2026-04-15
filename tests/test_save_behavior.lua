-- tests/test_save_behavior.lua
--
-- Headless Neovim regression test for save behavior:
-- * open + :w without edits   -> modified_at unchanged
-- * open + edit + :w          -> modified_at updated
-- * second :w without edits   -> modified_at unchanged

local function die(msg)
  io.stderr:write("FAIL  " .. msg .. "\n")
  os.exit(1)
end

local function pass(msg)
  io.write("PASS  " .. msg .. "\n")
end

local repo_root = debug.getinfo(1, "S").source:match("^@(.+)/tests/") or "."
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local autofm = require("md-autofm")
local parse = autofm._parse_frontmatter

local tick = 0
autofm.setup({
  date_format = function()
    tick = tick + 1
    return ("stamp-%02d"):format(tick)
  end,
})

local md_path = vim.fn.tempname() .. ".md"
vim.fn.writefile({
  "---",
  "created_at: created-00",
  "modified_at: modified-initial",
  "---",
  "",
  "# my-note",
  "",
  "first line",
}, md_path)

local function read_modified_at(path)
  local lines = vim.fn.readfile(path)
  local fm = parse(lines)
  if not fm.exists then
    die("frontmatter missing in test file")
  end
  local idx = fm.keys["modified_at"]
  if not idx then
    die("modified_at key missing in test file")
  end
  local value = lines[idx]:match("^modified_at:%s*(.*)$")
  if not value then
    die("modified_at line has unexpected format: " .. lines[idx])
  end
  return value
end

local function edit(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

edit(md_path)
local first = read_modified_at(md_path)
if first ~= "modified-initial" then
  die("unexpected initial modified_at: " .. first)
end

-- no edits: move cursor and write
vim.cmd("normal! G")
vim.cmd("write")
local after_no_change_write = read_modified_at(md_path)
if after_no_change_write ~= first then
  die(("modified_at changed without edits (%s -> %s)"):format(first, after_no_change_write))
end
pass("open + :w without edits keeps modified_at")

-- edit and write
vim.api.nvim_buf_set_lines(0, -1, -1, false, { "second line" })
vim.cmd("write")
local after_edit_write = read_modified_at(md_path)
if after_edit_write == after_no_change_write then
  die("modified_at did not change after real edit + write")
end
pass("open + edit + :w updates modified_at")

-- no further edits: second write should keep value
vim.cmd("write")
local after_second_no_change_write = read_modified_at(md_path)
if after_second_no_change_write ~= after_edit_write then
  die(("modified_at changed on second no-op write (%s -> %s)")
    :format(after_edit_write, after_second_no_change_write))
end
pass("second :w without new edits keeps modified_at")

vim.cmd("bdelete!")
vim.fn.delete(md_path)

-- ---------------------------------------------------------------------------
-- Auto-skip: existing document with H1 but no frontmatter
-- ---------------------------------------------------------------------------
-- Opening such a file must NOT insert frontmatter automatically.

local h1_only_path = vim.fn.tempname() .. ".md"
vim.fn.writefile({
  "# My Existing Note",
  "",
  "Body text here.",
}, h1_only_path)

edit(h1_only_path)
local h1_lines_after_open = vim.fn.readfile(h1_only_path)
-- File is opened and BufReadPost fires, but since H1 is present and no
-- frontmatter exists, ensure_frontmatter must have returned early.
-- The file on disk has not changed (it hasn't been written yet), but we
-- can verify the buffer still has no frontmatter.
local h1_buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local h1_buf_fm = parse(h1_buf_lines)
if h1_buf_fm.exists then
  die("auto-skip failed: frontmatter was inserted into a doc that already had an H1")
end
pass("auto-skip: existing doc with H1 not modified on open")
vim.cmd("bdelete!")
vim.fn.delete(h1_only_path)

-- ---------------------------------------------------------------------------
-- :MdAutofmInsert command: force-inserts frontmatter even when H1 exists
-- ---------------------------------------------------------------------------

local force_path = vim.fn.tempname() .. ".md"
vim.fn.writefile({
  "# Force Insert Test",
  "",
  "Content here.",
}, force_path)

edit(force_path)
-- Verify auto-open did NOT insert frontmatter.
local force_buf_before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
if parse(force_buf_before).exists then
  die(":MdAutofmInsert pre-condition failed: frontmatter was auto-inserted")
end

-- Run the manual command and verify frontmatter is now present.
vim.cmd("MdAutofmInsert")
local force_buf_after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local force_fm = parse(force_buf_after)
if not force_fm.exists then
  die(":MdAutofmInsert did not insert frontmatter")
end
if not force_fm.keys["created_at"] then
  die(":MdAutofmInsert: created_at key missing after insert")
end
if not force_fm.keys["modified_at"] then
  die(":MdAutofmInsert: modified_at key missing after insert")
end
pass(":MdAutofmInsert force-inserts frontmatter into doc with existing H1")
vim.cmd("bdelete!")
vim.fn.delete(force_path)

io.write("save behavior regression test passed\n")
os.exit(0)
