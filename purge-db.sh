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





=================================



Two important corrections:
- Everything I measured earlier was the cloud ichimill.in cluster (my kubectl points there — I can't reach your airgapped env). So ignore those 63G/role numbers for this box. I ran only read-only queries there; nothing was changed on either cluster.
- You can't fix this with SQL (TRUNCATE/PURGE) because mysqld won't stay up to accept a connection. You have to free space at the filesystem/volume level first.

Recovery (you run these against the airgap cluster)

First confirm the primaries (-0) are healthy and have room — the replicas rebuild from them:

kubectl -n mariadb get pods | grep world
for w in 1 2 3; do echo "world$w-0:"; kubectl -n mariadb exec mariadb-world$w-0 -c mariadb -- df -h /var/lib/mysql | tail -1; done

Path A — cleanest for your goal (you wanted a fresh slate anyway): delete the full replica PVC+pod and let the operator rebuild a small, clean replica from the primary.

for w in 1 2 3; do
  kubectl -n mariadb delete pvc storage-mariadb-world$w-1 &   # frees the disk
  kubectl -n mariadb delete pod mariadb-world$w-1
done
Operator re-provisions the PVC and resyncs from the primary (the PreferReplica self-heal). Fresh replica = primary's ~small dataset, none of the 60G of self-inflicted binlogs. On a dev throughput box a GTID data-gap on the replica doesn't matter.

Path B — if the operator won't auto-rebuild / you want to keep the data: expand the full PVC just enough to boot (Longhorn online, no detach), then reclaim properly via SQL.

kubectl get sc longhorn-galera -o jsonpath='{.allowVolumeExpansion}{"\n"}'   # must be true
# bump each full replica PVC to current+20Gi
kubectl -n mariadb patch pvc storage-mariadb-world1-1 --type merge -p '{"spec":{"resources":{"requests":{"storage":"<cur+20>Gi"}}}}'
# ...repeat world2-1, world3-1. Once booted, purge the real hog:
RP=$(kubectl -n mariadb get secret mariadb-world1-root -o jsonpath='{.data.password}' | base64 -d)
kubectl -n mariadb exec mariadb-world1-1 -c mariadb -- mariadb -uroot -p"$RP" -e "FLUSH BINARY LOGS; PURGE BINARY LOGS BEFORE NOW();"
Note: PVCs can't shrink afterward, so don't over-expand on your 64GB VMs.

Prevent the refill (this is the actual root cause)

The replicas fill their own disk because log_slave_updates=1 makes each replica write its own full binlog stream, and binlog_expire_logs_seconds=86400 keeps a full day of it. On tiny airgap disks under a throughput test that's fatal. Once they're back up:

for w in 1 2 3; do for i in 0 1; do
  kubectl -n mariadb exec mariadb-world$w-$i -c mariadb -- mariadb -uroot -p"$RP" -e \
    "SET GLOBAL binlog_expire_logs_seconds = 3600;"   # 1h instead of 24h
done; done
And to persist + stop replicas generating their own binlogs at all (they don't need it — no downstream replica), set binlog_expire_logs_seconds: 3600 and drop log_slave_updates in the MariaDB CR / my.cnf and reconcile.

Which path do you want — the clean rebuild (A) or expand-and-keep (B)? And can you paste kubectl -n mariadb get pods | grep world output so I can see whether the primaries are healthy before you delete anything?
