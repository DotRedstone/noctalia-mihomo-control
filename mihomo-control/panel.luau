-- Native controls supply Tab / Shift+Tab, Enter/Space and Escape navigation.
-- The service validates every command again; labels and connections shown here
-- are untrusted controller data, so no text is ever used as a shell command.
local snapshot = noctalia.state.get("nmc.snapshot") or { status = "offline", groups = {}, connections = {} }
local operation = noctalia.state.get("nmc.operation") or { busy = false, error = "" }
local opened = false
local serial = 0
local expanded_group = nil
local group_page, member_page = 1, 1
local render

local function tr(key) return noctalia.tr(key) end
local known_errors = {
  unreachable = true, unauthorized = true, ["request rejected"] = true,
  ["health check timeout"] = true, ["helper status failed"] = true,
  ["helper status timeout"] = true, ["invalid helper status"] = true,
  ["helper unavailable"] = true, ["helper request rejected"] = true,
  ["stop health check failed"] = true, ["stop health check rejected"] = true,
  ["operation timeout"] = true,
}
local function error_message(value)
  if known_errors[value] then return tr("failure." .. value) end
  local count = tostring(value):match("^(%d+) delay tests failed$")
  if count then return tr("failure.delay_tests_failed") .. " " .. count end
  return tostring(value)
end
local function send(op, extra)
  serial = serial + 1
  local cmd = extra or {}
  cmd.op, cmd.serial = op, serial
  noctalia.state.set("nmc.command", cmd)
end

local function button(text, action, enabled, variant)
  return ui.button({ text = text, onClick = action, enabled = enabled ~= false,
    variant = variant or "default", controlSize = "sm" })
end

