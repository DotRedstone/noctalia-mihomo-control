-- 配置适配器的本地 mock；不修改文件、网络或服务。
local state, watches, calls, now = {}, {}, {}, 100
local decode = {
  first = { profiles = { { id = "base", name = "Base" } }, active = "base" },
  imported = { id = "second" },
  second = { profiles = { { id = "base", name = "Base" },
    { id = "second", name = "Second" } }, active = "base" },
  switched = { id = "second" },
  switched_base = { id = "base" },
  active_second = { profiles = { { id = "base", name = "Base" },
    { id = "second", name = "Second" } }, active = "second" },
  malformed = { profiles = { { id = "../bad", name = "Bad" } }, active = "" },
}
local config = { controller_port = 9090, helper_path = "", profile_helper_path = "/profile-helper" }
local host = {
  getConfig = function(key) return config[key] end,
  fileExists = function(path) return path == "/profile-helper" end,
  setUpdateInterval = function() end,
  state = {
    set = function(key, value) state[key] = value end,
    watch = function(key, fn) watches[key] = fn end,
  },
  json = { decode = function(s) return decode[s] end, encode = function() return "{}" end },
  http = function(req, cb) table.insert(calls, { req = req, cb = cb }); return true end,
  httpStream = function() return { stop = function() end } end,
  runAsync = function(argv, cb, timeout)
    assert(argv[1] == "/profile-helper", "unexpected executable")
    table.insert(calls, { argv = argv, cb = cb, timeout = timeout })
    return true
  end,
}
local env = setmetatable({ noctalia = host, os = { time = function() return now end } }, { __index = _G })
assert(loadfile("mihomo-control/service.luau", "t", env))()

local function take(verb)
  for i, call in ipairs(calls) do
    if call.argv and call.argv[2] == verb then
      table.remove(calls, i)
      return call
    end
  end
  error("missing profile call " .. verb)
end
local function complete(verb, stdout, exit, timed_out)
  local call = take(verb)
  call.cb({ stdout = stdout or "", exitCode = exit or 0, timedOut = timed_out or false })
  return call
end
local function command(op, value)
  local item = { op = op }
  if op == "profile_import" then item.path = value else item.id = value end
  watches["nmc.command"](item)
end

assert(state["nmc.profiles"].available)
assert(complete("list", "first").timeout == 8000)
assert(state["nmc.profiles"].active == "base")
command("profile_import", "https://invalid.example/profile.yaml")
assert(state["nmc.profiles"].error == "profile_path_invalid")

local source = "/tmp/synthetic $(not-a-command).yaml"
command("profile_import", source)
local call = take("import")
assert(call.argv[3] == source and #call.argv == 3 and call.timeout == 60000)
call.cb({ exitCode = 65, stdout = "" })
assert(state["nmc.profiles"].error == "profile_invalid")
assert(state["nmc.profiles"].active == "base")

command("profile_import", source)
complete("import", "imported")
assert(state["nmc.profiles"].active == "base", "import activated a profile")
complete("list", "second")
assert(#state["nmc.profiles"].items == 2)
assert(state["nmc.profiles"].notice == "profile_imported")

command("profile_activate", "unknown")
for _, item in ipairs(calls) do assert(not (item.argv and item.argv[2] == "activate")) end
command("profile_activate", "second")
complete("activate", "", 75)
complete("list", "second")
assert(state["nmc.profiles"].active == "base")
assert(state["nmc.profiles"].error == "profile_rolled_back")

command("profile_activate", "second")
complete("activate", "switched")
assert(state["nmc.profiles"].active == "", "activation was trusted before list confirmation")
complete("list", "active_second")
assert(state["nmc.profiles"].notice == "profile_activated")
assert(state["nmc.profiles"].active == "second")

command("profile_activate", "base")
complete("activate", "switched_base")
complete("list", "active_second")
assert(state["nmc.profiles"].error == "profile_activation_unconfirmed")
assert(state["nmc.profiles"].active == "second")

command("profiles_refresh")
complete("list", "malformed")
assert(state["nmc.profiles"].error == "profile_invalid_response")
assert(state["nmc.profiles"].active == "second", "malformed list replaced last known state")

command("profile_import", source)
complete("import", "", 0, true)
assert(state["nmc.profiles"].error == "profile_timeout")
assert(state["nmc.profiles"].active == "second")

command("profile_activate", "base")
complete("activate", "", 76)
assert(state["nmc.profiles"].active == "", "rollback failure left a stale active label")
complete("list", "active_second")
assert(state["nmc.profiles"].error == "profile_rollback_failed")
assert(state["nmc.profiles"].active == "second")

command("profiles_refresh")
local late = take("list")
now = now + 11; env.update()
assert(state["nmc.profiles"].error == "profile_list_failed")
late.cb({ exitCode = 0, stdout = "first" })
assert(state["nmc.profiles"].active == "second", "late list replaced current state")
print("profiles: ok")
