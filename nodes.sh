#!/bin/bash

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}          Memory Allocation Breakdown${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

# Function to convert Ki to Gi
ki_to_gi() {
    echo "scale=2; $1 / 1024 / 1024" | bc
}

# Get node information
kubectl get nodes -o json | jq -r '.items[] |
{
  name: .metadata.name,
  capacity: .status.capacity.memory,
  allocatable: .status.allocatable.memory
}' | jq -s '.[]' | while read -r node_data; do

    node_name=$(echo "$node_data" | jq -r '.name')
    capacity_ki=$(echo "$node_data" | jq -r '.capacity' | sed 's/Ki//')
    allocatable_ki=$(echo "$node_data" | jq -r '.allocatable' | sed 's/Ki//')

    # Convert to Gi
    capacity_gi=$(ki_to_gi $capacity_ki)
    allocatable_gi=$(ki_to_gi $allocatable_ki)
    reserved_ki=$((capacity_ki - allocatable_ki))
    reserved_gi=$(ki_to_gi $reserved_ki)

    # Get actual pod usage
    pod_usage_mi=$(kubectl top pods -A --no-headers 2>/dev/null | \
        while read ns pod cpu mem; do
            node=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
            if [ "$node" = "$node_name" ]; then
                echo "$mem" | sed 's/Mi//'
            fi
        done | awk '{sum += $1} END {print sum}')

    pod_usage_gi=$(echo "scale=2; ${pod_usage_mi:-0} / 1024" | bc)

    # Get node total usage
    node_used_pct=$(kubectl top node "$node_name" --no-headers 2>/dev/null | awk '{print $5}' | sed 's/%//')
    node_used_gi=$(echo "scale=2; $allocatable_gi * $node_used_pct / 100" | bc)

    # Calculate system overhead
    system_overhead_gi=$(echo "scale=2; $node_used_gi - $pod_usage_gi" | bc)

    # Calculate free on node
    free_gi=$(echo "scale=2; $allocatable_gi - $node_used_gi" | bc)

    # VM RAM (assumed 8 Gi)
    vm_ram_gi=8.00
    vm_to_capacity_gi=$(echo "scale=2; $vm_ram_gi - $capacity_gi" | bc)

    echo -e "${GREEN}Node: $node_name${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  ${YELLOW}VM Total RAM:${NC}                   %8.2f Gi  (100.00%%)\n" $vm_ram_gi
    printf "  ${YELLOW}├─ Lost to BIOS/Firmware:${NC}       %8.2f Gi  (%6.2f%%)\n" \
        $vm_to_capacity_gi \
        $(echo "scale=2; $vm_to_capacity_gi * 100 / $vm_ram_gi" | bc)
    printf "  ${YELLOW}└─ K8s Capacity:${NC}                %8.2f Gi  (%6.2f%%)\n" \
        $capacity_gi \
        $(echo "scale=2; $capacity_gi * 100 / $vm_ram_gi" | bc)
    printf "     ${YELLOW}├─ Reserved by K8s:${NC}          %8.2f Gi  (%6.2f%%)\n" \
        $reserved_gi \
        $(echo "scale=2; $reserved_gi * 100 / $vm_ram_gi" | bc)
    printf "     ${YELLOW}└─ K8s Allocatable:${NC}          %8.2f Gi  (%6.2f%%)\n" \
        $allocatable_gi \
        $(echo "scale=2; $allocatable_gi * 100 / $vm_ram_gi" | bc)
    printf "        ${YELLOW}├─ Used by Pods:${NC}          %8.2f Gi  (%6.2f%%)\n" \
        $pod_usage_gi \
        $(echo "scale=2; $pod_usage_gi * 100 / $vm_ram_gi" | bc)
    printf "        ${YELLOW}├─ System Overhead:${NC}       %8.2f Gi  (%6.2f%%)\n" \
        $system_overhead_gi \
        $(echo "scale=2; $system_overhead_gi * 100 / $vm_ram_gi" | bc)
    printf "        ${YELLOW}└─ Free:${NC}                  %8.2f Gi  (%6.2f%%)\n" \
        $free_gi \
        $(echo "scale=2; $free_gi * 100 / $vm_ram_gi" | bc)
    echo ""

    # Visual bar
    used_pct=$(echo "scale=0; $node_used_gi * 100 / $vm_ram_gi" | bc)
    reserved_pct=$(echo "scale=0; $reserved_gi * 100 / $vm_ram_gi" | bc)
    free_pct=$(echo "scale=0; 100 - $used_pct - $reserved_pct" | bc)

    used_bars=$((used_pct / 2))
    reserved_bars=$((reserved_pct / 2))
    free_bars=$((free_pct / 2))

    echo -n "  ["
    for i in $(seq 1 $used_bars); do echo -n "█"; done
    for i in $(seq 1 $reserved_bars); do echo -n "▓"; done
    for i in $(seq 1 $free_bars); do echo -n "░"; done
    echo "] 100%"
    echo "  █ Used  ▓ Reserved  ░ Free"
    echo ""
done

echo -e "${BLUE}=====================================================================${NC}"
echo ""
echo -e "${YELLOW}Explanation:${NC}"
echo "• Lost to BIOS/Firmware: Memory used by hardware/firmware (unavailable to OS)"
echo "• Reserved by K8s: --system-reserved, --kube-reserved, --eviction-threshold"
echo "• System Overhead: OS processes, caches, kubelet, container runtime"
echo "• Free: Available for new pod scheduling"
