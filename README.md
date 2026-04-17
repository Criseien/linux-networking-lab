# linux-networking-labs

Hands-on labs covering Linux networking from the kernel primitives up. Each lab starts from a real failure scenario — packets that disappear silently, mounts that fail after reboot, DNS that works from your workstation but not from the application — works through the mechanism at the system level, and connects explicitly to how Kubernetes uses the same underlying subsystem. The target environment is AlmaLinux 9 on bare metal.

## Why this matters for Kubernetes

Kubernetes networking is not an abstraction layered on top of Linux networking — it is Linux networking, automated. The primitives are identical:

- Every Kubernetes pod runs in its own network namespace, connected to the node via a veth pair. When pod networking breaks, the debugging path is the same as the namespace failure modes in this repo: check ip_forward, check the FORWARD chain, check MASQUERADE rules, verify the veth pair is up.
- kube-proxy in iptables mode creates `KUBE-SVC-*` chains that are probabilistic DNAT — the same `--match statistic --mode random` pattern implemented manually in the DNAT load balancing lab here.
- CoreDNS injects a `/etc/resolv.conf` into every pod with `ndots:5`. Understanding why `dig` resolves but the application fails — and what `nsswitch.conf` has to do with it — is the prerequisite for debugging pod DNS failures.
- A DROP target in firewalld on a bare-metal node silently kills pod networking before any iptables or kube-proxy rule ever sees the packet. This is one of the most common cluster bootstrap failures and is not diagnosed by looking at K8s logs.
- NFS PersistentVolumes with default export options silently break kubelet writes due to `root_squash`. The mount succeeds, the failure only appears when a pod writes.

---

## Labs

### namespaces

**Scenario:** Two network namespaces (`app-ns` and `db-ns`) need to communicate with each other and reach the internet through the host. Built manually from scratch — veth pairs, bridge, routes, NAT. Once built, a DROP rule is silently blocking egress.

**Covers:** the full manual CNI sequence (namespace → bridge → veth pairs → IP assignment → default routes → ip_forward → MASQUERADE), five failure modes (interface down, no default route, ip_forward disabled, MASQUERADE missing, FORWARD chain blocking), firewalld vs raw iptables as independent layers, and using `nsenter` to inspect a running namespace.

**K8s connection:** This is exactly what a CNI plugin does automatically when a pod starts. When a pod can't reach another pod or the internet, the debug flow is identical — the commands are the same, the scale is larger. `nsenter --net=/proc/<pid>/ns/net` gives you the same view as `ip netns exec` for pods running under containerd.

---

### iptables

**Scenario:** A network namespace is running a 3-backend DNAT load balancer. Traffic flows from the namespace to the internet but the FORWARD chain is silently dropping packets under specific conditions. `tcpdump` shows packets leaving the source but never arriving at the destination.

**Covers:** `filter`, `nat`, and `mangle` table responsibilities, packet traversal path (PREROUTING → routing decision → INPUT vs FORWARD → POSTROUTING), using `tcpdump` to bisect a packet path, FORWARD chain rule management (`-A`, `-I`, `-D` by position and by spec), custom logging chains, rule save/restore, and `ip_forward` as a prerequisite.

**K8s connection:** kube-proxy creates rules in `filter` and `nat` using these exact primitives. Each Service becomes a `KUBE-SVC-<hash>` chain (the load balancer) with per-endpoint `KUBE-SEP-<hash>` chains (the DNAT targets). The FORWARD chain issue in this lab is the same gap that causes cross-node pod failures when ip_forward is disabled on a node.

---

### iptables/dnat-load-balancing

**Scenario:** Three backends are running on port 8080. Traffic arrives on port 80. The goal is to split that traffic evenly between the three backends using only iptables — no Nginx, no HAProxy.

**Covers:** the `--match statistic --mode random` pattern, why equal-third probabilities decrease down the chain (each rule only sees unmatched traffic), a self-contained setup/verify/teardown script, and live packet counter monitoring with `watch`.

**K8s connection:** This is exactly what kube-proxy does for Services with multiple endpoints — the `KUBE-SVC-*` probability chain is this pattern at scale, with health check integration via endpoint watches. Reading `iptables -t nat -L KUBE-SVC-XXXX -n -v` becomes straightforward after building this manually.

