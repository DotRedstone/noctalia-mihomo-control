# 在 NixOS dotfiles 中接入

以下仅是**宿主仓库示例**；本插件仓库不放主机名、用户名、密钥、订阅或系统权限规则。当前 Noctalia v5 会把插件启用状态记在 app-managed state，所以 Home Manager 安装代码与首次/启动时 `plugins enable` 需要配合。接入前先将独立仓库推送到 GitHub、发布 `v0.1.0`，再固定该 tag 对应的 commit。

## 1. 固定独立仓库

在 dotfiles 的 `flake.nix` inputs 中加入（替换托管地址与 revision）：

```nix
noctalia-mihomo-control = {
  url = "github:YOUR_ORG/noctalia-mihomo-control/COMMIT_SHA";
  flake = false;
};
```

运行 `nix flake lock --update-input noctalia-mihomo-control` 后检查 lock 中 `rev` 与 `narHash`。固定版本的来源是 flake.lock，不依赖插件自动更新。

## 2. 安装、启用、放入状态栏

在 Noctalia Home Manager 模块接收 `inputs` 并加入：

```nix
{ inputs, ... }: {
  xdg.dataFile."noctalia/plugins/mihomo-control".source =
    "${inputs.noctalia-mihomo-control}/mihomo-control";
}
```

这会把当前锁定版本放入 Noctalia 的本地插件目录。部署 Home Manager 后执行一次：

```sh
noctalia msg plugins enable nmc/mihomo-control
```

若 dotfiles 已有启动时的插件同步脚本，加入 `ensure_plugin nmc/mihomo-control`。如果之前使用社区 `mdj2812/mihomo-control`，在同一同步脚本中停止自动启用并将其禁用，避免双 widget 和重复轮询。将已有 bar 配置中的 `[widget.mihomo] type` 改为 `"nmc/mihomo-control:widget"`；保持 `end` 数组中的 `"mihomo"`，无需重复添加。新用户则将 `"mihomo"` 加到所需 bar 的 `start/center/end` 任一数组。

在 Noctalia 插件设置填写端口和可选密钥。密钥应留在宿主的私有设置或密钥管理方案，不写入此仓库或公开 dotfiles。`helper_path` 暂留空，确认只读 API 正常后再接第 4 步。

## 3. 让宿主服务默认关闭

宿主现有的 `systemd.services.mihomo` 如果含有 `wantedBy = [ "multi-user.target" ];`，必须从**宿主 dotfiles** 的服务定义中移除这一行。保留 unit、`ExecStart` 和必要的服务限制；插件不能通过 UI 配置改变开机启动策略。这样 NixOS 仍会生成 `mihomo.service`，但不会由 `multi-user.target` 自动拉起。不要仅执行一次 `systemctl stop` 就认为已经默认关闭。

部署后检查 `systemctl is-enabled mihomo.service` 不为 `enabled`（无 `[Install]` 规则的 unit 也可能显示 `static`），且 `multi-user.target` 不再依赖它；重启后检查 `systemctl is-active mihomo.service` 为 `inactive`。移除 `wantedBy` 不会自动停止当前已经运行的核心；如需马上切换为关闭状态，先确认当前代理连接可以中断，再由宿主安排停机。若还有其他 unit、timer 或手动 enable 建立的依赖，也必须在宿主侧清除并重新验证。此仓库不修改正在运行的服务。

## 4. 宿主提供只允许 `mihomo.service` 的权限桥

该示例面向 **system service**。在宿主的 NixOS system 模块定义受限组及 Polkit 规则；将组成员配置加进**实际使用者自己的**用户模块，不要开放给普通用户组：

```nix
{ pkgs, ... }:
let
  mihomoLifecycle = pkgs.writeShellScriptBin "mihomo-lifecycle" ''
    set -eu
    [ "$#" -eq 1 ] || exit 64
    case "$1" in
      status)
        if ${pkgs.coreutils}/bin/timeout 10s ${pkgs.systemd}/bin/systemctl --system is-active --quiet mihomo.service; then
          printf 'running\n'
        elif ${pkgs.systemd}/bin/systemctl --system is-failed --quiet mihomo.service; then
          exit 1
        else
          printf 'stopped\n'
        fi
        ;;
      start|stop|restart)
        exec ${pkgs.coreutils}/bin/timeout 12s ${pkgs.systemd}/bin/systemctl --system --no-ask-password "$1" mihomo.service
        ;;
      *) exit 64 ;;
    esac
  '';
in {
  users.groups.mihomo-control = {};
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          subject.isInGroup("mihomo-control") &&
          action.lookup("unit") == "mihomo.service" &&
          ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0) {
        return polkit.Result.YES;
      }
    });
  '';
  environment.systemPackages = [ mihomoLifecycle ];
}
```

只给目标用户加入 `mihomo-control` 组。helper 只接受四个固定参数，固定操作 `mihomo.service`；Polkit 同时限制了**实际 systemd D-Bus 操作的 unit 和 verb**。这里没有 NOPASSWD sudo，也没有 `manage-unit-files` 授权，不允许 enable/disable/mask 或任意 unit。规则依据 systemd 对 `manage-units` action 提供的 `unit` / `verb` 细节；部署前在目标 NixOS 版本上复核。组成员变更后需重新登录，才能在图形会话中生效。

在用户 Noctalia 插件设置里把 `helper_path` 设为**绝对路径**，例如 `command -v mihomo-lifecycle` 的输出；该路径应指向由 Nix 构建、普通用户不能改写的 helper。不要把可写脚本作为 helper，否则 Polkit 规则虽然限制 systemd 操作，脚本自身仍可被替换。插件不运行 `sudo`，也不把用户输入拼进 shell 命令。

## 5. 验证与回退

先 `nix flake check path:. --no-build`、`home-manager build --flake .#YOUR_HOME_OUTPUT`、`sudo nixos-rebuild dry-run --flake .#YOUR_HOST`。这只验证求值与构建边界；服务启停需在部署后手动验收：

1. 重启后确认 `mihomo.service` 仍存在、未被 enable 或其他 unit 拉起、`is-active` 为 `inactive`；`noctalia msg plugins list` 确认新插件启用，点 widget 查看**离线**面板。
2. `mihomo-lifecycle status` 初始输出 `stopped`；用插件按钮启动后，先确认服务为 `running`，再允许本机 API 最长约 180 秒就绪。测试取消等待不会停止服务。再用插件停止、重启并验证状态与错误提示。
3. 尝试让无该组的用户操作、尝试其他 systemd unit、尝试 `enable`，应被拒绝。核查 Polkit 日志和权限边界。
4. 回退时从 bar 配置移除或恢复原 widget type，禁用 `nmc/mihomo-control`，移除 HM 插件安装和 system 权限桥，重新部署；不需要改插件仓库。

不要仅凭 Nix dry-run、插件加载或 HTTP 200 宣称启停验收通过。
