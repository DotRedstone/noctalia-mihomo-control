local state, watches, rendered = {}, {}, {}
local function ui_node(kind)
  return function(props, children)
    return { kind = kind, props = props or {}, children = children or {} }
  end
end
local ui = {}
for _, kind in ipairs({ "row", "column", "scroll", "label", "glyph", "button", "separator" }) do
  ui[kind] = ui_node(kind)
end
local host = {
  state = {
    get = function(key) return state[key] end,
    set = function(key, value) state[key] = value end,
    watch = function(key, fn) watches[key] = fn end,
  },
  tr = function(key) return key end,
  setUpdateInterval = function() end,
  togglePanel = function(id) assert(id == "nmc/mihomo-control:panel") end,
  openSettings = function() end,
}
local function contains(node, value)
  if node.props and node.props.text == value then return true end
  for _, child in ipairs(node.children or {}) do
    if contains(child, value) then return true end
  end
  return false
end
local panel_env = setmetatable({ noctalia = host, ui = ui,
  panel = { render = function(tree) rendered.panel = tree end, close = function() end } }, { __index = _G })
assert(loadfile("mihomo-control/panel.luau", "t", panel_env))()
panel_env.onOpen()
assert(contains(rendered.panel, "offline_title"))
assert(not contains(rendered.panel, "start"), "helper action shown without helper")

local online = { status = "running", error = "", version = "test", mode = "rule",
  helper = true, down = 10, up = 5, count = 1,
  groups = { { name = "Choice", selected = "A", kind = "Selector", members = { "A", "B" } } },
  connections = { { id = "1", host = "example.test", process = "app", chains = "Choice" } } }
watches["nmc.snapshot"](online)
assert(contains(rendered.panel, "Choice"))
assert(contains(rendered.panel, "example.test"))
assert(contains(rendered.panel, "stop"))

-- A large controller response must stay below Noctalia's 256-child UI limit.
online.groups = {}
for i = 1, 300 do
  local members = {}
  for j = 1, 300 do members[j] = "Node " .. j end
  online.groups[i] = { name = "Group " .. i, selected = members[1], kind = "Selector", members = members }
end
watches["nmc.snapshot"](online)
local function bounded(node)
  assert(#node.children <= 256, "UI child limit exceeded")
  for _, child in ipairs(node.children) do bounded(child) end
end
bounded(rendered.panel)

local widget_env = setmetatable({ noctalia = host, ui = ui,
  barWidget = { isVertical = function() return false end,
    render = function(tree) rendered.widget = tree end,
    setTooltip = function() end } }, { __index = _G })
state["nmc.snapshot"] = online
assert(loadfile("mihomo-control/widget.luau", "t", widget_env))()
widget_env.update()
assert(contains(rendered.widget, "status.running"))
widget_env.onClick()
print("ui: ok")
