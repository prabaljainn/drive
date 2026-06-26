helm install monitoring ./kube-prometheus-stack-86.2.0.tgz -n monitoring --create-namespace \
  -f deploy/monitoring/kube-prometheus-stack.values.yaml \
  -f deploy/monitoring/kube-prometheus-stack.prod-overrides.yaml
kubectl -n monitoring rollout status deploy/kps-operator
kubectl get crd | grep monitoring.coreos.com    # MUST list servicemonitors/prometheusrules BEFORE step E