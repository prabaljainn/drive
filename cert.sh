What's the exact error text? Most likely it's `x509: certificate is valid for ... not <node-ip>` or `certificate signed by unknown authority` — the fix differs. Meanwhile, here's the usual diagnosis path for MicroK8s HA:

**1. Check what the error actually says**

```bash
microk8s kubectl get pods 2>&1 | head -5
```

**2. Most common cause on Lightsail: node IP changed**

If node2/node3 were stopped/started and their IPs changed, their apiserver certs no longer match. Check:

```bash
# on node2/node3
hostname -I
sudo grep -r "IP\." /var/snap/microk8s/current/certs/csr.conf
```

If the current IP isn't in the cert's SAN list, refresh:

```bash
sudo microk8s refresh-certs --cert server.crt
```

**3. Check cert expiry** (MicroK8s CA certs are fine for years, but server certs can lapse if the auto-refresh didn't run):

```bash
sudo openssl x509 -in /var/snap/microk8s/current/certs/server.crt -noout -dates
```

**4. Check time sync** — clock skew breaks TLS validation:

```bash
timedatectl status
```

**5. If it's `certificate signed by unknown authority`**, node2/node3's kubeconfig may have a stale CA (can happen if node1 regenerated its CA after they joined). Compare:

```bash
sudo md5sum /var/snap/microk8s/current/certs/ca.crt   # run on all 3 nodes
```

If they differ, the clean fix is `microk8s leave` on the bad node, `microk8s remove-node <node>` on node1, then re-join.

**6. Nuclear-ish option that often just works:**

```bash
sudo snap restart microk8s
```

Paste the actual error and I can pin it down — also worth knowing whether node2/node3 were recently rebooted or whether this appeared out of nowhere.