-- The service is the only entry that talks to Mihomo or the optional helper.
-- Other entries exchange plain snapshots/commands through noctalia.state.
-- Requests carry a generation so late callbacks cannot resurrect stale state.
local snapshot = {
  status = "offline", error = "", mode = "", down = 0, up = 0,
  count = 0, groups = {}, connections = {}, helper = false, service_state = "unknown", version = "",
}
local operation = { busy = false, name = "", stage = "", remaining = 0, error = "" }
local generation, poll_tick, sequence = 0, 0, 0
local probe_token, helper_token = 0, 0
local probe_pending, helper_pending = false, false
local probe_started, helper_started = 0, 0
local traffic_stream = nil
local config = {}
local transition = nil
local transition_phase = nil
local transition_deadline = 0
local operation_started = 0
local operation_deadline = 0
local helper_state = "unknown"
local probe_suspended = false
local HELPER_TIMEOUT = 18
local API_READY_TIMEOUT = 180
local finish_operation

local function publish()
  noctalia.state.set("nmc.snapshot", snapshot)
end

local function publish_operation()
  noctalia.state.set("nmc.operation", operation)
end

local function number(value)
  return math.max(0, tonumber(value) or 0)
end

local function refresh_config()
  config.port = tonumber(noctalia.getConfig("controller_port")) or 9090
  config.secret = noctalia.getConfig("controller_secret") or ""
  config.helper = noctalia.getConfig("helper_path") or ""
  config.test_url = noctalia.getConfig("test_url") or "https://www.gstatic.com/generate_204"
  -- Refuse malformed credentials rather than putting CR/LF in an HTTP header.
  if string.find(config.secret, "[\r\n]") then config.secret = "" end
  snapshot.helper = string.sub(config.helper, 1, 1) == "/" and noctalia.fileExists(config.helper)
  helper_state = snapshot.helper and "unknown" or "absent"
  snapshot.service_state = helper_state
  probe_suspended = false
end

local function headers(json)
  local h = { "Accept: application/json" }
  if config.secret ~= "" then table.insert(h, "Authorization: Bearer " .. config.secret) end
  if json then table.insert(h, "Content-Type: application/json") end
  return h
end

local function request(method, path, body, callback)
  local port = config.port
  if port < 1 or port > 65535 then return false end
  local req = {
    url = "http://127.0.0.1:" .. tostring(port) .. path,
    method = method, headers = headers(body ~= nil), follow_redirects = false,
  }
  if body ~= nil then req.body = noctalia.json.encode(body) end
  return noctalia.http(req, callback)
end

local function ok(res)
  return res ~= nil and res.ok == true and res.status >= 200 and res.status < 300
end

local function decode(res)
  if not ok(res) then return nil end
  local data = noctalia.json.decode(res.body or "")
  if type(data) == "table" then return data end
  return nil
end

local function error_text(res)
  if res and res.status == 401 then return "unauthorized" end
  if res and res.status and res.status > 0 then return "HTTP " .. tostring(res.status) end
  return "unreachable"
end

local function clear_live()
  snapshot.mode, snapshot.down, snapshot.up, snapshot.count = "", 0, 0, 0
  snapshot.groups, snapshot.connections, snapshot.version = {}, {}, ""
  if traffic_stream then traffic_stream.stop(); traffic_stream = nil end
end

local function mark_offline(reason)
  clear_live()
  if transition_phase == "api" then
    -- A slow first boot is expected. Keep the wait visible without calling
    -- every failed probe an error until the overall readiness deadline.
    snapshot.status, snapshot.error = "starting", ""
  elseif helper_state == "stopped" then
    snapshot.status, snapshot.error = "offline", ""
  elseif helper_state == "unknown" then
    snapshot.status, snapshot.error = "offline", ""
  else
    snapshot.error = reason or "unreachable"
    snapshot.status = helper_state == "absent" and "offline" or "error"
  end
  publish()
end