---

### nat

**Scenario:** A network namespace can reach the host but cannot reach the internet (SNAT problem). Separately, external clients need to reach a service inside the namespace on port 8080 via the host's public IP on port 80 (DNAT problem).

**Covers:** SNAT vs DNAT mechanics, MASQUERADE vs static SNAT decision criteria (dynamic vs fixed IP), connection tracking as the mechanism that makes stateless NAT rules handle stateful sessions, DNAT requiring a companion FORWARD rule, the ip_forward dependency, and the firewalld vs raw iptables independence trap.

**K8s connection:** Pod-to-internet traffic is SNAT'd so pod IPs don't escape the cluster. NodePort and LoadBalancer Services are DNAT — external traffic hitting `<NodeIP>:NodePort` is rewritten to the pod IP:port. `sessionAffinity: ClientIP` in Services is conntrack. This lab is the substrate for all of that.

---

### dns

**Scenario:** An application on a server can't reach `app.internal`. The hostname resolves correctly from your workstation. The service is running. Nothing obvious is broken.

**Covers:** the correct diagnostic flow (application → `getent` → `dig`, never dig-first), why `dig` and system DNS resolution are not the same path, `nsswitch.conf` and how missing `dns` entry silently breaks all application resolution while `dig` continues working, `/etc/resolv.conf` directives (`nameserver`, `search`, `ndots`), `resolvectl` for systemd-resolved environments, and the common failure mode table.

**K8s connection:** CoreDNS injects `resolv.conf` with `ndots:5` into every pod. This causes names with fewer than 5 dots to be tried with each search domain before the absolute lookup — resulting in 4+ DNS queries for a simple `curl http://my-service`. Debugging pod DNS failures follows the exact same flow: `kubectl exec` into the pod → `cat /etc/resolv.conf` → `getent hosts <service>`.

---

### firewalld

**Scenario:** An nginx instance is running on port 8080 but is unreachable from outside the host. `ss -tlnp` confirms nginx is listening. The issue is above the process layer.

**Covers:** the diagnosis flow (process → tcpdump → firewalld), zone and target model (DROP vs REJECT vs default — and why DROP causes silent timeouts that look like connectivity failures), runtime vs permanent rule distinction, the `--add-port` vs `ACCEPT` target trap under pressure, firewalld vs raw iptables as independent layers, and nftables as the AlmaLinux 9 backend.

**K8s connection:** On bare-metal nodes, firewalld must have explicit rules for kubelet (10250/tcp), etcd (2379-2380/tcp), the API server (6443/tcp), and pod/service CIDRs. A DROP target is the most common cause of silent pod networking failures in bare-metal clusters — packets leave the pod, cross the CNI bridge, and are silently dropped by firewalld before any kube-proxy rule sees them.

---

### nfs

**Scenario:** A shared storage server needs to export `/srv/shared` so application nodes can mount it and write logs centrally. The mount must survive reboots and support multiple simultaneous clients. Secondary requirement: compatibility with Kubernetes PersistentVolumes.

**Covers:** reading NFS errors on client and server, four failure modes (connection timeout due to firewall or service down, writes failing despite successful mount due to `root_squash`, mount not surviving reboot, stale file handle), `/etc/exports` option semantics (`rw`, `sync`, `no_subtree_check`, `no_root_squash`), `exportfs -r` vs `exportfs -a`, and fstab configuration for persistent mounts.

**K8s connection:** An NFS PersistentVolume with `ReadWriteMany` access mode is exactly this setup — one of the few storage backends that supports concurrent writes from multiple pods. Without `no_root_squash`, kubelet mounts appear successful and writes silently fail. This failure is invisible in Kubernetes events until a pod tries to write and the application logs the error.

---

## Prerequisites

AlmaLinux 9 (or compatible RHEL 9 derivative). Root or sudo access. The namespace and iptables labs require `iproute2`, `iptables`, and `tcpdump`. The NFS lab requires `nfs-utils` on both server and client nodes.

## Recommended order

`namespaces` → `iptables` → `iptables/dnat-load-balancing` → `nat` → `firewalld` → `dns` → `nfs`. Namespaces first — the veth/bridge/ip_forward/MASQUERADE concepts from that lab appear in every subsequent one.
