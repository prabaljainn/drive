Is it OK to delete on dev? Yes — it's test data. Do it on the primary (world1-1); truncates replicate to the replica automatically.

Commands, in order

RP=$(kubectl -n mariadb get secret mariadb-world1-root -o jsonpath='{.data.password}' | base64 -d)

# 1. Clean slate: truncate telemetry on the PRIMARY (replicates to replica; reclaims ~7.3G on both)
kubectl -n mariadb exec mariadb-world1-1 -c mariadb -- mariadb -uroot -p"$RP" -e "
  TRUNCATE TABLE IOT_RTK_RECEIVE.receive_all_data;
  TRUNCATE TABLE IOT_RTK.analysis_all_data;
  TRUNCATE TABLE IOT_RTK.latest_location_data;"

# 2. Let the replica apply the truncates (wait for 0)
kubectl -n mariadb exec mariadb-world1-0 -c mariadb -- mariadb -uroot -p"$RP" -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master

# 3. Reclaim the 63G of binlogs — run on BOTH nodes.
#    BEFORE NOW() auto-keeps any log a connected replica still needs, so it's safe on the primary too.
for i in 0 1; do
  kubectl -n mariadb exec mariadb-world1-$i -c mariadb -- mariadb -uroot -p"$RP" -e "
    FLUSH BINARY LOGS;
    PURGE BINARY LOGS BEFORE NOW();"
done

# 4. Stop it refilling next run: drop binlog retention to 1h (runtime; add to the CR to persist)
for i in 0 1; do
  kubectl -n mariadb exec mariadb-world1-$i -c mariadb -- mariadb -uroot -p"$RP" -e \
    "SET GLOBAL binlog_expire_logs_seconds = 3600;"
done

Net reclaim: ~7G tables + ~63G binlogs ≈ 70G on the replica, ~25G on the primary.