-- tests/test_md_autofm.lua
--
-- Minimal unit-tests for the pure-Lua helpers exported by md-autofm.
-- They do NOT require a running Neovim instance; run them with:
--
--   nvim --headless -u NONE -l tests/test_md_autofm.lua
--
-- Exit code 0 = all tests passed, 1 = at least one failure.

-- ---------------------------------------------------------------------------
-- Minimal test harness
-- ---------------------------------------------------------------------------

local pass_count = 0
local fail_count = 0

local function pass(msg)
  pass_count = pass_count + 1
  io.write("  PASS  " .. msg .. "\n")
end

local function fail(msg, extra)
  fail_count = fail_count + 1
  io.write("  FAIL  " .. msg .. (extra and ("  →  " .. extra) or "") .. "\n")
end

local function assert_true(cond, msg)
  if cond then pass(msg) else fail(msg, "expected true, got false") end
end

local function assert_false(cond, msg)
  if not cond then pass(msg) else fail(msg, "expected false, got true") end
end

local function assert_eq(got, want, msg)
  if got == want then
    pass(msg)
  else
    fail(msg, ("expected %q, got %q"):format(tostring(want), tostring(got)))
  end
end

local function assert_nil(v, msg)
  if v == nil then pass(msg) else fail(msg, "expected nil, got " .. tostring(v)) end
end

local function assert_not_nil(v, msg)
  if v ~= nil then pass(msg) else fail(msg, "expected non-nil") end
end

-- ---------------------------------------------------------------------------
-- Load the module (works when cwd is the repo root or when the lua/ dir is
-- on the package path, which `nvim -l` ensures).
-- ---------------------------------------------------------------------------

-- Make sure the lua/ subtree is on package.path when running outside Neovim.
local repo_root = debug.getinfo(1, "S").source:match("^@(.+)/tests/") or "."
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

-- Stub out vim.* used only at setup()-time so the pure helpers load cleanly.
if not vim then
  ---@diagnostic disable-next-line: lowercase-global
  vim = {
    tbl_deep_extend = function(_, t1, t2)
      local out = {}
      for k, v in pairs(t1) do out[k] = v end
      for k, v in pairs(t2) do out[k] = v end
      return out
    end,
    deepcopy = function(t)
      if type(t) ~= "table" then return t end
      local c = {}
      for k, v in pairs(t) do c[k] = vim.deepcopy(v) end
      return c
    end,
  }
end

local autofm = require("md-autofm")
local parse  = autofm._parse_frontmatter
local has_h1 = autofm._has_h1
local ts     = autofm._get_timestamp

-- ---------------------------------------------------------------------------
-- parse_frontmatter
-- ---------------------------------------------------------------------------

io.write("\n── parse_frontmatter ─────────────────────────────────────────────\n")

do -- empty buffer
  local r = parse({})
  assert_false(r.exists, "empty buffer → no frontmatter")
end

do -- buffer without opening ---
  local r = parse({ "# Hello", "some text" })
  assert_false(r.exists, "no opening --- → no frontmatter")
end

do -- opening --- but no closing ---
  local r = parse({ "---", "created_at: 2025-01-01 00:00:00" })
  assert_false(r.exists, "unclosed frontmatter → no frontmatter")
end

do -- minimal valid frontmatter
  local lines = { "---", "created_at: 2025-01-01 00:00:00", "---" }
  local r = parse(lines)
  assert_true(r.exists, "minimal frontmatter detected")
  assert_eq(r.fm_start, 1, "fm_start = 1")
  assert_eq(r.fm_end, 3, "fm_end = 3")
  assert_eq(r.keys["created_at"], 2, "created_at at line 2")
  assert_nil(r.keys["modified_at"], "modified_at absent")
end

do -- full frontmatter with both keys
  local lines = {
    "---",
    "created_at: 2025-01-01 00:00:00",
    "modified_at: 2025-06-15 10:30:00",
    "tags: [neovim, lua]",
    "---",
    "",
    "# My Note",
  }
  local r = parse(lines)
  assert_true(r.exists, "full frontmatter detected")
  assert_eq(r.fm_end, 5, "fm_end = 5")
  assert_eq(r.keys["created_at"], 2, "created_at at line 2")
  assert_eq(r.keys["modified_at"], 3, "modified_at at line 3")
  assert_eq(r.keys["tags"], 4, "extra key 'tags' at line 4")
end

do -- frontmatter not at start → ignored
  local lines = {
    "some prose",
    "---",
    "created_at: 2025-01-01 00:00:00",
    "---",
  }
  local r = parse(lines)
  assert_false(r.exists, "frontmatter not at line 1 → ignored")
end

do -- key with hyphen in name (e.g. custom keys)
  local lines = { "---", "my-key: value", "---" }
  local r = parse(lines)
  assert_true(r.exists, "key with hyphen parsed")
  assert_not_nil(r.keys["my-key"], "my-key recognised")
