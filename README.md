# ovn-mac-unlock

Disables source MAC filtering for selected pods on a [Kube-OVN](https://github.com/kubeovn/kube-ovn)
cluster without redeploying or forking Kube-OVN.

For every pod labelled `ovn-mac-unlock=true`, a small controller in `kube-system` keeps each of the
pod's OVN logical switch ports in this state:

- `port_security` empty: no source MAC/IP filtering.
- `unknown` in `addresses`: frames addressed to MACs other than the pod's own are delivered, and
  OVN learns MACs behind the port (FDB). This is needed for nested VMs, bridges, VRRP virtual MACs, etc.

This covers the primary interface (`<pod>.<namespace>`) and any Kube-OVN Multus attachments
(`<pod>.<namespace>.<provider>`, where the provider is usually `<nad>.<nad-namespace>.ovn`). Ports
are found from the pod's `<provider>.kubernetes.io/allocated` annotations. Attachments that only
use Kube-OVN for IPAM (e.g. macvlan) have no logical switch port and are skipped.

kube-ovn-controller resets these fields on pod updates and on resync, so the controller re-checks
every `INTERVAL` seconds (default 10). It writes only when something needs changing.

## Install

Set the image in `ovn-mac-unlock.yaml` to the same tag as your `kube-ovn-controller`. It uses the
stock image's `ovn-nbctl` and `kubectl`; nothing needs building. Then:

```sh
kubectl apply -k .
kubectl label pod <pod> -n <ns> ovn-mac-unlock=true   # or set the label in the pod template
kubectl -n kube-system logs deploy/ovn-mac-unlock -f
```

## Enabling per namespace with Gatekeeper

[`gatekeeper/`](gatekeeper/) has rules that make a namespace label control this, so you don't
have to label each pod:

- `AssignMetadata` mutation: labels new pods `ovn-mac-unlock=true` in namespaces labelled
  `ovn-mac-unlock=true`.
- `OvnMacUnlockRestricted` constraint: denies adding the pod label in any other namespace. Pods
  that already have it can still be updated.

```sh
kubectl apply -k gatekeeper/   # run twice on first install: the Constraint needs the template's CRD
kubectl label namespace <ns> ovn-mac-unlock=true
kubectl -n <ns> rollout restart deploy/<app>   # existing pods are only labelled when recreated
```

This needs Gatekeeper with mutation enabled (the default since 3.10). If you change
`LABEL_SELECTOR`, update the label in `mutation.yaml` and `constraint.yaml` to match. Removing the
namespace label stops new pods from getting the label; pods that already have it stay unlocked
until they're recreated.

## Configuration

Environment variables on the Deployment:

| Variable         | Default               | Notes                                                     |
|------------------|-----------------------|-----------------------------------------------------------|
| `LABEL_SELECTOR` | `ovn-mac-unlock=true` | Pods to unlock.                                           |
| `INTERVAL`       | `10`                  | Seconds between reconciles.                               |
| `ENABLE_SSL`     | `auto`                | `auto` tries tcp then ssl; `true`/`false` pins it.        |
| `TLS_DIR`        | `/var/run/tls`        | Where `kube-system/kube-ovn-tls` is mounted (optional).   |

The log shows which NB connection mode was used. If it can't connect, the log says why, e.g. SSL
appears to be on but the `kube-ovn-tls` secret is missing.

## Caveats

- All of a labelled pod's OVN interfaces are unlocked; you can't unlock just one of them.
- Without the Gatekeeper constraint, anyone who can label pods can turn filtering off for them.
- After kube-ovn-controller resets a port, it can take up to `INTERVAL` seconds to be fixed again.
