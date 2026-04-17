# DNS Resolution

## Scenario

An application on a server can't reach `app.internal`. The hostname is
registered in DNS and resolves correctly from your workstation.
The service itself is running. Nothing obvious is broken.

Your job: determine whether the issue is DNS resolution, routing, or
application configuration — using the correct diagnostic flow.

## The Correct Diagnostic Flow

The trap in DNS troubleshooting is reaching for `dig` first and concluding
"DNS works" when it resolves — but the application still fails. `dig` and
system DNS resolution are **not the same path**.

```
Correct flow:
1. Test application connectivity first (curl, nc, telnet)
2. If connection fails → test system DNS (getent hosts <name>)
3. If system DNS fails → test nameserver directly (dig)
4. If dig works but getent fails → check nsswitch.conf
5. If dig fails → check /etc/resolv.conf, nameserver, network
```

The inverted flow (dig first) gives false confidence when the real issue
is `nsswitch.conf` ordering or a misconfigured search domain.

## dig vs System Resolution — Critical Difference

```bash
dig app.internal           # goes directly to the nameserver
                           # bypasses /etc/hosts, nsswitch.conf

getent hosts app.internal  # uses nsswitch.conf resolution order
                           # respects /etc/hosts, then DNS (or not)

nslookup app.internal      # similar to dig — direct nameserver query
```

If `dig` resolves but `getent` (or the application) doesn't:

```bash
cat /etc/nsswitch.conf | grep hosts
# hosts: files dns
#         ↑ checks /etc/hosts first, then DNS
# hosts: files
#         ↑ never queries DNS — only /etc/hosts
```

Applications using `getaddrinfo()` (the standard libc call) follow
`nsswitch.conf`. If `nsswitch.conf` only has `files`, the nameserver
configured in `/etc/resolv.conf` is never consulted — regardless of
whether `dig` works.

## /etc/resolv.conf — The Three Directives

```
nameserver 8.8.8.8          # primary DNS server (up to 3 allowed)
nameserver 8.8.4.4          # secondary
search corp.internal dev.internal  # append these domains to unqualified names
options ndots:5             # names with < 5 dots are tried with search domains first
```

`search` is particularly important in K8s: pods use it to resolve short names
like `my-service` as `my-service.default.svc.cluster.local` without typing
the full FQDN.

## Debugging DNS Resolution

```bash
# Test system resolution (what the application sees)
getent hosts app.internal

# Test nameserver directly (bypasses nsswitch)
dig app.internal
dig @8.8.8.8 app.internal        # query a specific nameserver
dig app.internal +trace           # follow the full delegation chain

# Check current DNS config
cat /etc/resolv.conf
resolvectl status                 # systemd-resolved status (if active)

# Flush DNS cache (systemd-resolved)
resolvectl flush-caches

# Check if a name resolves with search domain applied
dig app.internal.corp.internal    # explicit FQDN (trailing dot = no search)
dig app.internal.                 # trailing dot = absolute name, no search applied
```

## Common Failure Modes

| Symptom | Likely cause |
|---|---|
| `dig` works, app fails | `nsswitch.conf` missing `dns`, or `ndots` mismatch |
| Both fail, nameserver reachable | Wrong nameserver in `resolv.conf`, or record doesn't exist |
| Both fail, nameserver unreachable | Firewall blocking port 53 (UDP/TCP) |
| Intermittent failures | DNS server under load, or `search` domain causing extra lookups |
| Works inside namespace, fails in pod | `resolv.conf` not injected correctly (K8s specific) |

## The Trap: Inverted Flow

Running `dig` first and getting a response does not mean DNS is fine for
the application. The debugging session on 25 Feb revealed this exact pattern:
`dig app.internal` resolved correctly, but the application couldn't reach
the service because `nsswitch.conf` only had `files`.

**Always test with `getent` or `curl` first — not `dig`.**

## Key Commands

```bash
# System resolution (application-accurate)
getent hosts app.internal
getent ahosts app.internal      # includes IPv6

# Direct nameserver query
dig app.internal
dig app.internal +short         # IP only
dig app.internal MX             # specific record type
dig app.internal +trace         # full delegation chain

# Check configuration
cat /etc/resolv.conf
cat /etc/nsswitch.conf
resolvectl status

# Test port 53 reachability
nc -zvu <nameserver-ip> 53      # UDP
nc -zvt <nameserver-ip> 53      # TCP (for large responses)
```

## K8s Connection

CoreDNS is the DNS server for Kubernetes clusters. Every pod gets a
`/etc/resolv.conf` injected by kubelet with:

```
nameserver 10.96.0.10           # CoreDNS ClusterIP
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

The `ndots:5` setting means any name with fewer than 5 dots is first tried
with each search domain appended before the absolute lookup — causing extra
DNS queries. This is why `curl http://my-service` makes 4+ DNS queries
before succeeding, and why DNS-heavy apps in K8s can overload CoreDNS.

Pod DNS policy (`dnsPolicy: ClusterFirst` vs `None` vs `Default`) controls
which `resolv.conf` the pod receives — directly applying the nsswitch.conf
logic practiced here. Debugging pod DNS failures follows the exact same flow:
`kubectl exec` into the pod → `cat /etc/resolv.conf` → `getent hosts <service>`.
