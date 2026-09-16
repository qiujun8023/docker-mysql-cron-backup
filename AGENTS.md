# Agent Guide

本文件说明 `docker-mysql-cron-backup` 仓库的当前实现和开发规则。面向使用者的说明见 [README.md](README.md)。

## 项目实现

- 项目运行在 Ubuntu 的 Docker Compose 环境，镜像支持 `linux/amd64` 和 `linux/arm64`。
- 镜像基于 MySQL 8.4，使用官方 `mysql` 和 `mysqldump` 客户端。
- BusyBox `crond` 根据 `BACKUP_CRON` 运行备份任务。
- 备份在容器临时目录生成，完成 gzip 校验和 S3 上传校验后清理。
- 对象键格式为 `[<S3_PREFIX>/]<数据库名>.<YYYYMMDDHHmmss>.sql.gz`。
- 备份保留周期由对象存储生命周期规则管理。
- `/var/lib/mysql-backup` 保存任务状态，供 Docker Healthcheck 使用。
- `master` 分支通过 CI 后发布 `ghcr.io/qiujun8023/mysql-cron-backup:latest`。

新增或修改配置时，同步更新 [README.md](README.md)、[compose.example.yml](compose.example.yml) 和相关测试。

## 常用校验

```bash
shellcheck scripts/*.sh tests/*.sh
bash -n scripts/*.sh tests/*.sh
bash tests/run.sh
bash tests/integration.sh
actionlint .github/workflows/docker.yml
```

集成测试使用真实 MySQL 8.4 验证导出、恢复、cron 调度和健康检查，S3 命令由测试脚本模拟。Dockerfile、基础镜像或构建流程变化后，需要完成集成测试和双架构构建。

## 提交规则

- 未经用户明确要求或明确同意，不得执行 `git commit` 或 `git push`。
- 默认在 `master` 分支开发，提交前确认 `git status --short` 只包含本次任务相关文件。
- 提交信息使用中文，格式为 `<type>(<scope>): <中文摘要>`。
- type 使用 `feat`、`fix`、`refactor`、`docs`、`test`、`build`、`ci` 或 `chore`。
- scope 使用 `backup`、`scheduler`、`docker`、`ci`、`docs` 等实际模块名。
- 提交信息不包含 AI 署名、生成标识、协作者 trailer 或工具标记。

## 操作边界

- 保留用户已有改动，忽略与当前任务无关的工作区变化。
- 仓库内容不包含 MySQL 密码、S3 密钥、`.env`、真实备份文件或镜像归档。
- S3 备份身份仅使用备份和校验所需权限，对象删除由存储桶生命周期执行。
- SSH 部署、生产容器重启和生产备份需要用户明确授权。
- 验证结果应注明实际执行过的测试范围。
