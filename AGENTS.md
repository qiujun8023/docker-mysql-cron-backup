# Agent Guide

本文件给 AI 代理使用，说明本仓库内必须遵守的开发和提交规则。面向人的项目说明见 [README.md](README.md)。

## 基本规则

- 默认在 `master` 上开发；提交前确认 `git status --short` 只包含本次任务相关文件。
- 不要回滚用户已有改动；遇到无关脏工作区直接忽略，除非它直接阻塞当前任务。
- 项目运行环境为 Ubuntu 上的 Docker Compose，发布镜像支持 `linux/amd64` 和 `linux/arm64`。
- 备份对象使用 `<服务器名>/<数据库名>.<YYYYMMDDHHmmss>.sql.gz` 结构，远端保留周期由对象存储生命周期管理。
- 备份流程包括临时文件写入、gzip 完整性检查、S3 上传校验、并发锁和健康状态记录；修改这些行为时必须同步更新测试。
- 新增或修改配置时，同步更新 [README.md](README.md) 和 [compose.example.yml](compose.example.yml)。

## 常用校验

```bash
shellcheck scripts/*.sh tests/*.sh
bash -n scripts/*.sh tests/*.sh
bash tests/run.sh
actionlint .github/workflows/docker.yml
```

修改 Dockerfile、基础镜像或构建流程后，以 GitHub Actions 的 `linux/amd64`、`linux/arm64` 构建结果为准。

## 提交规则

- 未经用户明确要求或明确同意，不得执行 `git commit` 或 `git push`。
- 提交信息统一使用中文，subject 和 body 都必须写中文。
- 格式：`<type>(<scope>): <中文摘要>`；type 使用 `feat`/`fix`/`refactor`/`docs`/`test`/`build`/`ci`/`chore`，不随意新增。
- scope 使用 `backup`、`scheduler`、`docker`、`ci` 或 `docs` 等实际模块名。
- 能用 subject 说清楚的不写 body；需要 body 时使用单个 `git commit -m $'...\n\n...'`。
- 不要加入 AI 署名、生成标识、协作者 trailer 或工具标记。

## 禁止事项

- 不要提交 MySQL 密码、S3 密钥、`.env`、`secrets/`、真实备份文件或镜像归档。
- 不要给备份身份增加远端对象删除权限。
- 未经用户明确要求，不要通过 SSH 修改配置、部署镜像、运行备份或重启生产容器。
- 不要仅凭单元测试声称真实 MySQL、S3 或多架构镜像已经验证。
