# DNAT Load Balancing

## Scenario

Three backends are running on port 8080. Traffic arrives on port 80.
The goal is to split that traffic evenly between the three backends without
using Nginx or HAProxy — just iptables.

## How it works

The `statistic` module adds a probability check to each rule. The key thing
is that each rule only sees traffic that wasn't already matched by the rules
above it, so the probabilities aren't equal thirds — they decrease:

| Rule | Sees | Probability | Gets |
|---|---|---|---|
| Backend 1 | 100% of traffic | 0.33 | ~33% |
| Backend 2 | 66% remaining | 0.50 | ~33% |
| Backend 3 | 33% remaining | 1.00 | ~33% |

## Usage

```bash
# edit the variables at the top first
vim setup-lb.sh

chmod +x setup-lb.sh

./setup-lb.sh setup     # apply rules
./setup-lb.sh verify    # watch packet counters live
./setup-lb.sh teardown  # remove rules
```

## Key commands

```bash
# verify rules are active
iptables -t nat -L PREROUTING -n -v --line-numbers

# watch distribution in real time
watch -n 1 "iptables -t nat -L PREROUTING -n -v --line-numbers"

# rollback manually (reverse order to avoid index shifting)
iptables -t nat -D PREROUTING 3
iptables -t nat -D PREROUTING 2
iptables -t nat -D PREROUTING 1
```

## Limitations

- No health checks — if a backend dies, traffic keeps going there
- No session persistence — each new connection is evaluated independently
- Only works with stateless backends

## K8s Connection

This is exactly what kube-proxy does in iptables mode. When you create a Service
with multiple endpoints, it generates the same probability chain under `KUBE-SVC-*`
chains — automatically, and with health check integration via endpoint watches.

```bash
# see it on a live node
iptables -t nat -L KUBE-SVC-XXXX -n -v
```
