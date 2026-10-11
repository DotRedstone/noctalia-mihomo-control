# 公开实现调研（2026-10-11）

Noctalia v5 的插件由目录内 `plugin.toml` 与独立 Luau entries 组成。`[[service]]`、`[[widget]]`、`[[panel]]` 分别运行于独立 VM，以 `noctalia.state` 传递普通值。UI 使用 `panel.render(ui.*)`，面板原生控件获取键盘焦点；插件 API 24 提供无 shell 的 `runAsync(argv)`。官方发布源需要仓库根目录 `catalog.toml`，插件放在与 ID 后半段同名的子目录。参见[官方开发指南](https://docs.noctalia.dev/noctalia/plugins/development/)、[运行时 API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/)与[工作流](https://docs.noctalia.dev/noctalia/plugins/development/workflow/)。

社区 [`mdj2812/mihomo-control`](https://github.com/noctalia-dev/community-plugins/tree/main/mihomo-control) 已合入 Noctalia community-plugins；其原 `github.com/mdj2812/mihomo-control` 地址当前返回 404。公开功能页记载它支持本机和远程 controller、HTTP/HTTPS、服务器配置、流量流、模式、组选择、测速、连接管理、API restart，以及额外图标和展示设置。其进程启停不是功能范围，源码利用 `jq` 处理大响应。本项目参考其功能边界和 Mihomo API 路由，不复用代码、字样、字体或资源。参见[公开功能页](https://noctalia.dev/plugins/community/mihomo-control)。

Mihomo 官方 API 明确给出 `GET /traffic`、`GET /version`、`GET/PATCH /configs`、`GET /group`、`GET /group/{name}/delay`、`PUT /proxies/{name}`、`GET/DELETE /connections`、`DELETE /connections/{id}`、`POST /restart`。参见[官方 API 文档](https://wiki.metacubex.one/en/api/)。
