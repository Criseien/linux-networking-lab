# Network Namespaces

## Scenario

Two network namespaces (`app-ns` and `db-ns`) need to communicate with each
other and reach the internet through the host. The topology is built manually
from scratch — veth pairs, a bridge, routes, and NAT.

Once built, a DROP rule is silently blocking egress to the internet.

Your job: build the topology, then diagnose and fix the failure without
rebuilding anything.

---

## How to Build a Namespace Topology

This is what a CNI plugin does automatically when a pod starts. Doing it
manually once means you know exactly what to look for when it breaks.

### Step 1 — Create the namespaces

```bash
ip netns add app-ns
ip netns add db-ns

ip netns list
# app-ns
# db-ns
```

### Step 2 — Create a bridge on the host

The bridge acts as a virtual switch — all namespace veth pairs connect to it.

```bash
ip link add br0 type bridge
ip link set br0 up
ip addr add 10.10.0.1/24 dev br0    # host-side IP — gateway for namespaces
```

### Step 3 — Create veth pairs and connect to namespaces

Each veth pair has two ends: one goes into the namespace, one connects to the bridge.

```bash
# veth pair for app-ns
ip link add veth-app type veth peer name veth-app-br
ip link set veth-app netns app-ns        # move one end into the namespace
ip link set veth-app-br master br0       # connect other end to the bridge
ip link set veth-app-br up

# veth pair for db-ns
ip link add veth-db type veth peer name veth-db-br
ip link set veth-db netns db-ns
ip link set veth-db-br master br0
ip link set veth-db-br up
```

### Step 4 — Assign IPs and bring interfaces up inside the namespaces

```bash
# app-ns
ip netns exec app-ns ip addr add 10.10.0.2/24 dev veth-app
ip netns exec app-ns ip link set veth-app up
ip netns exec app-ns ip link set lo up
ip netns exec app-ns ip route add default via 10.10.0.1   # default route via bridge

# db-ns
ip netns exec db-ns ip addr add 10.10.0.3/24 dev veth-db
ip netns exec db-ns ip link set veth-db up
ip netns exec db-ns ip link set lo up
ip netns exec db-ns ip route add default via 10.10.0.1
```

### Step 5 — Enable forwarding and MASQUERADE on the host

```bash
# Allow the kernel to forward packets between interfaces
sysctl -w net.ipv4.ip_forward=1

# SNAT outbound traffic from the namespace subnet so it looks like the host
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE

# Allow forwarding for namespace traffic
iptables -A FORWARD -s 10.10.0.0/24 -j ACCEPT
iptables -A FORWARD -d 10.10.0.0/24 -j ACCEPT
```

### Verify the topology

```bash
# Namespace to host
ip netns exec app-ns ping -c 2 10.10.0.1

# Namespace to namespace
ip netns exec app-ns ping -c 2 10.10.0.3

# Namespace to internet
ip netns exec app-ns ping -c 2 8.8.8.8
```

---

## The 90% — Namespace Failure Modes

### 1. Interface is down — link not brought up

**Symptom:**

```bash
ip netns exec app-ns ping 10.10.0.1
# connect: Network is unreachable
```

**Diagnose:**

```bash
ip netns exec app-ns ip -br a
# veth-app    DOWN    10.10.0.2/24   ← DOWN is the problem
```

**Fix:**

```bash
ip netns exec app-ns ip link set veth-app up
ip netns exec app-ns ip link set lo up    # lo also needs to be up
```

---

### 2. No default route inside the namespace

**Symptom:** namespace can ping the host but nothing beyond it.

```bash
ip netns exec app-ns ping 10.10.0.1    # works
ip netns exec app-ns ping 8.8.8.8      # fails — no route to host
```

**Diagnose:**

```bash
ip netns exec app-ns ip route
# 10.10.0.0/24 dev veth-app    ← only local subnet, no default route
```

**Fix:**

```bash
ip netns exec app-ns ip route add default via 10.10.0.1
```

---

### 3. ip_forward disabled on the host

**Symptom:** namespace can reach the host but not other namespaces or the internet.
Packets disappear at the host boundary.

