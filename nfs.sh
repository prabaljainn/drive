Yes — nfs-utils 2.6.4 is the current Ubuntu 24.04 client. Supports NFSv4.2, nconnect, hard mounts. Nothing to upgrade.

Here's the ordered path, assuming static NFS PV (decided) and that you'll stand up a dev export since there's none:

1. Confirm the client on all 3 nodes (a batch pod can land anywhere):
for n in <node1> <node2> <node3>; do ssh $n 'which mount.nfs || echo MISSING'; done

2. Stand up the export on one VM (only if you want a dev test; prod uses SoftBank's):
sudo dpkg -i nfsd-debs/*.deb          # nfs-kernel-server, grabbed as before
sudo mkdir -p /srv/nfs/cold && sudo chmod 777 /srv/nfs/cold
echo '/srv/nfs/cold <DEV-VLAN-CIDR>(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
sudo exportfs -ra && sudo systemctl enable --now nfs-kernel-server

3. Prove the mount from each node — no k8s yet (this is the real gate; if it passes, the PV is guaranteed to mount):
sudo mount -t nfs4 <NFS_SERVER>:/srv/nfs/cold /mnt && touch /mnt/probe && sudo umount /mnt

4. Migrate existing cold data — the current batch-s3-pvc holds live download zips on longhorn. Only if users still need them: scale down, cp -a old→NFS via a one-off pod. If it's just regenerable staging, skip.

5. Pre-create the NFS PV, reserved for the existing PVC:
apiVersion: v1
kind: PersistentVolume
metadata: { name: batch-cold-nfs }
spec:
  capacity: { storage: 500Gi }
  accessModes: [ReadWriteMany]
  nfs: { server: <NFS_SERVER>, path: /srv/nfs/cold }
  mountOptions: [nfsvers=4.1, hard, nconnect=8]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef: { namespace: default, name: batch-s3-pvc }

6. Recreate the PVC onto NFS (PVC spec is immutable — must delete first):
kubectl apply -f batch-cold-nfs-pv.yaml
kubectl scale deploy/batch-workers deploy/backend --replicas=0
kubectl delete pvc batch-s3-pvc
# helm values: pvc.batchS3 -> storageClass: "", accessMode: ReadWriteMany, size: 500Gi
helm upgrade ...   # read project_helm_release_repaired first

7. Verify:
kubectl get pvc batch-s3-pvc          # Bound -> batch-cold-nfs
kubectl exec deploy/batch-workers -- sh -c 'touch /mnt/s3/dl_storage/.probe && ls -l /mnt/s3/dl_storage/.probe'
ls -l /srv/nfs/cold/.probe            # on the NFS server — confirms it landed off-cluster

Gate at step 3: if the host mount fails, stop — k8s will only reproduce the same failure. skipped: data migration if dl_storage is regenerable. Same <NFS_SERVER>/path also fill the __NFS_SERVER__/__NFS_PATH__ placeholders in 51-partition-archive.yaml.

Want me to write steps 5–6 as a committed manifest + the helm values delta in the repo, and wire the 51- archive CronJob to the same export in one pass?


========================



Pick one volume for cold data (vol1 = /nfs01). Next commands:

A. Carve a cold-data dir on the export (via the host mount you already have):
sudo mkdir -p /nfs01/dl_storage && sudo chmod 777 /nfs01/dl_storage

B. Check the NFS version the SVM negotiated (so the PV mount options match):
mount | grep /nfs01     # note vers=4.1 or vers=3

C. Confirm the other 2 k8s nodes reach the filer (a batch pod can land on any):
for n in <node2> <node3>; do ssh $n 'sudo mount -t nfs 10.169.12.10:/svm_00022_vol1 /mnt && sudo umount /mnt && echo OK || echo FAIL'; done

D. PV + reserve it for the existing PVC (set nfsvers to what step B showed):
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
  claimRef: { namespace: default, name: batch-s3-pvc }

E. Recreate batch-s3-pvc onto NFS (PVC spec is immutable → delete first):
kubectl apply -f batch-cold-nfs-pv.yaml
kubectl scale deploy/batch-workers deploy/backend --replicas=0
kubectl delete pvc batch-s3-pvc
# helm values pvc.batchS3: storageClass "", accessMode ReadWriteMany, size 2Ti
helm upgrade ...   # read project_helm_release_repaired first

F. Verify it lands off-cluster:
kubectl get pvc batch-s3-pvc          # Bound -> batch-cold-nfs
kubectl exec deploy/batch-workers -- sh -c 'touch /mnt/s3/dl_storage/.probe'
ls -l /nfs01/dl_storage/.probe        # appears here = cold data is on the NetApp

Two NetApp gotchas: if step B shows vers=3, change nfsvers=4.1→nfsvers=3 in the PV (else it hangs). And if the pod writes as root and the SVM export policy squashes root to nobody, the chmod 777 in step A is what saves you — keep it.

Note before E: the current batch-s3-pvc holds live download zips on longhorn — migrate them to /nfs01/dl_storage first if users still fetch them, otherwise they vanish on the delete.

Want me to commit the PV + helm values delta, and point the 51-partition-archive archive CronJob at 10.169.12.10:/svm_00022_vol2 (keep DB cold-tier on a separate volume from download storage) in the same pass?