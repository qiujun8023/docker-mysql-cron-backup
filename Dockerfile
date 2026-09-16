# syntax=docker/dockerfile:1.7

FROM amazon/aws-cli:2.36.46 AS aws-cli

FROM busybox:1.37.0-musl AS busybox

FROM mysql:8.4

USER root

RUN microdnf install -y \
      gzip \
      tzdata \
      util-linux \
    && microdnf clean all

COPY --from=aws-cli /usr/local/aws-cli /usr/local/aws-cli
COPY --from=busybox /bin/busybox /usr/local/bin/busybox

RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
    && ln -s /usr/local/bin/busybox /usr/local/bin/crond

RUN aws --version \
    && mysqldump --version \
    && gzip --version \
    && flock --version

COPY scripts/backup.sh /usr/local/bin/backup.sh
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod 0755 \
      /usr/local/bin/backup.sh \
      /usr/local/bin/entrypoint.sh \
      /usr/local/bin/healthcheck.sh \
    && mkdir -p /var/lib/mysql-backup /var/spool/cron/crontabs

ENV MYSQL_HOST=mysql \
    MYSQL_PORT=3306 \
    MYSQL_SSL_MODE=PREFERRED \
    S3_REGION=us-east-1 \
    BACKUP_CRON="0 3 * * *" \
    GZIP_LEVEL=6 \
    HEALTHCHECK_MAX_AGE_SECONDS=129600 \
    TZ=UTC

HEALTHCHECK --interval=5m --timeout=10s --retries=1 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
