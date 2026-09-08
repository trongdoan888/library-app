# Ảnh nhỏ chỉ để chạy pg_dump/psql (khớp server Postgres 16) theo lịch.
FROM postgres:16-alpine

RUN apk add --no-cache bash tzdata coreutils

COPY backup-loop.sh /usr/local/bin/backup-loop.sh
RUN chmod +x /usr/local/bin/backup-loop.sh

# Chạy như root để ghi được lên CIFS volume (mount bằng uid=0).
ENTRYPOINT ["/usr/local/bin/backup-loop.sh"]
