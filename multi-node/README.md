# 多节点部署

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
