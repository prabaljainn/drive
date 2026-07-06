Your world2/world3 shards came back empty because the mariadb-operator re-initializes a fresh datadir when the PVC is gone — system DBs only, no schema. Everything you need is already in the airgap bundle at helm/spider-sharding/deploy-kit/02-RUNBOOK.md (steps 5–9); here's the exact sequence scoped to world2/3 only (world1 + spider are intact — don't touch them).

cd <repo>   # your airgap copy
source helm/spider-sharding/deploy-kit/00-VARS.sh   # NS, DATAID bases, PW(), sql_primary()
SD=helm/spider-sharding

1. Schema load (runbook Step 5) — via the primary service, root creds from operator secret:

DBINIT="helm/ichimill-rtk/files/db-init"
for c in mariadb-world2 mariadb-world3; do
  RP=$(kubectl -n $NS get secret ${c}-root -o go-template='{{index .data "password"|base64decode}}')
  for f in $DBINIT/0000000{1,2,4,5,6,7,8,9}_*.sql $DBINIT/00000099_*.sql; do
    kubectl exec -i ${c}-0 -n $NS -c mariadb -- \
      env MYSQL_PWD="$RP" mariadb --skip-ssl -h ${c}-primary.$NS.svc.cluster.local -uroot < "$f"
  done
done

2. Fix users — known trap. The datadir wipe erased mysql.user, but the User/Grant CRs still say "Created" so the operator won't re-reconcile them → Access denied as prabal. Test, and if denied, bounce the CRs:

sql_primary mariadb-world2 prabal <<<"SELECT 1;"   # if Access denied:
kubectl -n $NS delete users.k8s.mariadb.com,grants.k8s.mariadb.com -l k8s.mariadb.com/mariadb=mariadb-world2
kubectl -n $NS delete users.k8s.mariadb.com,grants.k8s.mariadb.com -l k8s.mariadb.com/mariadb=mariadb-world3
kubectl apply -f $SD/10-mariadb-world-shards.yaml -f $SD/12-app-user.yaml
(if the label selector matches nothing, list them with kubectl get users,grants -n $NS and delete the world2/3 ones by name)

3. Dedup UNIQUE key (Step 5b) — else register's ON DUPLICATE silently no-ops:

for c in mariadb-world2 mariadb-world3; do sql_primary $c prabal < $SD/31-analysis-dedup-uniquekey.sql; done

4. Daily partitions — installs the procs that the nightly partition-archive cron calls; without them ingest eventually hits errno 1526:

for c in mariadb-world2 mariadb-world3; do sql_primary $c prabal < $SD/32-daily-partitions.sql; done

5. data_id disjoint bases (Step 9) — critical. The fresh seed reset data_id_sequence to world1's range → data_id collisions across shards. Safe now because the shards are empty:

sed "s/__DATAID_BASE__/$DATAID_BASE_WORLD2/" $SD/34-dataid-ranges.sql | sql_primary mariadb-world2 prabal
sed "s/__DATAID_BASE__/$DATAID_BASE_WORLD3/" $SD/34-dataid-ranges.sql | sql_primary mariadb-world3 prabal
for c in mariadb-world2 mariadb-world3; do echo -n "$c base="; sql_primary $c prabal <<<"SELECT id FROM IOT_RTK.data_id_sequence;"; done
# want 100000000000 and 200000000000

6. Reference data — do NOT hand-seed. The SPIDER node's IOT_RTK_MASTER (incl. device_master with world_id already seeded) is intact; the refdata-sync CronJob pushes it to all shards. Trigger it now instead of waiting:

kubectl create job --from=cronjob/refdata-sync refdata-resync-manual -n $NS
kubectl logs -n $NS job/refdata-resync-manual -f
sql_primary mariadb-world2 prabal <<<"SELECT COUNT(*) FROM IOT_RTK_MASTER.device_master;"

Skip 33-seed-world-id.sql (lives on spider, untouched) and never run 34 against world1 (non-empty).

7. Verify the path end-to-end:
- Replicas caught up: kubectl exec -n $NS mariadb-world2-<replica> -c mariadb -- ... "SHOW SLAVE STATUS\G" → both threads Yes (schema replicates automatically since you loaded via the primary service).
- SPIDER reads work again (wrappers point at service names, nothing to redo there): sql_primary mariadb-spider prabal <<<"SELECT COUNT(*) FROM IOT_RTK.analysis_all_data;" — must not error.
- Bounce the world2/3 registers (kubectl rollout restart deploy -l ...world2/world3 per 42-/43-*-pipeline.yaml) — they were likely crashlooping against the wiped DBs — then confirm telemetry rows land.