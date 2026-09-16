# syntax=docker/dockerfile:1.7

ARG MYSQL_VERSION=8.4.11

FROM amazon/aws-cli:2.36.46 AS aws-cli

FROM mysql:${MYSQL_VERSION}

USER root

RUN microdnf install -y \
      findutils \
      gzip \
      tzdata \
      util-linux \
    && microdnf clean all

COPY --from=aws-cli /usr/local/aws-cli /usr/local/aws-cli
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws

RUN aws --version \
    && mysqldump --version \
    && gzip --version \
    && flock --version

COPY scripts/backup.sh /usr/local/bin/backup.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY scripts/scheduler.sh /usr/local/bin/scheduler.sh

RUN chmod 0755 \
      /usr/local/bin/backup.sh \
      /usr/local/bin/healthcheck.sh \
      /usr/local/bin/scheduler.sh \
    && mkdir -p /backup

ENV BACKUP_DIR=/backup \
    BACKUP_TIME=03:00 \
    GZIP_LEVEL=6 \
    HEALTHCHECK_MAX_AGE_SECONDS=129600 \
    LOCAL_RETENTION_COUNT=2 \
    MYSQL_PORT=3306 \
    MYSQL_SSL_MODE=PREFERRED \
    RUN_ON_STARTUP=false \
    S3_BUCKET=mysql-backups \
    S3_REGION=us-east-1 \
    TZ=Asia/Shanghai

VOLUME ["/backup"]

HEALTHCHECK --interval=5m --timeout=10s --retries=1 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/scheduler.sh"]
CMD []
