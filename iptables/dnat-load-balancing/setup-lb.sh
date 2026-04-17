#!/bin/bash

DPORT=80
BACKEND1="10.0.0.10:8080"
BACKEND2="10.0.0.20:8080"
BACKEND3="10.0.0.30:8080"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {setup|teardown|verify}"
    exit 1
fi

setup() {
    echo "Setting up DNAT load balancing on port $DPORT..."

    # Rule 1: 33% of traffic goes to BACKEND1
    iptables -t nat -A PREROUTING -p tcp --dport "$DPORT" \
        -m statistic --mode random --probability 0.33 \
        -j DNAT --to-destination "$BACKEND1"

    # Rule 2: 50% of remaining traffic (which is ~66%) goes to BACKEND2
    # 0.50 x 0.66 = ~33% of total
    iptables -t nat -A PREROUTING -p tcp --dport "$DPORT" \
        -m statistic --mode random --probability 0.50 \
        -j DNAT --to-destination "$BACKEND2"

    # Rule 3: everything left goes to BACKEND3 (~33% of total)
    iptables -t nat -A PREROUTING -p tcp --dport "$DPORT" \
        -j DNAT --to-destination "$BACKEND3"

    echo "Done. Run '$0 verify' to check the rules."
}

teardown() {
    echo "Removing DNAT rules for port $DPORT..."

    # delete in reverse order to avoid index shifting
    iptables -t nat -D PREROUTING 3
    iptables -t nat -D PREROUTING 2
    iptables -t nat -D PREROUTING 1

    echo "Rules removed."
}

verify() {
    echo "Watching packet counters (Ctrl+C to stop)..."
    watch -n 1 "iptables -t nat -L PREROUTING -n -v --line-numbers | grep $DPORT"
}

case "$1" in
    setup)    setup ;;
    teardown) teardown ;;
    verify)   verify ;;
    *)
        echo "Usage: $0 {setup|teardown|verify}"
        exit 1
        ;;
esac
