# iptables Chains & Rules

## Scenario

A network namespace is running a 3-backend DNAT load balancer. Traffic is flowing
from the namespace to the internet but the FORWARD chain is silently dropping
packets under specific conditions. tcpdump shows packets leaving the source
but never arriving at the destination.

Your job: use tcpdump to pinpoint at which hop the packet is lost, identify
the iptables rule responsible, and restore connectivity without flushing the
entire ruleset.

## Diagnosis Flow

```bash
# 1. Capture on the outgoing interface — see if packets leave the host
tcpdump -i eth0 host 10.10.0.2

# 2. Capture inside the namespace — see if packets arrive at the source
ip netns exec app-ns tcpdump -i veth0

# 3. If packets leave but don't arrive — FORWARD chain is blocking
iptables -L FORWARD -n -v --line-numbers

# 4. Check NAT rules
iptables -t nat -L -n -v
```

## Root Cause

A DROP rule in the FORWARD chain was blocking traffic from the namespace.
Traffic could reach the host (INPUT chain, unaffected) but could not cross
the veth interface boundary (FORWARD chain).

The critical distinction: FORWARD processes traffic crossing between interfaces
(namespace ↔ internet). INPUT only processes traffic destined for the host itself.

```
Incoming packet → PREROUTING (nat) → routing decision
  ├─ for this host   → INPUT (filter) → local process
  └─ for forwarding  → FORWARD (filter) → POSTROUTING (nat) → out
```

## Fix

```bash
# Delete the blocking rule by position
iptables -D FORWARD 1

# Verify it was removed
iptables -L FORWARD -n --line-numbers
```

## The Trap: `-D` Syntax

`iptables -D` requires either the line number or the exact rule spec:

```bash
iptables -D FORWARD 1                        # by position — correct
iptables -D FORWARD -s 10.10.0.0/24 -j DROP # by spec — correct
iptables -D FORWARD DROP                     # invalid — not valid syntax
```

Always run `iptables -L --line-numbers` first to confirm the position.

## Tables & Chains

| Table | Purpose | Chains |
|---|---|---|
| `filter` | Allow/deny traffic (default table) | INPUT, FORWARD, OUTPUT |
| `nat` | Rewrite source/destination addresses | PREROUTING, POSTROUTING, OUTPUT |
| `mangle` | Modify packet headers (TTL, DSCP) | All chains |

## MASQUERADE vs SNAT

For MASQUERADE vs SNAT decision criteria and conntrack, see [nat/](../nat/).

## Key Commands

```bash
# Inspect all tables
iptables -L -n -v                   # filter table (default)
iptables -t nat -L -n -v            # nat table
iptables -t mangle -L -n -v         # mangle table

# Rule management
iptables -A FORWARD -s 10.10.0.0/24 -j ACCEPT      # append to end
iptables -I FORWARD 1 -s 10.10.0.0/24 -j ACCEPT    # insert at position 1
iptables -D FORWARD 1                               # delete by position
iptables -L FORWARD -n --line-numbers               # list with line numbers

# Save and restore
iptables-save > /etc/iptables/rules.v4
iptables-restore < /etc/iptables/rules.v4

# Check ip_forward (required for FORWARD to work)
sysctl net.ipv4.ip_forward
sysctl -w net.ipv4.ip_forward=1

# Custom chain for logging
iptables -N LOG-AND-DROP
iptables -A LOG-AND-DROP -j LOG --log-prefix "DROPPED: " --log-level 4
iptables -A LOG-AND-DROP -j DROP
iptables -A FORWARD -s 10.10.0.0/24 -j LOG-AND-DROP
```

Logs appear in `journalctl -k` (kernel log).

## DNAT Load Balancing

See [dnat-load-balancing/](./dnat-load-balancing/) for the probabilistic 3-backend setup.

## K8s Connection

kube-proxy (iptables mode) creates rules in `filter` and `nat` using the exact
same primitives. Each Kubernetes Service becomes:

- A custom chain in `nat`: `KUBE-SVC-<hash>` — the load balancer
- Per-endpoint chains: `KUBE-SEP-<hash>` — the DNAT targets
- PREROUTING and OUTPUT rules jumping to `KUBE-SERVICES`

When a pod can't reach a Service, the debug path is identical:
`iptables -t nat -L -n -v | grep <service-ip>` to trace whether the DNAT
rules exist and are matching. The FORWARD chain issue from this lab is the same
gap that causes cross-node pod failures when ip_forward is disabled.
