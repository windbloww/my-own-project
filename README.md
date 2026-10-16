# Cloudflare DDNS

一个尽量傻瓜化的 Cloudflare DDNS Bash 脚本，仅支持 **API Token**。

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

## 私有仓库一键安装

因为仓库是 Private，GitHub 不允许匿名 `curl raw.githubusercontent.com/... | bash`。

推荐在机器上安装并登录 GitHub CLI 一次：

```bash
gh auth login
```

之后安装命令只有一条：

```bash
gh api repos/windbloww/my-own-project/contents/install.sh --jq '.content' | tr -d '\n' | base64 -d | bash
```

安装器会自动下载主脚本、安装依赖并进入首次配置向导。

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

> 不要把 `~/.config/cf-ddns/config.json` 提交到 GitHub；其中包含 Cloudflare API Token。
