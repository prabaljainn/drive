
dd — always present, no install (airgap-friendly), and cold-data = large sequential zips, which is exactly what dd sequential measures. fio is better for random IOPS but you can't apt-get it here.

The one trap: without cache-busting you measure page cache, not disk — you'll get fake multi-GB/s numbers. So flush on write, drop caches before read.

Write (NFS vs local block):
# NFS (NetApp)
dd if=/dev/zero of=/nfs01/dl_storage/ddtest bs=1M count=2048 conv=fdatasync 2>&1 | tail -1
# local block disk (proxy for Longhorn/NVMe)
dd if=/dev/zero of=/data01/ddtest bs=1M count=2048 conv=fdatasync 2>&1 | tail -1

Read (drop caches first, or it lies):
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
dd if=/nfs01/dl_storage/ddtest of=/dev/null bs=1M 2>&1 | tail -1
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
dd if=/data01/ddtest of=/dev/null bs=1M 2>&1 | tail -1

Cleanup:
rm -f /nfs01/dl_storage/ddtest /data01/ddtest

For the true apples-to-apples (NFS vs Longhorn, not local disk), run the same dd inside a pod on a Longhorn PVC — but for a cold tier that's overkill; local-disk vs NFS already tells you the network penalty.
