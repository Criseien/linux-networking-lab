# NAT & Masquerading

## Scenario

A network namespace (`app-ns`) can reach the host but cannot reach the
internet. Separately, external clients need to reach a service running
inside the namespace on port 8080 via the host's public IP on port 80.

Two distinct NAT problems:
1. **SNAT/Masquerading** — namespace-to-internet (hide private source IP)
2. **DNAT/Port forwarding** — internet-to-namespace (rewrite destination)

## SNAT — Masquerading

Source NAT rewrites the source IP of packets leaving the host so the
internet sees the host's IP, not the namespace's private IP.
Return traffic is automatically de-NATted via connection tracking.

```bash
# MASQUERADE — dynamic SNAT (IP resolved per packet from outgoing interface)
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE

# SNAT — static SNAT (IP hardcoded, faster)
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j SNAT --to-source 192.168.1.10
```

Also requires ip_forward to be enabled on the host:

```bash
sysctl -w net.ipv4.ip_forward=1
# Make persistent:
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
```

**Retrieval (8 Mar):** resolved with `firewall-cmd --add-masquerade`.
Gap: did not verify the underlying iptables rule that firewalld creates.
Always check both layers:

```bash
firewall-cmd --zone=public --query-masquerade    # firewalld state
iptables -t nat -L POSTROUTING -n -v             # actual iptables rule
```

## DNAT — Port Forwarding

Destination NAT rewrites the destination IP/port of incoming packets,
redirecting them to a backend. Applied in PREROUTING (before routing decision).

```bash
# Forward external port 80 to namespace service on 10.10.0.2:8080
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.10.0.2:8080

# Also need FORWARD rule to allow the forwarded traffic
iptables -A FORWARD -d 10.10.0.2 -p tcp --dport 8080 -j ACCEPT
```

## MASQUERADE vs SNAT — Decision Criteria

| | MASQUERADE | SNAT |
|---|---|---|
| **Source IP** | Resolved dynamically from outgoing interface | Hardcoded with `--to-source` |
| **Use when** | Dynamic IP (DHCP, cloud instance with changing IP) | Static IP (bare metal, fixed interface) |
| **Performance** | Slightly slower (IP lookup per packet) | Faster (no lookup needed) |
| **Typical use** | Developer VM, laptop, cloud instance | Production server, bare metal node |

## Connection Tracking (conntrack)

NAT works because the kernel tracks the connection state. Return packets
are automatically rewritten to undo the NAT without explicit reverse rules.

```bash
# View active NAT sessions
conntrack -L

# View specific connection
conntrack -L --src 10.10.0.2

# Count tracked connections
conntrack -C
```

Connection tracking enables **session affinity**: once a connection is
mapped (e.g., DNAT to backend A), all subsequent packets in that session
go to the same backend — even if load balancing rules would normally
route differently.

## Verifying NAT Is Working

```bash
# Test SNAT — ping from namespace, verify source IP on the wire
ip netns exec app-ns ping -c 3 8.8.8.8

# On host, capture outgoing traffic — should show host IP as source
tcpdump -i eth0 icmp

# Test DNAT — connect to host IP on port 80, should reach internal service
curl http://<host-ip>:80

# Verify NAT table
iptables -t nat -L -n -v

# Verify conntrack entry is created
conntrack -L | grep 10.10.0.2
```

## Traps

**Forgetting ip_forward:** MASQUERADE rule exists but traffic still doesn't
flow. The kernel drops forwarded packets silently if `ip_forward = 0`.
Check with `sysctl net.ipv4.ip_forward` — it must be `1`.

**Forgetting FORWARD rule for DNAT:** DNAT rewrites the destination, but
the `filter` FORWARD chain still needs to ACCEPT the rewritten packet.
DNAT happens in `nat/PREROUTING`, FORWARD check happens after.

**firewalld masquerade ≠ iptables masquerade:** `firewall-cmd --add-masquerade`
creates a MASQUERADE rule in iptables, but reporting `--query-masquerade no`
does not mean the rule is absent — it may have been added directly via iptables.
Both layers are independent.

## Key Commands

```bash
# SNAT
iptables -t nat -A POSTROUTING -s <src-cidr> -o <interface> -j MASQUERADE
iptables -t nat -A POSTROUTING -s <src-cidr> -o <interface> -j SNAT --to-source <ip>

# DNAT
iptables -t nat -A PREROUTING -p tcp --dport <port> -j DNAT --to-destination <ip:port>

# Inspect NAT table
iptables -t nat -L -n -v
iptables -t nat -L -n -v --line-numbers

# ip_forward
sysctl net.ipv4.ip_forward
sysctl -w net.ipv4.ip_forward=1

# conntrack
conntrack -L
conntrack -L --src <ip>
conntrack -C            # total connection count
conntrack -D --src <ip> # delete specific entries
```

## K8s Connection

Kubernetes uses NAT extensively at the cluster networking layer:

**Pod → Internet (SNAT):** CNI plugins add MASQUERADE/SNAT rules so pod
traffic leaving the node appears to originate from the node IP — the same
pattern as the namespace lab. Without this, return packets wouldn't know
how to reach the pod (private IP unreachable from internet).

**NodePort / LoadBalancer (DNAT):** External traffic hitting `<NodeIP>:NodePort`
is DNAT'd by kube-proxy to the pod IP:port — identical to the PREROUTING
DNAT rules practiced here. `KUBE-SVC-*` chains in iptables are just
structured DNAT with load balancing (the `statistic --mode random` pattern
from the namespace lab, at scale).

**Connection tracking in K8s:** Session affinity in Services (`sessionAffinity: ClientIP`)
leverages the same conntrack mechanism — the kernel remembers which backend
a client was mapped to and sends subsequent requests there.
