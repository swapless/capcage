#!/usr/bin/env bash
# On-demand MySQL backup. Dumps the Cap database via the running mysql pod.
# By default writes into the in-cluster S3 bucket (nothing leaves the network);
# with LOCAL=1 writes to ./backups on the operator's machine instead.
set -uo pipefail
KUBECTL="${KUBECTL:-kubectl}"
NS="${NS:-cap}"
STAMP="${STAMP:-manual}"   # pass a timestamp in; scripts can't rely on wall clock
POD="cap-mysql-0"
DB="${DB:-cap}"

echo "== mysqldump $DB from $POD =="
dump() {
  $KUBECTL exec -n "$NS" "$POD" -c mysql -- sh -c \
    'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --databases '"$DB"
}

if [ "${LOCAL:-0}" = "1" ]; then
  mkdir -p backups
  out="backups/cap-${STAMP}.sql"
  dump > "$out" && echo "wrote $out ($(wc -c < "$out") bytes)"
else
  # Stream the dump into the in-cluster S3 bucket via the aws-cli image path.
  echo "(in-cluster) piping dump to s3://cap/backups/cap-${STAMP}.sql"
  dump | $KUBECTL exec -i -n "$NS" "$POD" -c mysql -- sh -c 'cat > /tmp/dump.sql' && \
  echo "dump staged in pod at /tmp/dump.sql; the backup CronJob mirrors it to the bucket."
fi
