Since it's airgapped and you want to move fast, don't helm upgrade yet — that reverts live image-tag overrides and can trigger pulls that fail with no registry (project_helm_release_repaired trap). Just patch the two live deployments' volumes directly. This touches only the volume — same images (no pull), and it leaves the old longhorn PVC intact (your existing zips stay recoverable until you delete it during hardening).

Run these on the cluster node:

# 1. Every node a pod might land on must reach the filer (this one already has /nfs01).
for n in $(microk8s kubectl get nodes -o name); do echo "$n:"; done   # list nodes
#    On node2 / node3, prove reachability:
sudo mount -t nfs 10.169.12.10:/svm_00022_vol1 /mnt && sudo umount /mnt && echo OK

# 2. Flip both deployments PVC -> inline NFS (strategic merge; null clears the PVC source)
microk8s kubectl patch deploy batch-workers -p \
 '{"spec":{"template":{"spec":{"volumes":[{"name":"s3-mount","persistentVolumeClaim":null,"nfs":{"server":"10.169.12.10","path":"/svm_00022_vol1/dl_storage"}}]}}}}'

microk8s kubectl patch deploy backend-batch -p \
 '{"spec":{"template":{"spec":{"volumes":[{"name":"s3-volume","persistentVolumeClaim":null,"nfs":{"server":"10.169.12.10","path":"/svm_00022_vol1/dl_storage"}}]}}}}'

# 3. Watch the rollout + prove writes land on the NetApp
microk8s kubectl rollout status deploy/batch-workers
microk8s kubectl rollout status deploy/backend-batch
microk8s kubectl exec deploy/batch-workers -- sh -c 'mount | grep dl_storage'   # 10.169.12.10:/svm_00022_vol1/dl_storage
microk8s kubectl exec deploy/batch-workers -- sh -c 'touch /mnt/s3/dl_storage/.probe'
ls -l /nfs01/dl_storage/.probe    # on the node -> confirms cold data is on the filer

If step 3's mount shows the NFS line and .probe appears in /nfs01/dl_storage, downloads now write and serve from the NetApp. Roll back instantly by re-patching nfs:null + persistentVolumeClaim:{"claimName":"batch-s3-pvc"}.

Deferred to hardening (your call — not now):
- helm upgrade to persist (repo already edited; needs your live image-tag --sets so airgap doesn't try to pull).
- migrate old zips off the longhorn batch-s3-pvc, then delete it (frees 50 Gi).
- point 51-partition-archive CronJob at 10.169.12.10:/svm_00022_vol2 (keep DB cold-tier off the download volume).
- lock down the export policy / perms (777 is smoke-test-loose).

skipped: helm now (image-revert risk in airgap) → kubectl patch, same images, no pull. skipped: PVC delete → left intact so your current zips survive the switch.

Want me to save the NetApp filer details (10.169.12.10, 3× 2.5 T vols) to memory so future sessions know real NFS exists here — it contradicts the old "dev has no NFS" note?

✻ Baked for 4m 19s

❯ I have to do D. PV + reserve it for the existing PVC (set nfsvers to what step B showed):
  apiVersion: v1
  kind: PersistentVolume
  metadata: { name: batch-cold-nfs }
  spec:
    capacity: { storage: 2Ti }
    accessModes: [ReadWriteMany]
    nfs: { server: 10.169.12.10, path: /svm_00022_vol1/dl_storage }
    mountOptions: [nfsvers=4.1, hard, nconnect=8]
    persistentVolumeReclaimPolicy: Retain
    storageClassName: ""
    claimRef: { namespace: default, name: batch-s3-pvc } or not now?

Not now — skip D entirely. That PV is the other approach; you already chose inline.

The two are mutually exclusive — pick one, never both:

┌───────────────────┬─────────────────────────────────────┬───────────────────────────┐
│                   │           PV/PVC (step D)           │ Inline NFS (what you did) │
├───────────────────┼─────────────────────────────────────┼───────────────────────────┤
│ Objects to create │ PV + PVC                            │ none                      │
├───────────────────┼─────────────────────────────────────┼───────────────────────────┤
│ Deployment volume │ persistentVolumeClaim: batch-s3-pvc │ nfs: {server, path}       │
├───────────────────┼─────────────────────────────────────┼───────────────────────────┤
│ You said          │ "not doing PVC" ✗                   │ ✓                         │
└───────────────────┴─────────────────────────────────────┴───────────────────────────┘

The kubectl patch put the NFS source directly in the pod spec. Nothing references a PVC anymore (batchS3.enabled: false in the repo), so a PV with claimRef: batch-s3-pvc would bind to a claim that doesn't exist — it'd just sit Available doing nothing.

So: don't apply that PV. Your config now lives entirely in the two deployments (batch-workers s3-mount, backend-batch s3-volume). The nfsvers/nconnect/hard tuning from that PV isn't lost forever — inline volumes just can't carry mountOptions, so the client negotiates it (you already saw it pick vers=4.2, hard). If you later want to pin those options, that's the one reason to switch to the PV route — not today.

Step D was Plan B. You're on Plan A. Two plans, one mount — don't run both.

✻ Churned for 19s

❯ is it good? and does both use same pvc?

Yes, it's good — and yes, both point at the same storage. That's the important part and you got it right.

Is it good? For this case, yes:
- Matches your existing pattern (51-partition-archive.yaml inline nfs:).
- No PV/PVC objects to manage, no dynamic provisioner, airgap-clean.
- NFS is natively shared-writable, so two pods on any nodes both reach it — no RWO co-location constraint you'd have had on plain Longhorn.
- Only trade-off: inline can't carry mountOptions, so version is negotiated (you saw vers=4.2, hard — fine). Switch to the PV route only if you ever need to pin nfsvers/nconnect.

Same storage — both deployments:

┌─────────────────────────────────┬─────────────┬─────────────────────────────────────────┐
│           Deployment            │ Volume name │                Points at                │
├─────────────────────────────────┼─────────────┼─────────────────────────────────────────┤
│ batch-workers (writes the zips) │ s3-mount    │ 10.169.12.10:/svm_00022_vol1/dl_storage │
├─────────────────────────────────┼─────────────┼─────────────────────────────────────────┤
│ backend-batch (serves the zips) │ s3-volume   │ 10.169.12.10:/svm_00022_vol1/dl_storage │
└─────────────────────────────────┴─────────────┴─────────────────────────────────────────┘

Same server, same path — that's mandatory, not optional. batch-workers writes a download zip → backend serves it from the identical directory. If they pointed at different paths, every download would 404. Both my repo edits and both kubectl patch commands use coldNfs.server/coldNfs.path (the same values), so they're guaranteed identical.

So: no PVC anymore (inline replaced it), but the shared-directory guarantee the PVC used to provide is preserved — both now share the same NFS export instead of the same batch-s3-pvc.

Before: both → same PVC (batch-s3-pvc, RWX). Now: both → same NFS path. Shared either way; that's the requirement.

Verify it's actually shared after rollout:
microk8s kubectl exec deploy/batch-workers -- sh -c 'echo hi > /mnt/s3/dl_storage/.shared'
microk8s kubectl exec deploy/backend-batch -- sh -c 'cat /mnt/s3/dl_storage/.shared'   # prints "hi" = same dir