end

-- ---------------------------------------------------------------------------
-- has_h1
-- ---------------------------------------------------------------------------

io.write("\n── has_h1 ────────────────────────────────────────────────────────\n")

assert_false(has_h1({}), "empty → no H1")
assert_false(has_h1({ "## H2", "### H3" }), "H2/H3 → no H1")
assert_true(has_h1({ "# Title" }), "bare H1 detected")
assert_true(has_h1({ "## H2", "# Title", "body" }), "H1 anywhere detected")
assert_false(has_h1({ "#notah1" }), "no space after # → not H1")
assert_true(has_h1({ "#" }), "lone # counts as H1")

-- ---------------------------------------------------------------------------
-- get_timestamp
-- ---------------------------------------------------------------------------

io.write("\n── get_timestamp ─────────────────────────────────────────────────\n")

do
  local t = ts("iso8601")
  assert_true(t:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil,
    "iso8601 format matches YYYY-MM-DD HH:MM:SS")
end

do
  local custom = function() return "custom-ts" end
  assert_eq(ts(custom), "custom-ts", "custom function used as date_format")
end

-- ---------------------------------------------------------------------------
-- Idempotency simulation (pure-Lua, no nvim_buf_set_lines)
-- ---------------------------------------------------------------------------
-- We simulate the "no-frontmatter" path manually by checking that a second
-- parse on the lines produced by the first insertion returns the same result.

io.write("\n── idempotency (parse level) ─────────────────────────────────────\n")

do
  -- Simulate what ensure_frontmatter would insert for an empty file.
  local now = ts("iso8601")
  local inserted = {
    "---",
    "created_at: " .. now,
    "modified_at: " .. now,
    "---",
    "",
    "# myfile",
    "",
  }
  local r1 = parse(inserted)
  assert_true(r1.exists, "idempotency: frontmatter detected after first insert")
  assert_not_nil(r1.keys["created_at"], "idempotency: created_at present")
  assert_not_nil(r1.keys["modified_at"], "idempotency: modified_at present")
  assert_true(has_h1(inserted), "idempotency: H1 present")

  -- A second ensure would see fm.exists==true, both keys present, H1 present
  -- → no mutations.  Verify parse result is identical.
  local r2 = parse(inserted)
  assert_eq(r2.fm_end, r1.fm_end, "idempotency: fm_end stable on 2nd parse")
  assert_eq(r2.keys["created_at"], r1.keys["created_at"],
    "idempotency: created_at line stable")
  assert_eq(r2.keys["modified_at"], r1.keys["modified_at"],
    "idempotency: modified_at line stable")
end

-- ---------------------------------------------------------------------------
-- Edge case: frontmatter with extra keys → preserved (line numbers stable)
-- ---------------------------------------------------------------------------

io.write("\n── extra keys preserved ──────────────────────────────────────────\n")

do
  local lines = {
    "---",
    "title: My Document",
    "tags: [a, b]",
    "---",
    "",
    "# My Document",
  }
  local r = parse(lines)
  assert_true(r.exists, "extra-keys file: frontmatter found")
  assert_nil(r.keys["created_at"], "created_at missing (to be inserted)")
  assert_nil(r.keys["modified_at"], "modified_at missing (to be inserted)")
  assert_not_nil(r.keys["title"], "title key preserved")
  assert_not_nil(r.keys["tags"], "tags key preserved")
end

-- ---------------------------------------------------------------------------
-- H1 not duplicated when file already has one but no frontmatter
-- ---------------------------------------------------------------------------

io.write("\n── no-frontmatter + existing H1 ─────────────────────────────────\n")

do
  -- File with an H1 but no frontmatter.  After the plugin inserts frontmatter
  -- it must NOT also insert another H1 (ensure_h1 + has_h1 guard).
  local original = { "# My Note", "", "Some content." }
  assert_true(has_h1(original), "pre-condition: H1 already present")
  assert_false(parse(original).exists, "pre-condition: no frontmatter yet")

  -- Simulate what ensure_frontmatter would prepend (no H1 appended because
  -- has_h1(original) is true).
  local now = ts("iso8601")
  local prepended = {
    "---",
    "created_at: " .. now,
    "modified_at: " .. now,
    "---",
    "",
  }
  for _, l in ipairs(original) do
    table.insert(prepended, l)
  end

  local count = 0
  for _, l in ipairs(prepended) do
    if l:match("^# ") or l == "#" then
      count = count + 1
    end
  end
  assert_eq(count, 1, "exactly one H1 after frontmatter insertion")
  assert_true(parse(prepended).exists, "frontmatter present after insertion")
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

io.write(("\n%d passed, %d failed\n"):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
else
  os.exit(0)
end