```bash
ip netns exec app-ns ping 10.10.0.1    # works — reaches host
ip netns exec app-ns ping 10.10.0.3    # fails — can't cross to db-ns
ip netns exec app-ns ping 8.8.8.8      # fails — can't reach internet
```

**Diagnose:**

```bash
sysctl net.ipv4.ip_forward
# net.ipv4.ip_forward = 0    ← kernel is not forwarding packets
```

**Fix:**

```bash
sysctl -w net.ipv4.ip_forward=1

# Persist across reboots
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
```

---

### 4. MASQUERADE missing — return traffic can't get back

**Symptom:** packets leave the namespace and reach the internet, but no response
comes back. `tcpdump` on `eth0` shows outbound packets with source IP `10.10.0.2`
— a private IP the internet can't route back to.

```bash
ip netns exec app-ns ping 8.8.8.8
# (no response — request goes out but reply doesn't return)

tcpdump -i eth0 icmp
# 10.10.0.2 > 8.8.8.8   ← source is the private namespace IP, not the host IP
```

**Diagnose:**

```bash
iptables -t nat -L POSTROUTING -n -v
# (no MASQUERADE rule for 10.10.0.0/24)
```

**Fix:**

```bash
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE
```

---

### 5. FORWARD chain blocking traffic

**Symptom:** topology looks correct — ip_forward is on, MASQUERADE is there —
but traffic is still silently dropped.

```bash
ip netns exec app-ns ping 8.8.8.8
# (no response)
```

**Diagnose:**

```bash
iptables -L FORWARD -n -v --line-numbers
# 1    DROP    all  --  10.10.0.0/24    0.0.0.0/0    ← blocking all egress
```

**Fix:**

```bash
# Delete the blocking rule by position
iptables -D FORWARD 1

# Or add an explicit ACCEPT before it
iptables -I FORWARD 1 -s 10.10.0.0/24 -j ACCEPT
```

The trap: `iptables -D FORWARD DROP` is not valid syntax. It requires either
a line number (`-D FORWARD 1`) or the full rule spec. Always check
`--line-numbers` first.

---

### 6. firewalld vs raw iptables — two separate layers

`firewall-cmd --zone=public --query-masquerade` returning `no` does not mean
there is no MASQUERADE rule in the system. firewalld and raw iptables are
independent layers.

```bash
firewall-cmd --zone=public --query-masquerade   # → no
iptables -t nat -L POSTROUTING -n -v            # → MASQUERADE rule still there
```

Always check both layers when diagnosing NAT issues.

---

## Key Commands

```bash
# Namespace lifecycle
ip netns add <name>
ip netns list
ip netns del <name>
ip netns exec <name> <command>

# Build topology
ip link add <veth> type veth peer name <veth-br>
ip link set <veth> netns <ns>
ip link set <veth-br> master br0
ip link set <veth-br> up

# Inside namespace
ip netns exec <ns> ip addr add <ip/prefix> dev <veth>
ip netns exec <ns> ip link set <veth> up
ip netns exec <ns> ip link set lo up
ip netns exec <ns> ip route add default via <gateway>

# Host forwarding
sysctl net.ipv4.ip_forward
sysctl -w net.ipv4.ip_forward=1

# NAT
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE
iptables -L FORWARD -n -v --line-numbers
iptables -D FORWARD <line-number>

# Teardown
ip netns del app-ns
ip netns del db-ns
ip link del br0          # also removes veth-*-br pairs attached to it
```

## K8s Connection

Every Kubernetes pod runs in its own network namespace. When a pod starts,
the CNI plugin runs exactly the steps above automatically: creates a veth pair,
moves one end into the pod's namespace, connects the other to a bridge or
overlay, assigns an IP, and sets up routes.

When a pod can't reach another pod or the internet, the debug flow is identical
to the failure modes above: check the FORWARD chain on the node, check
ip_forward, check CNI MASQUERADE rules, verify the veth pair is up. The
commands are the same — the scale is just larger.

```bash
# On a K8s node — inspect a pod's namespace directly
crictl inspect <container-id> | grep pid
nsenter --net=/proc/<pid>/ns/net ip -br a
nsenter --net=/proc/<pid>/ns/net ip route
```
