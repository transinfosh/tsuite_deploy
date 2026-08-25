# 单机部署

`deploy.sh` 是单台 Ubuntu 的 Frappe Docker Compose 部署 Adapter。它只处理一个站点的三种生命周期：

1. 新安装：创建站点、安装应用并迁移；
2. 已有部署更新：升级镜像前备份，迁移后进行健康检查；
3. 旧 `frappe_docker` Compose 接管：使用 `--adopt-existing-site` 迁移站点卷并纳入本工具管理。

安装入口保持在仓库根目录的 `install.sh`，以兼容既有命令：

```bash
curl -fsSL https://raw.githubusercontent.com/transinfosh/tsuite_deploy/main/install.sh | sudo bash
sudo tsuite-deploy
```

单机部署不读取 `shared/contracts/` 中的文件；这些文档只定义跨部署形态的约定，避免安装脚本在运行时依赖仓库目录布局。
