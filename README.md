# Cloudflare DDNS

一个尽量傻瓜化的 Cloudflare DDNS Bash 脚本，仅支持 **API Token**。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/windbloww/my-own-project/main/install.sh | bash
```

首次运行会自动进入配置向导。以后无需 GitHub 登录。

首次配置时只需要：

1. 粘贴 Cloudflare API Token
2. 从脚本列出的 Cloudflare 域名中选一个
3. 输入 DDNS 主机名前缀，例如 `home` / `nas` / `ddns`
4. 选择 IPv4、IPv6 或双栈
5. 选择是否开启 Cloudflare 橙云

脚本会自动：

- 检查 Token
- 获取 Zone ID
- 获取公网 IPv4 / IPv6
- 查找 DNS Record ID
- 没有记录时自动创建
- IP 变化时自动更新
- 安装 cron，默认每 5 分钟检查一次
- 将 Token 保存在当前用户 `~/.config/cf-ddns/config.json`，权限为 `600`

## Cloudflare API Token

进入 Cloudflare Dashboard：

`My Profile → API Tokens → Create Token`

推荐使用 **Edit zone DNS** 模板，并确认至少包含：

- `Zone → DNS → Edit`
- `Zone → Zone → Read`

资源建议只允许需要 DDNS 的那个 Zone。

Token 创建后只显示一次，请复制保存。

## 常用命令

```bash
~/.local/bin/cf-ddns
~/.local/bin/cf-ddns --update
~/.local/bin/cf-ddns --status
~/.local/bin/cf-ddns --setup
```

## 文件位置

- 程序：`~/.local/bin/cf-ddns`
- 配置：`~/.config/cf-ddns/config.json`
- 日志：`~/.local/state/cf-ddns/ddns.log`

> Cloudflare API Token 不会上传到 GitHub。不要把 `~/.config/cf-ddns/config.json` 提交到仓库。
