# mysql-scheduled-backup

`mysql-scheduled-backup` 是运行在 Docker 中的 MySQL 定时备份服务。服务每天按指定时间导出业务数据库，将压缩后的 SQL 文件上传到 S3 兼容对象存储，并通过 Docker Healthcheck 暴露最近一次任务状态。

镜像内置 MySQL 8.4 客户端、AWS CLI、gzip 和调度器，支持 `linux/amd64` 与 `linux/arm64`。

## 备份流程

每次任务执行以下流程：

1. 从 MySQL 读取数据库列表，选择业务数据库。
2. 使用一致性事务分别导出每个数据库的表、视图、触发器、事件和存储过程。
3. 将导出内容写入临时文件并使用 gzip 压缩。
4. 通过 `gzip -t` 检查文件完整性后生成正式备份文件。
5. 将文件上传到 S3，并通过 `HeadObject` 比较本地与远端文件大小。
6. 按数据库清理本地历史文件，默认保留最近 2 份。
7. 记录任务成功或失败时间，供容器健康检查使用。

业务数据库范围不包含 `information_schema`、`mysql`、`performance_schema` 和 `sys`。

## 对象结构

S3 对象键格式为：

```text
<服务器名>/<数据库名>.<YYYYMMDDHHmmss>.sql.gz
```

示例：

```text
mysql-backups/
├── tencent-tky-001/
│   ├── anonaddy.20260917013000.sql.gz
│   ├── grafana.20260917013000.sql.gz
│   └── telegram_monitor.20260917013000.sql.gz
└── tencent-tky-002/
    └── arbitrage.20260917020000.sql.gz
```

文件名时间使用容器的 `TZ`，默认时区为 `Asia/Shanghai`。

## 部署

运行环境为 Ubuntu 服务器上的 Docker Compose。参考 [compose.example.yml](compose.example.yml) 将服务加入 MySQL 所在的 Compose 项目和 Docker 网络。

部署目录需要提供以下密钥文件，每个文件只包含一行内容：

```text
secrets/mysql_backup_user
secrets/mysql_backup_password
secrets/rustfs_access_key
secrets/rustfs_secret_key
```

启动服务：

```bash
docker compose up -d mysql-scheduled-backup
```

立即执行一次备份：

```bash
docker exec database-mysql-backup /usr/local/bin/backup.sh
```

查看调度和备份日志：

```bash
docker logs database-mysql-backup
```

## 配置

| 变量 | 必需 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `BACKUP_SERVER_NAME` | 是 | - | S3 对象键中的服务器前缀 |
| `BACKUP_TIME` | 否 | `03:00` | 每日执行时间，24 小时制 |
| `RUN_ON_STARTUP` | 否 | `false` | 容器启动后立即执行一次备份 |
| `BACKUP_DIR` | 否 | `/backup` | 本地备份和状态目录 |
| `LOCAL_RETENTION_COUNT` | 否 | `2` | 每个数据库在本地保留的文件数 |
| `GZIP_LEVEL` | 否 | `6` | gzip 压缩等级，范围 1-9 |
| `MYSQL_HOST` | 否 | `mysql` | MySQL 主机名 |
| `MYSQL_HOST_FILE` | 否 | - | 从文件读取 MySQL 主机名 |
| `MYSQL_PORT` | 否 | `3306` | MySQL 端口 |
| `MYSQL_USER` / `MYSQL_USER_FILE` | 是 | - | MySQL 用户名，二选一 |
| `MYSQL_PASSWORD` / `MYSQL_PASSWORD_FILE` | 是 | - | MySQL 密码，二选一 |
| `MYSQL_DATABASES` | 否 | 自动发现 | 逗号分隔的数据库列表 |
| `MYSQL_DATABASES_FILE` | 否 | - | 每行一个数据库名 |
| `MYSQL_SSL_MODE` | 否 | `PREFERRED` | MySQL 客户端 SSL 模式 |
| `S3_ENDPOINT` | 是 | - | S3 兼容接口地址 |
| `S3_BUCKET` | 否 | `mysql-backups` | 目标桶名称 |
| `S3_REGION` | 否 | `us-east-1` | S3 区域 |
| `AWS_ACCESS_KEY_ID` / `AWS_ACCESS_KEY_ID_FILE` | 是 | - | S3 Access Key，二选一 |
| `AWS_SECRET_ACCESS_KEY` / `AWS_SECRET_ACCESS_KEY_FILE` | 是 | - | S3 Secret Key，二选一 |
| `HEALTHCHECK_MAX_AGE_SECONDS` | 否 | `129600` | 最近成功备份的最大允许年龄，默认 36 小时 |
| `TZ` | 否 | `Asia/Shanghai` | 调度和文件名时区 |

生产部署使用 `_FILE` 变量读取凭据。`MYSQL_DATABASES_FILE` 的优先级高于 `MYSQL_DATABASES` 和自动发现。

## MySQL 账号

每台 MySQL 使用独立的只读备份用户：

```sql
CREATE USER 'mysql_backup'@'%' IDENTIFIED BY '<独立随机密码>';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW_ROUTINE ON *.* TO 'mysql_backup'@'%';
```

备份命令使用 `--single-transaction` 和 `--no-tablespaces`，不需要 `PROCESS` 权限。

## RustFS 配置

备份用户使用以下 IAM 策略访问 `mysql-backups` 桶：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ["arn:aws:s3:::mysql-backups"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::mysql-backups/*"]
    }
  ]
}
```

`mysql-backups` 桶使用 7 天生命周期规则管理远端保留时间。备份用户的策略不包含 `s3:DeleteObject`。

## 健康状态

状态文件保存在 `/backup/.state`：

- 最近一次任务失败时，容器状态为 `unhealthy`。
- 最近一次成功备份超过 `HEALTHCHECK_MAX_AGE_SECONDS` 时，容器状态为 `unhealthy`。
- 新任务成功后，容器状态恢复为 `healthy`。

## CI

GitHub Actions 执行 ShellCheck、脚本测试和多架构镜像构建：

- Pull Request 构建镜像但不发布。
- `master` 分支发布 `latest`、`master` 和 commit SHA 标签。
- `v*` 标签发布对应版本标签。

镜像地址：

```text
ghcr.io/qiujun8023/mysql-scheduled-backup
```
