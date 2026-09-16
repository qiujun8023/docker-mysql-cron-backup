# docker-mysql-cron-backup

`docker-mysql-cron-backup` 是运行在 Docker 中的 MySQL 定时备份服务。服务根据 cron 表达式导出 MySQL 数据库，将压缩后的 SQL 文件上传到 AWS S3 或 S3 兼容对象存储。

镜像基于 MySQL 8.4，包含官方 `mysql`、`mysqldump` 客户端、AWS CLI、gzip、flock 和 BusyBox `crond`，支持 `linux/amd64` 与 `linux/arm64`。

## 备份流程

每次任务执行以下流程：

1. 读取 MySQL 中的数据库列表。
2. 排除 `information_schema`、`mysql`、`performance_schema` 和 `sys`。
3. 分别导出每个数据库的表、视图、触发器、事件和存储过程。
4. 将 SQL 压缩到容器临时目录，并使用 `gzip -t` 检查文件完整性。
5. 上传文件到 S3，并使用 `HeadObject` 核对对象大小。
6. 清理临时文件并记录任务状态。

单个数据库失败后，其余数据库继续执行；存在任何失败时，本次任务最终状态为失败。备份文件保存在对象存储中，保留周期由存储桶生命周期规则管理。

## 对象结构

对象键格式：

```text
[<S3_PREFIX>/]<数据库名>.<YYYYMMDDHHmmss>.sql.gz
```

当 `S3_PREFIX=db-01` 时：

```text
mysql-backups/
└── db-01/
    ├── app.20260917030000.sql.gz
    └── analytics.20260917030000.sql.gz
```

`S3_PREFIX` 支持 `production/db-01` 形式的多级前缀。文件名时间使用容器的 `TZ`。

## 部署

运行环境为 Ubuntu 上的 Docker Compose。参考 [compose.example.yml](compose.example.yml)，并确保备份容器可以通过 `MYSQL_HOST` 访问 MySQL。

启动或更新服务：

```bash
docker compose pull mysql-backup
docker compose up -d mysql-backup
```

立即执行一次备份：

```bash
docker compose exec mysql-backup backup.sh
```

查看日志：

```bash
docker compose logs -f mysql-backup
```

导出文件上传前存放在容器的 `/tmp`，容器可写层需要能够容纳最大的单个数据库压缩文件。

## 恢复

```bash
aws s3 cp s3://<bucket>/<S3_PREFIX>/app.20260917030000.sql.gz - \
  | gzip -dc \
  | mysql -h <host> -u root -p
```

备份包含 `CREATE DATABASE` 和 `USE` 语句，会恢复到同名数据库。

## 配置

| 变量 | 必需 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `MYSQL_HOST` | 否 | `mysql` | MySQL 主机名 |
| `MYSQL_PORT` | 否 | `3306` | MySQL 端口 |
| `MYSQL_USER` | 是 | - | MySQL 用户名 |
| `MYSQL_PASSWORD` | 是 | - | MySQL 密码 |
| `MYSQL_SSL_MODE` | 否 | `PREFERRED` | MySQL SSL 模式 |
| `MYSQL_DATABASES` | 否 | 自动发现 | 逗号分隔的数据库列表 |
| `S3_ENDPOINT` | 否 | AWS S3 | S3 兼容服务地址；设置后使用 path-style 访问 |
| `S3_REGION` | 否 | `us-east-1` | S3 区域 |
| `S3_BUCKET` | 是 | - | 目标存储桶 |
| `S3_PREFIX` | 否 | - | 对象键前缀，例如 `db-01` 或 `production/db-01` |
| `AWS_ACCESS_KEY_ID` | 是 | - | S3 Access Key |
| `AWS_SECRET_ACCESS_KEY` | 是 | - | S3 Secret Key |
| `BACKUP_CRON` | 否 | `0 3 * * *` | 5 段 cron 表达式，按 `TZ` 计算 |
| `TZ` | 否 | `UTC` | 调度和文件名时区 |
| `GZIP_LEVEL` | 否 | `6` | gzip 压缩等级，范围 1-9 |
| `HEALTHCHECK_MAX_AGE_SECONDS` | 否 | `129600` | 最近成功备份的最大允许时间，默认 36 小时 |

`MYSQL_SSL_MODE` 支持 `DISABLED`、`PREFERRED`、`REQUIRED`、`VERIFY_CA` 和 `VERIFY_IDENTITY`。

## MySQL 账号

备份账号需要读取业务数据库的表、视图、触发器、事件和存储过程：

```sql
CREATE USER 'backup'@'%' IDENTIFIED BY '<随机密码>';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW_ROUTINE ON *.* TO 'backup'@'%';
```

备份命令使用 `--single-transaction`、`--no-tablespaces` 和 `--set-gtid-purged=OFF`。

## S3 权限

备份身份需要以下权限，其中 `<bucket>` 替换为目标存储桶：

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
      "Resource": ["arn:aws:s3:::<bucket>"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::<bucket>/*"]
    }
  ]
}
```

对象过期由存储桶生命周期规则处理。

## 健康检查

任务状态保存在容器的 `/var/lib/mysql-backup`：

- 最近一次任务失败时，容器状态为 `unhealthy`。
- 最近一次成功备份超过 `HEALTHCHECK_MAX_AGE_SECONDS` 时，容器状态为 `unhealthy`。
- 后续任务成功后，容器状态恢复为 `healthy`。

容器重建后健康状态重新计时。

## CI

GitHub Actions 执行 ShellCheck、脚本测试、MySQL 8.4 备份恢复测试以及 `linux/amd64`、`linux/arm64` 镜像构建。`master` 构建成功后发布：

```text
ghcr.io/qiujun8023/mysql-cron-backup:latest
```
