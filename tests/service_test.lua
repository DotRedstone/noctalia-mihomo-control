-- Run with Lua 5.4. No network or Noctalia process is needed.
local callbacks, commands, state, clock = {}, {}, {}, 100
local bodies = {
  version = { version = "test" }, config = { mode = "rule" },
  groups = { proxies = { { name = "Choice", type = "Selector", now = "A", all = { "A", "B" } } } },
  connections = { connections = { { id = "id-1", metadata = { host = "example.test" }, chains = { "Choice" } } } },
  delay = { A = 10, B = 20 }, traffic = { up = 10, down = 20 },
}
local host = {
  getConfig = function(key)
    local values = { controller_port = 9090, controller_secret = "", helper_path = "/helper",
      test_url = "https://example.test/204" }
    return values[key]
  end,
  fileExists = function(path) return path == "/helper" end,
  setUpdateInterval = function(ms) assert(ms == 2000) end,
  state = {
    set = function(key, value) state[key] = value end,
    get = function(key) return state[key] end,
    watch = function(key, fn) commands[key] = fn end,
  },
  string = { urlEncode = function(s) return s:gsub(" ", "%%20") end },
  json = { encode = function() return "body" end, decode = function(s) return bodies[s] end },
  http = function(req, cb)
    assert(req.url:match("^http://127%.0%.0%.1:9090/"), "non-loopback request")
    table.insert(callbacks, { req = req, cb = cb })
    return true
  end,
  httpStream = function(req, on_line)
    assert(req.url:match("/traffic$"))
    on_line("traffic")
    return { stop = function() end }
  end,
  runAsync = function(argv, cb)
    assert(argv[1] == "/helper")
    table.insert(callbacks, { argv = argv, cb = cb })
    return true
  end,
}
local env = setmetatable({ noctalia = host, os = { time = function() return clock end } }, { __index = _G })
assert(loadfile("mihomo-control/service.luau", "t", env))()

local function respond(path, body, status)
  for i, entry in ipairs(callbacks) do
    if entry.req and entry.req.url:find(path, 1, true) then
      table.remove(callbacks, i)
      entry.cb({ ok = true, status = status or 200, body = body or "" })
      return entry.req
    end
  end
  error("missing request " .. path)
end

local function helper(verb, stdout, exit)
  for i, entry in ipairs(callbacks) do
    if entry.argv and entry.argv[2] == verb then
      table.remove(callbacks, i)
      entry.cb({ stdout = stdout or "", exitCode = exit or 0, timedOut = false })
      return
    end
  end
  error("missing helper " .. verb)
end

local function respond_all(path, body)
  local found = true
  while found do
    found = false
    for _, entry in ipairs(callbacks) do
      if entry.req and entry.req.url:find(path, 1, true) then
        respond(path, body); found = true; break
      end
    end
  end
end

assert(state["nmc.snapshot"].status == "offline")
env.update()
respond("/version", "version")
respond_all("/configs", "config")
respond_all("/group", "groups")
respond_all("/connections", "connections")
assert(state["nmc.snapshot"].status == "running")
assert(state["nmc.snapshot"].down == 20)
assert(state["nmc.snapshot"].count == 1)

commands["nmc.command"]({ op = "mode", mode = "global" })
local request = respond("/configs", "", 204)
assert(request.method == "PATCH")
commands["nmc.command"]({ op = "select", group = "Choice", node = "B" })
request = respond("/proxies/Choice", "", 204)
assert(request.method == "PUT")
commands["nmc.command"]({ op = "select", group = "Choice", node = "bad" })
for _, entry in ipairs(callbacks) do assert(not (entry.req and entry.req.method == "PUT")) end
commands["nmc.command"]({ op = "close", id = "id-1" })
request = respond("/connections/id-1", "", 204)
assert(request.method == "DELETE")

commands["nmc.command"]({ op = "stop" })
assert(state["nmc.snapshot"].status == "stopping")
helper("stop")
helper("status", "stopped\n")
assert(state["nmc.snapshot"].status == "offline")
assert(not state["nmc.operation"].busy)
commands["nmc.command"]({ op = "start" })
helper("start")
respond("/version", "version")
respond_all("/configs", "config")
respond_all("/group", "groups")
respond_all("/connections", "connections")
assert(state["nmc.snapshot"].status == "running")
assert(not state["nmc.operation"].busy)

commands["nmc.command"]({ op = "delay_all" })
assert(#state["nmc.snapshot"].groups == 1, "missing groups after restart")
assert(state["nmc.operation"].busy, "delay operation not started")
respond("/group/Choice/delay", "delay")
assert(not state["nmc.operation"].busy)

commands["nmc.command"]({ op = "restart_core" })
for i, entry in ipairs(callbacks) do
  if entry.req and entry.req.url:find("/restart", 1, true) then
    table.remove(callbacks, i)
    entry.cb({ ok = false, status = 0, body = "" })
    break
  end
end
assert(state["nmc.snapshot"].status == "starting")
commands["nmc.command"]({ op = "refresh" })
respond("/version", "version")
assert(state["nmc.snapshot"].status == "running")

commands["nmc.command"]({ op = "refresh" })
respond("/version", "", 401)
assert(state["nmc.snapshot"].status == "error")
assert(state["nmc.snapshot"].error == "unauthorized")
assert(state["nmc.snapshot"].down == 0)
print("service: ok")