local function group_view(group)
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ text = group.name, key = "open:" .. group.name,
        contentAlign = "start", flexGrow = 1,
        variant = expanded_group == group.name and "secondary" or "ghost",
        onClick = function()
          if expanded_group == group.name then expanded_group = nil
          else expanded_group = group.name; member_page = 1 end
          render()
        end }),
      ui.label({ text = group.selected or "", color = "primary" }),
      button(tr("test_group"), function() send("delay", { group = group.name }) end,
        not operation.busy),
    }),
  }
  if expanded_group == group.name and group.kind == "Selector" then
    local members = group.members or {}
    local total_pages = math.max(1, math.ceil(#members / 30))
    member_page = math.min(member_page, total_pages)
    for i = (member_page - 1) * 30 + 1, math.min(member_page * 30, #members) do
      local node = members[i]
      local latency = group.delays and group.delays[node]
      local suffix = latency and (" · " .. tostring(latency) .. " ms") or ""
      table.insert(rows, ui.button({ key = "node:" .. group.name .. ":" .. node,
        text = node .. suffix, selected = node == group.selected,
        contentAlign = "start", controlSize = "sm", enabled = not operation.busy,
        onClick = function() send("select", { group = group.name, node = node }) end }))
    end
    if total_pages > 1 then
      table.insert(rows, ui.row({ gap = 8, align = "center" }, {
        button(tr("previous"), function() member_page = member_page - 1; render() end, member_page > 1),
        ui.label({ text = tostring(member_page) .. "/" .. tostring(total_pages) }),
        button(tr("next"), function() member_page = member_page + 1; render() end,
          member_page < total_pages),
      }))
    end
  elseif expanded_group == group.name then
    table.insert(rows, ui.label({ text = tr("automatic_group"), color = "on_surface_variant" }))
  end
  return ui.column({ key = "group:" .. group.name, gap = 5, padding = 10,
    fill = "surface_container", radius = 10 }, rows)
end

local function connection_view(item)
  local host = item.host ~= "" and item.host or tr("unknown_host")
  local detail = item.process ~= "" and (item.process .. " · " .. item.chains) or item.chains
  return ui.row({ key = "connection:" .. item.id, gap = 8, align = "center" }, {
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = host, maxLines = 1 }),
      ui.label({ text = detail, color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
    }),
    button(tr("close_connection"), function() send("close", { id = item.id }) end,
      not operation.busy, "outline"),
  })
end

render = function()
  if not opened then return end
  local status = snapshot.status or "offline"
  local online = status == "running"
  local status_color = online and "primary" or (status == "error" and "error" or "on_surface_variant")
  local body = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "network", color = status_color, size = 20 }),
      ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      button(tr("refresh"), function() send("refresh") end),
      ui.button({ glyph = "close", tooltip = tr("close_panel"), onClick = function() panel.close() end }),
    }),
    ui.label({ text = tr("status." .. status) ..
      ((snapshot.version or "") ~= "" and (" · " .. snapshot.version) or ""), color = status_color }),
  }
  if snapshot.error and snapshot.error ~= "" then
    table.insert(body, ui.label({ text = tr("error") .. ": " .. error_message(snapshot.error),
      color = "error", maxLines = 3 }))
  end
  if operation.busy then
    table.insert(body, ui.label({ text = tr("working") .. " " .. (operation.name or ""),
      color = "tertiary" }))
  elseif operation.error and operation.error ~= "" then
    table.insert(body, ui.label({ text = tr("error") .. ": " .. error_message(operation.error), color = "error" }))
  end

  if snapshot.helper then
    table.insert(body, ui.row({ gap = 8 }, {
      button(tr("start"), function() send("start") end,
        not online and not operation.busy and status ~= "starting"),
      button(tr("stop"), function() send("stop") end,
        online and not operation.busy),
      button(tr("restart_service"), function() send("restart_service") end,
        online and not operation.busy),
    }))
  end

  if not online then
    table.insert(body, ui.column({ gap = 8, padding = 16,
      fill = "surface_container", radius = 12 }, {
      ui.glyph({ name = "network-off", size = 28, color = status_color }),
      ui.label({ text = tr("offline_title"), fontWeight = "bold" }),
      ui.label({ text = tr("offline_hint"), color = "on_surface_variant", maxLines = 3 }),
      button(tr("open_settings"), function() noctalia.openSettings() end),
    }))
    panel.render(ui.column({ gap = 12, flexGrow = 1 }, body))
    return
  end

  table.insert(body, ui.row({ gap = 8 }, {
    ui.label({ text = "↓ " .. tostring(math.floor(snapshot.down or 0)) .. " B/s", color = "primary" }),
    ui.label({ text = "↑ " .. tostring(math.floor(snapshot.up or 0)) .. " B/s", color = "tertiary" }),
    ui.label({ text = tr("connections") .. " " .. tostring(snapshot.count or 0) }),
  }))
  table.insert(body, ui.row({ gap = 6 }, {
    button(tr("mode.rule"), function() send("mode", { mode = "rule" }) end, not operation.busy,
      snapshot.mode == "rule" and "primary" or "outline"),
    button(tr("mode.global"), function() send("mode", { mode = "global" }) end, not operation.busy,
      snapshot.mode == "global" and "primary" or "outline"),
    button(tr("mode.direct"), function() send("mode", { mode = "direct" }) end, not operation.busy,
      snapshot.mode == "direct" and "primary" or "outline"),
  }))
  table.insert(body, ui.row({ gap = 8 }, {
    button(tr("test_all"), function() send("delay_all") end, not operation.busy),
    button(tr("restart_core"), function() send("restart_core") end,
      not operation.busy, "outline"),
  }))

  local sections = {}
  table.insert(sections, ui.label({ text = tr("proxy_groups"), fontWeight = "bold", color = "primary" }))
  if #(snapshot.groups or {}) == 0 then
    table.insert(sections, ui.label({ text = tr("no_groups"), color = "on_surface_variant" }))
  else
    local groups = snapshot.groups
    local total_pages = math.max(1, math.ceil(#groups / 20))
    group_page = math.min(group_page, total_pages)
    for i = (group_page - 1) * 20 + 1, math.min(group_page * 20, #groups) do
      table.insert(sections, group_view(groups[i]))
    end
    if total_pages > 1 then
      table.insert(sections, ui.row({ gap = 8, align = "center" }, {
        button(tr("previous"), function() group_page = group_page - 1; render() end, group_page > 1),
        ui.label({ text = tostring(group_page) .. "/" .. tostring(total_pages) }),
        button(tr("next"), function() group_page = group_page + 1; render() end,
          group_page < total_pages),
      }))
    end
  end
  table.insert(sections, ui.separator({ spacing = 8 }))
  table.insert(sections, ui.label({ text = tr("connections") .. " (" .. tostring(snapshot.count or 0) .. ")",
    fontWeight = "bold", color = "primary" }))
  if #(snapshot.connections or {}) == 0 then
    table.insert(sections, ui.label({ text = tr("no_connections"), color = "on_surface_variant" }))
  else
    for _, item in ipairs(snapshot.connections) do table.insert(sections, connection_view(item)) end
    if (snapshot.count or 0) > #snapshot.connections then
      table.insert(sections, ui.label({ text = tr("showing_first"), color = "on_surface_variant" }))
    end
  end
  table.insert(body, ui.scroll({ flexGrow = 1, gap = 10 }, sections))
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, body))
end

noctalia.state.watch("nmc.snapshot", function(value)
  snapshot = value or { status = "offline", groups = {}, connections = {} }
  render()
end)
noctalia.state.watch("nmc.operation", function(value)
  operation = value or { busy = false, error = "" }
  render()
end)

function onOpen()
  opened = true
  render()
  send("refresh")
end

function onClose()
  opened = false
end
