local util = {}

local tl = require("tl")
local assert = require("luassert")
local lfs = require("lfs")
local current_dir = assert(lfs.currentdir(), "unable to get current dir")
local tl_executable = current_dir .. "/tl"

local t_unpack = unpack or table.unpack

util.tl_executable = tl_executable

function util.do_in(dir, func, ...)
   local cdir = assert(lfs.currentdir())
   assert(lfs.chdir(dir))
   local res = {pcall(func, ...)}
   assert(lfs.chdir(cdir))
   if not table.remove(res, 1) then
      error(res[1], 2)
   end
   return t_unpack(res)
end

function util.mock_io(finally, files)
   assert(type(finally) == "function")
   assert(type(files) == "table")

   local io_open = io.open
   finally(function() io.open = io_open end)
   io.open = function (filename, mode)
      local basename = string.match(filename, "([^/]+)$")
      if files[basename] then
         -- Return a stub file handle
         return {
            read = function (_, format)
               if format == "*a" then
                  return files[basename]     -- Return fake bar.tl content
               else
                  error("Not implemented!")  -- Implement other modes if needed
               end
            end,
            close = function () end,
         }
      else
         return io_open(filename, mode)
      end
   end
end

local function unindent(code)
   assert(type(code) == "string")

   return code:gsub("[ \t]+", " "):gsub("\n[ \t]+", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
end

local function indent(str)
   assert(type(str) == "string")
   return (str:gsub("\n", "\n   "))
end

local function batch_assertions()
   return {
      add = function(self, assert_func, ...)
         table.insert(self, { fn = assert_func, nargs = select("#", ...), args = {...} })
         return self
      end,
      assert = function(self)
         local err_batch = { }
         local passed = true
         for _, assertion in ipairs(self) do
            local ok, err = pcall(assertion.fn, t_unpack(assertion.args, 1, assertion.nargs))
            if not ok then
               passed = false
               table.insert(err_batch, indent(tostring(err)))
            end
         end
         assert(passed, "batch assertion failed:\n   " .. indent(table.concat(err_batch, "\n\n")))
      end,
   }
end

function util.assert_line_by_line(s1, s2)
   assert(type(s1) == "string")
   assert(type(s2) == "string")

   s1 = unindent(s1)
   s2 = unindent(s2)
   local l1 = {}
   for l in s1:gmatch("[^\n]*") do
      table.insert(l1, l)
   end
   local l2 = {}
   for l in s2:gmatch("[^\n]*") do
      table.insert(l2, l)
   end
   local batch = batch_assertions()
   for i in ipairs(l1) do
      batch:add(assert.same, l1[i], l2[i], "mismatch at line " .. i .. ":")
   end
   batch:assert()
end

local valid_commands = {
   gen = true,
   check = true,
   run = true,
   build = true,
}
function util.tl_cmd(name, ...)
   assert(name, "no command provided")
   assert(valid_commands[name], "not a valid command: tl " .. tostring(name))

   local cmd = {
      tl_executable,
      name
   }
   for i = 1, select("#", ...) do
      table.insert(cmd, string.format("%q", (select(i, ...))))
   end
   return table.concat(cmd, " ") .. " "
end

function util.chdir_setup()
   assert(lfs.chdir("/tmp"))
end

function util.chdir_teardown()
   assert(lfs.chdir(current_dir))
end

local tmp_files = 0
function util.write_tmp_file(finally, content, ext)
   if not ext then ext = "tl" end
   assert(type(finally) == "function")
   assert(type(content) == "string")

   tmp_files = tmp_files + 1
   local full_name = "/tmp/teal_tmp_file" .. tostring(tmp_files) .. "." .. ext

   local fd = assert(io.open(full_name, "w"))
   fd:write(content)
   fd:close()
   finally(function()
      os.remove(full_name)
   end)
   return full_name
end

function util.write_tmp_dir(finally, dir_structure)
   assert(type(finally) == "function")
   assert(type(dir_structure) == "table")

   tmp_files = tmp_files + 1
   local full_name = "/tmp/teal_tmp_dir" .. tostring(tmp_files) .. "/"
   assert(lfs.mkdir(full_name))
   local function traverse_dir(dir_structure, prefix)
      prefix = prefix or full_name
      for name, content in pairs(dir_structure) do
         if type(content) == "table" then
            assert(lfs.mkdir(prefix .. name))
            traverse_dir(content, prefix .. name .. "/")
         else
            local fd = io.open(prefix .. name, "w")
            fd:write(content)
            fd:close()
         end
      end
   end
   traverse_dir(dir_structure)
   finally(function()
      os.execute("rm -r " .. full_name)
      -- local function rm_dir(dir_structure, prefix)
      --    prefix = prefix or full_name
      --    for name, content in pairs(dir_structure) do
      --       if type(content) == "table" then
      --          rm_dir(prefix .. name .. "/")
      --       end
      --       os.remove(prefix .. name)
      --    end
      -- end
      -- rm_dir(dir_structure)
   end)
   return full_name
end

function util.get_dir_structure(dir_name)
   -- basically run `tree` and put it into a table
   local dir_structure = {}
   for fname in lfs.dir(dir_name) do
      if fname ~= ".." and fname ~= "." then
         if lfs.attributes(dir_name .. "/" .. fname, "mode") == "directory" then
            dir_structure[fname] = util.get_dir_structure(dir_name .. "/" .. fname)
         else
            dir_structure[fname] = true
         end
      end
   end
   return dir_structure
end

local function insert_into(tab, files)
   for k, v in pairs(files) do
      if type(k) == "number" then
         tab[v] = true
      elseif type(v) == "string" then
         tab[k] = true
      elseif type(v) == "table" then
         if not tab[k] then
            tab[k] = {}
         end
         insert_into(tab[k], v)
      end
   end
end

function util.run_mock_project(finally, t)
   assert(type(finally) == "function")
   assert(type(t) == "table")
   assert(type(t.cmd) == "string", "tl <cmd> not given")
   assert(valid_commands[t.cmd], "Invalid command tl " .. t.cmd)

   local actual_dir_name = util.write_tmp_dir(finally, t.dir_structure)
   local expected_dir_structure
   if t.generated_files then
      expected_dir_structure = {}
      insert_into(expected_dir_structure, t.dir_structure)
      insert_into(expected_dir_structure, t.generated_files)
   end

   local pd, actual_output, actual_dir_structure
   util.do_in(actual_dir_name, function()
      local cmd = util.tl_cmd(t.cmd, t_unpack(t.args or {})) .. "2>&1"
      pd = assert(io.popen(cmd, "r"))
      actual_output = pd:read("*a")
      if expected_dir_structure then
         actual_dir_structure = util.get_dir_structure(".")
      end
   end)

   local batch = batch_assertions()
   if t.popen then
      batch:add(util.assert_popen_close,
         t.popen.status,
         t.popen.exit,
         t.popen.code,
         pd:close()
      )
   end
   if t.cmd_output then
      batch:add(assert.are.equal, t.cmd_output, actual_output)
   end
   if expected_dir_structure then
      batch:add(assert.are.same, expected_dir_structure, actual_dir_structure, "Actual directory structure is not as expected")
   end
   batch:assert()
end

function util.read_file(name)
   assert(type(name) == "string")

   local fd = assert(io.open(name, "r"))
   local output = fd:read("*a")
   fd:close()
   return output
end

function util.assert_popen_close(want1, want2, want3, ret1, ret2, ret3)
   assert(want1 == nil or type(want1) == "boolean")
   assert(type(want2) == "string")
   assert(type(want3) == "number")

   if _VERSION == "Lua 5.3" then
      batch_assertions()
         :add(assert.same, want1, ret1)
         :add(assert.same, want2, ret2)
         :add(assert.same, want3, ret3)
         :assert()
   end
end

local function check(lax, code, unknowns)
   return function()
      local tokens = tl.lex(code)
      local syntax_errors = {}
      local _, ast = tl.parse_program(tokens, syntax_errors)
      assert.same({}, syntax_errors, "Code was not expected to have syntax errors")
      local batch = batch_assertions()
      local errors, unks = tl.type_check(ast, { filename = "foo.lua", lax = lax })
      batch:add(assert.same, {}, errors)
      if unknowns then
         assert.same(#unknowns, #unks, "Expected same number of unknowns:")
         for i, u in ipairs(unknowns) do
            local got = unks[i] or {}
            if u.y then
               batch:add(assert.same, u.y, got.y)
            end
            if u.x then
               batch:add(assert.same, u.x, got.x)
            end
            if u.msg then
               batch:add(assert.same, u.msg, got.msg or "")
            end
            if u.filename then
               batch:add(assert.same, u.filename, got.filename or "")
            end
         end
      end
      batch:assert()
      return true, ast
   end
end

local function check_type_error(lax, code, type_errors)
   return function()
      local tokens = tl.lex(code)
      local syntax_errors = {}
      local _, ast = tl.parse_program(tokens, syntax_errors)
      assert.same({}, syntax_errors, "Code was not expected to have syntax errors")
      local batch = batch_assertions()
      local errors = tl.type_check(ast, { filename = "foo.tl", lax = lax })
      batch:add(assert.same, #type_errors, #errors, "Expected same number of errors:")
      for i, err in ipairs(type_errors) do
         local got = errors[i] or {}
         if err.y then
            batch:add(assert.same, err.y, got.y,  "[" .. i .. "] Expected same y location:")
         end
         if err.x then
            batch:add(assert.same, err.x, got.x,  "[" .. i .. "] Expected same x location:")
         end
         if err.msg then
            batch:add(assert.match, err.msg, got.msg or "", 1, true,  "[" .. i .. "] Expected messages to match:")
         end
         if err.filename then
            batch:add(assert.match, err.filename, got.filename or "", 1, true,  "[" .. i .. "] Expected filenames to match:")
         end
      end
      batch:assert()
   end
end

function util.check(code)
   assert(type(code) == "string")

   return check(false, code)
end

function util.lax_check(code, unknowns)
   assert(type(code) == "string")
   assert(type(unknowns) == "table")

   return check(true, code, unknowns)
end

function util.strict_and_lax_check(code, unknowns)
   assert(type(code) == "string")
   assert(type(unknowns) == "table")

   return check(true, code)
      and check(false, code, unknowns)
end

function util.check_type_error(code, type_errors)
   assert(type(code) == "string")
   assert(type(type_errors) == "table")

   return check_type_error(false, code, type_errors)
end

function util.strict_check_type_error(code, type_errors, unknowns)
   assert(type(code) == "string")
   assert(type(type_errors) == "table")
   assert(type(unknowns) == "table")

   -- fails in strict
   local ok = check_type_error(false, code, type_errors)
   if not ok then
      return
   end
   -- passes in lax
   return check(true, code, unknowns)
end

function util.lax_check_type_error(code, type_errors)
   assert(type(code) == "string")
   assert(type(type_errors) == "table")

   return check_type_error(true, code, type_errors)
end

function util.check_syntax_error(code, syntax_errors)
   assert(type(code) == "string")
   assert(type(syntax_errors) == "table")

   return function()
      local tokens = tl.lex(code)
      local errors = {}
      tl.parse_program(tokens, errors)
      local batch = batch_assertions()
      batch:add(assert.same, #syntax_errors, #errors, "Expected same amount of syntax errors:")
      for i, err in ipairs(syntax_errors) do
         local got = errors[i] or {}
         if err.y then
            batch:add(assert.same, err.y, got.y, "[" .. i .. "] Expected same y location:")
         end
         if err.x then
            batch:add(assert.same, err.x, got.x,  "[" .. i .. "] Expected same x location:")
         end
         if err.msg then
            batch:add(assert.match, err.msg, got.msg or "", 1, true,  "[" .. i .. "] Expected messages to match:")
         end
         if err.filename then
            batch:add(assert.match, err.filename, got.filename or "", 1, true,  "[" .. i .. "] Expected filenames to match:")
         end
      end
      batch:assert()
   end
end

function util.check_warnings(code, warnings)
   assert(type(code) == "string")
   assert(type(warnings) == "table")

   return function()
      local result = tl.process_string(code)
      local batch = batch_assertions()
      batch:add(assert.same, #warnings, #result.warnings, "Expected same amount of warnings:")
      for i, warning in ipairs(warnings) do
         local got = result.warnings[i] or {}
         if warning.y then
            batch:add(assert.same, warning.y, got.y, "[" .. i .. "] Expected same y location:")
         end
         if warning.x then
            batch:add(assert.same, warning.x, got.x,  "[" .. i .. "] Expected same x location:")
         end
         if warning.msg then
            batch:add(assert.match, warning.msg, got.msg or "", 1, true,  "[" .. i .. "] Expected messages to match:")
         end
         if warning.filename then
            batch:add(assert.match, warning.filename, got.filename or "", 1, true,  "[" .. i .. "] Expected filenames to match:")
         end
      end
      batch:assert()
   end
end

local function gen(lax, code, expected)
   return function()
      local tokens = tl.lex(code)
      local syntax_errors = {}
      local _, ast = tl.parse_program(tokens, syntax_errors)
      assert.same({}, syntax_errors, "Code was not expected to have syntax errors")
      local errors, unks = tl.type_check(ast, { filename = "foo.tl", lax = lax })
      assert.same({}, errors)
      local output_code = tl.pretty_print_ast(ast)

      local expected_tokens = tl.lex(expected)
      local _, expected_ast = tl.parse_program(expected_tokens, {})
      local expected_code = tl.pretty_print_ast(expected_ast)

      assert.same(expected_code, output_code)
   end
end

function util.gen(code, expected)
   assert(type(code) == "string")
   assert(type(expected) == "string")

   return gen(false, code, expected)
end

return util
