# 多节点部署

## 发布前数据库备份

`customer.yml`、`control.yml` 和 `runtime.yml` 在修改服务前都会执行强制数据库备份。
已有数据库备份失败、文件为空或 SHA-256 校验失败时，发布立即中止；首次安装尚无内置数据库
容器时会记录 `not_installed` 后继续。

备份默认保存在数据库所在主机的
`/opt/tsuite-deploy/backups/releases/<UTC 时间>/`。每个组件同时写入一份 JSON 清单，记录
目标环境、部署节点、数据库、备份文件、校验值、发布前运行镜像及本次目标版本；全局历史追加到
`/opt/tsuite-deploy/backups/releases/history.jsonl`，用于定位可回退的数据库与镜像组合。

`ansible/` 是多节点部署 Adapter，按 Control、Runtime、Customer 角色编排，并可配置独立 PostgreSQL 与入口节点。

从旧目录布局升级时，Git 不会自动移动未跟踪的 Inventory、Vault 或源码归档。先复制到新位置，确认可用后再自行处理旧副本；命令使用 `-n`，不会覆盖已有文件：

```bash
mkdir -p multi-node/ansible/inventories/internal-demo multi-node/ansible/artifacts
cp -an ansible/inventories/internal-demo/{hosts.yml,vault.yml,control_private.yml} \
  multi-node/ansible/inventories/internal-demo/ 2>/dev/null || true
cp -an ansible/artifacts/* multi-node/ansible/artifacts/ 2>/dev/null || true
```

从该目录运行 Ansible，以使用本目录的 `ansible.cfg` 和相对路径：

```bash
cd multi-node/ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/preflight.yml --ask-vault-pass
ansible-playbook playbooks/deploy-all.yml --ask-vault-pass
```

本地源码快照仅用于 `local_bundle` 故障恢复模式：

```bash
multi-node/tools/create-source-bundle.sh
```