local function start_traffic()
  if traffic_stream ~= nil then return end
  local current = generation
  local stream = noctalia.httpStream({
    url = "http://127.0.0.1:" .. tostring(config.port) .. "/traffic",
    headers = headers(false), follow_redirects = false,
  }, function(line)
    if current ~= generation then return end
    local data = noctalia.json.decode(line)
    if type(data) == "table" and data.up ~= nil and data.down ~= nil then
      snapshot.up, snapshot.down = number(data.up), number(data.down)
      publish()
    end
  end, function(_result)
    if current == generation then
      traffic_stream = nil
      snapshot.up, snapshot.down = 0, 0
      publish()
    end
  end)
  traffic_stream = stream
end

local function poll_details(current)
  request("GET", "/configs", nil, function(res)
    if current ~= generation then return end
    local data = decode(res)
    if data and type(data.mode) == "string" then snapshot.mode = string.lower(data.mode); publish() end
  end)
  request("GET", "/group", nil, function(res)
    if current ~= generation then return end
    local data = decode(res)
    if not data or type(data.proxies) ~= "table" then return end
    local groups = {}
    for _, group in ipairs(data.proxies) do
      if type(group.name) == "string" and type(group.all) == "table" then
        local members = {}
        for _, name in ipairs(group.all) do
          if type(name) == "string" then table.insert(members, name) end
        end
        table.insert(groups, { name = group.name, selected = group.now or "",
          kind = group.type or "", members = members, delays = {} })
      end
    end
    snapshot.groups = groups
    publish()
  end)
  request("GET", "/connections", nil, function(res)
    if current ~= generation then return end
    local data = decode(res)
    if not data then return end
    -- Mihomo may encode an empty collection as JSON null. Treat that as an
    -- empty list so a previous nonzero count cannot remain on screen.
    local raw = data.connections
    if raw == nil then raw = {} end
    if type(raw) ~= "table" then return end
    snapshot.count = #raw
    local connections = {}
    -- Keep shared-state messages and panel rendering bounded on busy cores.
    for i = 1, math.min(#raw, 40) do
      local item = raw[i]
      local meta = type(item.metadata) == "table" and item.metadata or {}
      if type(item.id) == "string" then
        table.insert(connections, { id = item.id,
          host = meta.host or meta.destinationIP or "", process = meta.process or "",
          chains = type(item.chains) == "table" and table.concat(item.chains, " / ") or "" })
      end
    end
    snapshot.connections = connections
    publish()
  end)
end

local function probe()
  if probe_pending or transition == "stop" or probe_suspended then return end
  if helper_state ~= "absent" and helper_state ~= "running" then return end
  probe_pending, probe_started = true, os.time()
  probe_token = probe_token + 1
  local current, token = generation, probe_token
  local accepted = request("GET", "/version", nil, function(res)
    if current ~= generation or token ~= probe_token then return end
    probe_pending = false
    local data = decode(res)
    if not data then mark_offline(error_text(res)); return end
    snapshot.version = tostring(data.version or "")
    snapshot.error = ""
    if transition_phase == "api" then
      transition, transition_phase = nil, nil
      if operation.busy then finish_operation() end
    end
    snapshot.status = "running"
    publish()
    start_traffic()
    poll_details(current)
  end)
  if not accepted then probe_pending = false; mark_offline("request rejected") end
end

local function helper_status()
  if not snapshot.helper or helper_pending or transition_phase == "service" or transition == "stop" then return end
  helper_pending, helper_started = true, os.time()
  helper_token = helper_token + 1
  local current, token = generation, helper_token
  local accepted = noctalia.runAsync({ config.helper, "status" }, function(result)
    if current ~= generation or token ~= helper_token then return end
    helper_pending = false
    if result.exitCode ~= 0 or result.timedOut then
      generation, probe_token = generation + 1, probe_token + 1
      probe_pending = false
      helper_state, snapshot.service_state = "error", "error"
      transition, transition_phase = nil, nil
      if operation.busy then finish_operation("helper status failed") end
      clear_live()
      snapshot.status, snapshot.error = "error", "helper status failed"
    else
      local status = (result.stdout or ""):match("^%s*(%a+)")
      if status == "stopped" then
        generation, probe_token = generation + 1, probe_token + 1
        probe_pending = false
        helper_state, snapshot.service_state = "stopped", "stopped"
        if transition_phase == "api" then
          transition, transition_phase = nil, nil
          finish_operation("service stopped before API ready")
        end
        clear_live(); snapshot.status, snapshot.error = "offline", ""
      elseif status == "running" then
        helper_state, snapshot.service_state = "running", "running"
        if transition_phase == "api" then
          snapshot.status = "starting"
        elseif snapshot.status ~= "running" then
          snapshot.status = "error"
          if not probe_suspended then snapshot.error = "unreachable" end
        end
        probe()
      else
        generation, probe_token = generation + 1, probe_token + 1
        probe_pending = false
        helper_state, snapshot.service_state = "error", "error"
        transition, transition_phase = nil, nil
        if operation.busy then finish_operation("invalid helper status") end
        clear_live()
        snapshot.status, snapshot.error = "error", "invalid helper status"
      end
    end
    publish()
  end, 8000)
  if not accepted then
    helper_pending = false
    generation, probe_token = generation + 1, probe_token + 1
    probe_pending = false
    helper_state, snapshot.service_state = "error", "error"
    transition, transition_phase = nil, nil
    if operation.busy then finish_operation("helper request rejected") end
    clear_live()
    snapshot.status, snapshot.error = "error", "helper request rejected"
    publish()
  end
end

finish_operation = function(err)
  operation = { busy = false, name = "", stage = "", remaining = 0, error = err or "" }
  operation_started, operation_deadline = 0, 0
  publish_operation()
end

local function lifecycle(verb)
  if not snapshot.helper then finish_operation("helper unavailable"); return end
  if operation.busy then return end
  generation = generation + 1
  sequence = sequence + 1
  probe_pending, helper_pending = false, false
  probe_suspended = false
  clear_live()
  operation_started = os.time()
  operation_deadline = operation_started + HELPER_TIMEOUT
  operation = { busy = true, name = verb, stage = "service", remaining = HELPER_TIMEOUT, error = "" }
  publish_operation()
  transition, transition_phase = verb, "service"
  transition_deadline = operation_deadline
  snapshot.status = verb == "stop" and "stopping" or "starting"
  snapshot.error = ""
  publish()
  local current, token = generation, sequence
  local accepted = noctalia.runAsync({ config.helper, verb }, function(result)
    if current ~= generation or token ~= sequence then return end
    if result.timedOut or result.exitCode ~= 0 then
      transition, transition_phase = nil, nil
      helper_state, snapshot.service_state = "error", "error"
      snapshot.status, snapshot.error = "error", "helper " .. verb .. " failed"
      finish_operation(snapshot.error); publish(); return
    end
    -- The helper command and controller readiness are separate milestones.
    -- Verify the service state before starting the longer API health wait.
    transition_deadline = os.time() + 10
    operation_deadline = transition_deadline
    local queued = noctalia.runAsync({ config.helper, "status" }, function(check)
      if current ~= generation or token ~= sequence then return end
      local status = check.exitCode == 0 and not check.timedOut and
        (check.stdout or ""):match("^%s*(%a+)") or nil
      if verb == "stop" and status == "stopped" then
        helper_state, snapshot.service_state = "stopped", "stopped"
        transition, transition_phase = nil, nil
        snapshot.status, snapshot.error = "offline", ""
        finish_operation(); publish()
      elseif verb ~= "stop" and status == "running" then
        helper_state, snapshot.service_state = "running", "running"
        transition_phase = "api"
        transition_deadline = os.time() + API_READY_TIMEOUT
        operation_started, operation_deadline = os.time(), transition_deadline
        operation.stage, operation.remaining = "api", API_READY_TIMEOUT
        publish_operation()
        publish()
        probe()
      elseif status == "stopped" then
        helper_state, snapshot.service_state = "stopped", "stopped"
        transition, transition_phase = nil, nil
        snapshot.status, snapshot.error = "offline", ""
        finish_operation("service stopped before API ready"); publish()
      else
        helper_state, snapshot.service_state = "error", "error"
        transition, transition_phase = nil, nil
        snapshot.status, snapshot.error = "error", "helper status failed"
        finish_operation(snapshot.error); publish()
      end
    end, 8000)
    if not queued then
      helper_state, snapshot.service_state = "error", "error"
      transition, transition_phase = nil, nil
      snapshot.status, snapshot.error = "error", "helper status rejected"
      finish_operation(snapshot.error); publish()
    end
  end, 12000)
  if not accepted then
    helper_state, snapshot.service_state = "error", "error"
    transition, transition_phase = nil, nil
    snapshot.status, snapshot.error = "error", "helper request rejected"
    finish_operation(snapshot.error); publish()
  end
end

local function command(cmd)
  if type(cmd) ~= "table" or type(cmd.op) ~= "string" then return end
  local op = cmd.op
  if op == "start" or op == "stop" or op == "restart_service" then
    lifecycle(op == "restart_service" and "restart" or op); return
  end
  if op == "cancel_wait" and transition_phase == "api" then
    generation, sequence = generation + 1, sequence + 1
    probe_token, helper_token = probe_token + 1, helper_token + 1
    probe_pending, helper_pending = false, false
    probe_suspended = true
    transition, transition_phase = nil, nil
    clear_live()
    snapshot.status, snapshot.error = "error", "health check cancelled"
    finish_operation(); publish()
    return
  end
  if op == "refresh" then
    probe_suspended = false
    if snapshot.helper then helper_status() else probe() end
    return
  end
  if snapshot.status ~= "running" or operation.busy then return end
  local method, path, body
  if op == "mode" and (cmd.mode == "rule" or cmd.mode == "global" or cmd.mode == "direct") then
    method, path, body = "PATCH", "/configs", { mode = cmd.mode }
  elseif op == "select" and type(cmd.group) == "string" and type(cmd.node) == "string" then
    for _, group in ipairs(snapshot.groups) do
      if group.name == cmd.group and group.kind == "Selector" then
        for _, node in ipairs(group.members) do
          if node == cmd.node then method, path, body = "PUT", "/proxies/" .. noctalia.string.urlEncode(cmd.group), { name = cmd.node } end
        end
      end
    end
  elseif op == "close" and type(cmd.id) == "string" then
    for _, item in ipairs(snapshot.connections) do
      if item.id == cmd.id then method, path = "DELETE", "/connections/" .. noctalia.string.urlEncode(cmd.id) end
    end
  elseif op == "restart_core" then
    method, path, body = "POST", "/restart", { path = "", payload = "" }
  elseif op == "delay" or op == "delay_all" then
    local selected = {}
    for _, group in ipairs(snapshot.groups) do
      if op == "delay_all" or group.name == cmd.group then table.insert(selected, group.name) end
    end
    if #selected == 0 then return end
    sequence = sequence + 1; local token = sequence
    operation_started = os.time()
    operation_deadline = operation_started + math.max(18, math.ceil(#selected / 4) * 7 + 10)
    operation = { busy = true, name = "delay", error = "" }; publish_operation()
    local index, active, completed, failed = 1, 0, 0, 0
    local function pump()
      if token ~= sequence then return end
      while index <= #selected and active < 4 do
        local name = selected[index]
        index, active = index + 1, active + 1
        local query = "?url=" .. noctalia.string.urlEncode(config.test_url) .. "&timeout=5000"
        local accepted = request("GET", "/group/" .. noctalia.string.urlEncode(name) .. "/delay" .. query, nil, function(res)
          if token ~= sequence then return end
          local data = decode(res)
          if not data then failed = failed + 1 else
            for _, group in ipairs(snapshot.groups) do
              if group.name == name then group.delays = data end
            end
            publish()
          end
          active, completed = active - 1, completed + 1
          pump()
        end)
        if not accepted then
          failed, active, completed = failed + 1, active - 1, completed + 1
        end
      end
      if completed == #selected then
        finish_operation(failed > 0 and (tostring(failed) .. " delay tests failed") or nil)
      end
    end
    pump()
    return
  end
  if not method then return end
  sequence = sequence + 1; local token = sequence
  operation_started = os.time()
  operation_deadline = operation_started + 18
  operation = { busy = true, name = op, error = "" }; publish_operation()
  local accepted = request(method, path, body, function(res)
    if token ~= sequence then return end
    -- A successful core restart may close the HTTP socket before its 204
    -- arrives. Treat only that transport close as provisional success, then
    -- require /version to come back before reporting the core as running.
    local restart_disconnect = op == "restart_core" and res and
      res.ok == false and (res.status == nil or res.status == 0)
    if not ok(res) and not restart_disconnect then finish_operation(error_text(res)); return end
    if op == "restart_core" then
      generation = generation + 1; clear_live()
      probe_pending = false
      snapshot.status, snapshot.error = "starting", ""
      transition, transition_phase = "restart", "api"
      transition_deadline = os.time() + API_READY_TIMEOUT
      operation_started, operation_deadline = os.time(), transition_deadline
      operation.stage, operation.remaining = "api", API_READY_TIMEOUT
      publish_operation()
      publish()
      probe()
    else
      finish_operation()
      poll_details(generation)
    end
  end)
  if not accepted then finish_operation("request rejected") end
end

noctalia.state.watch("nmc.command", command)
refresh_config()
publish()
publish_operation()
noctalia.setUpdateInterval(2000)
if snapshot.helper then helper_status() else probe() end

function update()
  poll_tick = poll_tick + 1
  if probe_pending and os.time() - probe_started > 8 then
    probe_token = probe_token + 1
    probe_pending = false
    mark_offline("health check timeout")
  end
  if helper_pending and os.time() - helper_started > 8 then
    helper_token = helper_token + 1
    generation, probe_token = generation + 1, probe_token + 1
    probe_pending = false
    helper_pending = false
    helper_state, snapshot.service_state = "error", "error"
    transition, transition_phase = nil, nil
    if operation.busy then finish_operation("helper status timeout") end
    clear_live()
    snapshot.status, snapshot.error = "error", "helper status timeout"; publish()
  end
  if transition and os.time() > transition_deadline then
    local reason = transition_phase == "api" and "health check timeout" or "operation timeout"
    generation, sequence, probe_token, helper_token =
      generation + 1, sequence + 1, probe_token + 1, helper_token + 1
    probe_pending, helper_pending, probe_suspended = false, false, true
    transition, transition_phase = nil, nil
    snapshot.status, snapshot.error = "error", reason
    finish_operation(snapshot.error); publish()
  end
  if operation.busy and not transition and operation_started > 0 and os.time() > operation_deadline then
    sequence = sequence + 1
    finish_operation("operation timeout")
  end
  if transition_phase == "api" then
    local remaining = math.max(0, transition_deadline - os.time())
    if operation.remaining ~= remaining then
      operation.remaining = remaining
      publish_operation()
    end
  end
  if poll_tick % 2 == 1 then probe() end
  if poll_tick % 3 == 0 then helper_status() end
  if snapshot.status == "running" and poll_tick % 2 == 0 then poll_details(generation) end
end

function onConfigChanged()
  generation, sequence, probe_token, helper_token = generation + 1, sequence + 1, probe_token + 1, helper_token + 1
  clear_live()
  probe_pending, helper_pending, transition, transition_phase = false, false, nil, nil
  finish_operation()
  refresh_config(); snapshot.status, snapshot.error = "offline", ""
  publish()
  if snapshot.helper then helper_status() else probe() end
end

function onIpc(event, payload)
  if event == "refresh" then command({ op = "refresh" })
  elseif event == "command" then command(noctalia.json.decode(payload or "")) end
end

function onExit()
  if traffic_stream then traffic_stream.stop() end
end
