# ovn-mac-unlock

Disables source MAC filtering for selected pods on a [Kube-OVN](https://github.com/kubeovn/kube-ovn)
cluster without redeploying or forking Kube-OVN.

For every pod labelled `ovn-mac-unlock=true`, a small controller in `kube-system` keeps the pod's
OVN logical switch port (`<pod>.<namespace>`) in this state:

- `port_security` empty: no source MAC/IP filtering.
- `unknown` in `addresses`: frames addressed to MACs other than the pod's own are delivered, and
  OVN learns MACs behind the port (FDB). This is needed for nested VMs, bridges, VRRP virtual MACs, etc.

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

- Only the pod's primary Kube-OVN interface is handled; Multus attachments (`<pod>.<ns>.<provider>`) are not.
- Anyone who can label pods can turn filtering off for them. Restrict the label (e.g. with a
  Gatekeeper constraint) if that matters.
- After kube-ovn-controller resets a port, it can take up to `INTERVAL` seconds to be fixed again.
