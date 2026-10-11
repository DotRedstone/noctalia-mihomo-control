-- A bar widget is a read-only projection of the service snapshot. The bar
-- itself has no keyboard focus; its click opens the native, focusable panel.
local snapshot = noctalia.state.get("nmc.snapshot") or { status = "offline" }

local function rate(value)
  local n = tonumber(value) or 0
  if n >= 1048576 then return string.format("%.1f MiB/s", n / 1048576) end
  if n >= 1024 then return string.format("%.0f KiB/s", n / 1024) end
  return string.format("%.0f B/s", n)
end

local function render()
  local status = snapshot.status or "offline"
  local colors = { offline = "on_surface_variant", starting = "tertiary",
    running = "primary", stopping = "tertiary", error = "error" }
  local glyphs = { offline = "network-off", starting = "loader",
    running = "network", stopping = "loader", error = "alert-circle" }
  local children = {
    ui.glyph({ name = glyphs[status] or "network-off", size = 17,
      color = colors[status] or "on_surface_variant" }),
    ui.label({ text = noctalia.tr("status." .. status), fontWeight = "medium" }),
  }
  if status == "running" then
    table.insert(children, ui.label({ text = noctalia.tr("mode." .. (snapshot.mode or "rule")) .. " · " ..
      tostring(snapshot.count or 0) .. " · ↓" .. rate(snapshot.down) .. " ↑" .. rate(snapshot.up),
      color = "on_surface_variant" }))
  end
  local layout = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(layout({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(noctalia.tr("title") .. " · " .. noctalia.tr("status." .. status) ..
    (snapshot.error ~= "" and (" · " .. tostring(snapshot.error)) or ""))
end

noctalia.state.watch("nmc.snapshot", function(value)
  snapshot = value or { status = "offline" }
  render()
end)

function update()
  noctalia.setUpdateInterval(3000)
  render()
end

function onClick()
  noctalia.togglePanel("nmc/mihomo-control:panel")
end
