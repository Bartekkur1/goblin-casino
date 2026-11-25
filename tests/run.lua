-- Runs every tests/test_*.lua with plain Lua 5.1 (the Lua WoW uses), from the repository root:
--   lua5.1 tests/run.lua            all tests
--   lua5.1 tests/run.lua reload     only tests whose name contains "reload"
-- Exits with 1 when a test fails. On GitHub Actions failures also become annotations.
package.path = "tests/?.lua;" .. package.path
math.randomseed(1)

local filter = arg and arg[1]
local onGitHub = os.getenv("GITHUB_ACTIONS") == "true"
local passed, failed = 0, {}

-- Test helpers (globals for the test files)
function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

function check(cond, what)
	if not cond then error(what or "check failed", 2) end
	return cond
end

-- Same content, whatever the table's insertion order (for comparing results between clients).
function serialize(v)
	if type(v) ~= "table" then return type(v) == "string" and string.format("%q", v) or tostring(v) end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. serialize(v[k]) end
	return "{" .. table.concat(parts, ",") .. "}"
end

local current
function test(name, fn)
	if filter and not name:lower():find(filter:lower(), 1, true) then return end
	local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
	if ok then
		passed = passed + 1
		print("  ok    " .. name)
	else
		failed[#failed + 1] = { file = current, name = name, err = err }
		print("  FAIL  " .. name)
		print("        " .. tostring(err):gsub("\n", "\n        "))
	end
end

local tests = {}
local list = io.popen("ls tests")
for file in list:lines() do
	if file:match("^test_.*%.lua$") then tests[#tests + 1] = file end
end
list:close()
table.sort(tests)

for _, file in ipairs(tests) do
	current = "tests/" .. file
	print(current)
	local chunk, err = loadfile(current)
	if not chunk then
		failed[#failed + 1] = { file = current, name = "load", err = err }
		print("  FAIL  can't load: " .. tostring(err))
	else
		local ok, loadErr = pcall(chunk)
		if not ok then
			failed[#failed + 1] = { file = current, name = "load", err = loadErr }
			print("  FAIL  " .. tostring(loadErr))
		end
	end
end

if passed == 0 and #failed == 0 then
	failed[#failed + 1] = { file = "tests/run.lua", name = "runner", err = "no tests were run" }
end
local summary = string.format("%d passed, %d failed", passed, #failed)
print("\n" .. summary)
if onGitHub then
	print("::notice title=Tests::" .. summary)
	local out = os.getenv("GITHUB_STEP_SUMMARY")
	local fh = out and io.open(out, "a")
	if fh then
		fh:write("### Tests: " .. summary .. "\n")
		for _, f in ipairs(failed) do fh:write("- " .. f.name .. "\n") end
		fh:close()
	end
	for _, f in ipairs(failed) do
		-- the first line of the failing test file in the traceback, else the file itself
		local line = tostring(f.err):match(f.file:gsub("%p", "%%%0") .. ":(%d+):") or "1"
		local msg = (f.name .. ": " .. tostring(f.err):match("^[^\n]*")):gsub("%%", "%%25"):gsub("\r", ""):gsub("\n", "%%0A")
		print(string.format("::error file=%s,line=%s::%s", f.file, line, msg))
	end
end
os.exit(#failed == 0 and 0 or 1)
