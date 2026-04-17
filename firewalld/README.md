# firewalld / nftables

## Scenario

An nginx instance is running on port 8080 but is unreachable from outside
the host. `ss -tlnp` confirms nginx is listening. The issue is above the
process layer.

Your job: diagnose whether firewalld is blocking the traffic, identify
the specific rule causing the drop, and restore access without opening
the firewall wider than necessary.

## Diagnosis Flow

```bash
# 1. Confirm the process is actually listening
ss -tlnp | grep 8080

# 2. Capture traffic to see if packets arrive at the host at all
tcpdump -i eth0 port 8080

# 3. If packets arrive but get no response — firewalld is blocking
firewall-cmd --list-all

# 4. Check zone target (DROP = silent drop, REJECT = ICMP unreachable)
firewall-cmd --zone=public --query-target
```

## Root Cause

Zone target was set to `DROP`. Every incoming packet not explicitly allowed
is silently dropped — no RST, no ICMP, just timeout. This is the failure mode
that under K8s looks like a pod can't reach a node: the connection hangs
instead of failing fast.

> "Pod cannot reach another node: silent timeout = DROP in firewalld, not a connectivity failure."

## Fix

```bash
# Open the specific port (runtime = immediate, permanent = survives reboot)
firewall-cmd --zone=public --add-port=8080/tcp --permanent
firewall-cmd --reload

# Reset target to default (allows established connections, drops new uninvited ones)
firewall-cmd --zone=public --set-target=default --permanent
firewall-cmd --reload

# Verify
firewall-cmd --list-all
curl http://localhost:8080
```

## Concepts: Zones & Targets

firewalld uses **zones** to group interfaces and apply policies.
The **target** defines how unmatched traffic is handled:

| Target | Behavior | Use case |
|---|---|---|
| `default` | Follow chain default (usually ACCEPT established, DROP new uninvited) | Standard server |
| `ACCEPT` | Accept all traffic (**dangerous** — bypasses all rules) | Never in production |
| `DROP` | Silently drop unmatched traffic | High-security perimeter |
| `REJECT` | Drop + send ICMP unreachable | Helpful for debugging (fast failure) |

**The trap under pressure:** reaching for `ACCEPT` as a "quick fix" opens
the host to all traffic. The correct approach is `default` + explicit `--add-port`.

## Runtime vs Permanent

firewalld has two layers:

```bash
# Runtime only (immediate effect, lost on reload/reboot)
firewall-cmd --add-port=8080/tcp

# Permanent only (survives reboot, requires reload to take effect)
firewall-cmd --add-port=8080/tcp --permanent
firewall-cmd --reload

# Both at once
firewall-cmd --add-port=8080/tcp --permanent
firewall-cmd --runtime-to-permanent   # promote current runtime to permanent
```

Always use `--permanent` + `--reload` in production. Runtime-only changes
disappear after the next `firewall-cmd --reload` or reboot.

## Key Commands

```bash
# Zone inspection
firewall-cmd --list-all                         # active zone full view
firewall-cmd --get-active-zones                 # which zones are active
firewall-cmd --zone=public --list-ports         # open ports in zone

# Port management
firewall-cmd --zone=public --add-port=10250/tcp --permanent
firewall-cmd --zone=public --remove-port=10250/tcp --permanent
firewall-cmd --reload

# Target management
firewall-cmd --zone=public --set-target=default --permanent
firewall-cmd --zone=public --query-target

# Masquerade (SNAT for outgoing traffic)
firewall-cmd --zone=public --add-masquerade --permanent
firewall-cmd --zone=public --query-masquerade

# Rich rules (advanced matching)
firewall-cmd --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" accept'
```

## firewalld vs Raw iptables — Two Separate Layers

firewalld manages nftables (or iptables in legacy mode) under the hood, but
raw rules inserted via `iptables` or `nft` bypass firewalld entirely and
persist independently.

```bash
# firewalld says masquerade is off
firewall-cmd --zone=public --query-masquerade   # → no

# But a raw MASQUERADE rule may still exist
iptables -t nat -L POSTROUTING -n -v            # → MASQUERADE rule visible

# Both layers must be checked when diagnosing NAT issues
```

This separation is also why kubelet port (10250) and other K8s ports opened
via `firewall-cmd` can coexist with kube-proxy iptables rules without conflict —
they operate in different layers.

## nftables — The Backend

AlmaLinux 9 uses nftables as the backend for firewalld. Direct `nft` commands
are available for lower-level inspection:

```bash
nft list ruleset          # full ruleset (all tables and chains)
nft list table inet firewalld   # firewalld-managed rules only
```

In practice, `firewall-cmd` covers all common operations. Drop to `nft`
only when debugging unexpected rule interactions.

## K8s Connection

On bare-metal Kubernetes nodes, firewalld must either be disabled or have
explicit rules for:

- `10250/tcp` — kubelet API
- `2379-2380/tcp` — etcd (control plane)
- `6443/tcp` — API server
- Pod CIDR and Service CIDR ranges — for pod-to-pod and pod-to-service traffic

A DROP target on the node's zone is the most common cause of silent pod
networking failures in bare-metal clusters — packets leave the pod, cross
the CNI bridge, reach the node network stack, and are silently dropped
by firewalld before any iptables/kube-proxy rule ever sees them.
