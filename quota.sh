#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to convert memory units to Mi
convert_to_mi() {
    local value=$1
    if [[ $value =~ ([0-9.]+)Gi ]]; then
        echo "scale=2; ${BASH_REMATCH[1]} * 1024" | bc
    elif [[ $value =~ ([0-9.]+)Mi ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ $value =~ ([0-9.]+)Ki ]]; then
        echo "scale=2; ${BASH_REMATCH[1]} / 1024" | bc
    elif [[ $value =~ ([0-9.]+)Ti ]]; then
        echo "scale=2; ${BASH_REMATCH[1]} * 1024 * 1024" | bc
    else
        echo "0"
    fi
}

# Function to convert Mi to Gi
mi_to_gi() {
    echo "scale=2; $1 / 1024" | bc
}

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}          Kubernetes Memory Usage Report (in Gi)${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

# Get nodes info
echo -e "${GREEN}=== NODES MEMORY USAGE ===${NC}"
printf "%-35s %15s %15s %24s %10s\n" "NODE" "CAPACITY" "USED" "AVAILABLE" "USAGE%"
echo "-----------------------------------------------------------------------------------------------------------------"

declare -A node_capacity
declare -A node_used
declare -A node_pods_usage

# Parse nodes
while IFS= read -r line; do
    node=$(echo "$line" | awk '{print $1}')
    cpu=$(echo "$line" | awk '{print $2}')
    cpu_pct=$(echo "$line" | awk '{print $3}')
    mem=$(echo "$line" | awk '{print $4}')
    mem_pct=$(echo "$line" | awk '{print $5}')

    # Convert memory to Mi then to Gi
    mem_mi=$(convert_to_mi "$mem")
    mem_gi=$(mi_to_gi "$mem_mi")

    # Extract percentage
    mem_pct_num=$(echo "$mem_pct" | sed 's/%//')

    # Calculate capacity (used / percentage * 100)
    capacity_mi=$(echo "scale=2; $mem_mi * 100 / $mem_pct_num" | bc)
    capacity_gi=$(mi_to_gi "$capacity_mi")

    # Calculate available
    available_mi=$(echo "scale=2; $capacity_mi - $mem_mi" | bc)
    available_gi=$(mi_to_gi "$available_mi")

    # Store for later use
    node_capacity[$node]=$capacity_gi
    node_used[$node]=$mem_gi

    # Color coding based on usage
    if (( $(echo "$mem_pct_num > 80" | bc -l) )); then
        color=$RED
    elif (( $(echo "$mem_pct_num > 60" | bc -l) )); then
        color=$YELLOW
    else
        color=$GREEN
    fi

    printf "${color}%-30s %16.2f Gi %16.2f Gi %16.2f Gi %9s${NC}\n" \
        "$node" "$capacity_gi" "$mem_gi" "$available_gi" "$mem_pct"

done < <(kubectl top nodes --no-headers)

echo ""
echo -e "${GREEN}=== PODS MEMORY USAGE BY NODE ===${NC}"

# Get all pods with their nodes
while IFS= read -r line; do
    namespace=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    cpu=$(echo "$line" | awk '{print $3}')
    mem=$(echo "$line" | awk '{print $4}')

    # Get node for this pod
    node=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.spec.nodeName}' 2>/dev/null)

    if [ -n "$node" ]; then
        # Convert memory to Mi
        mem_mi=$(convert_to_mi "$mem")

        # Add to node total
        if [ -z "${node_pods_usage[$node]}" ]; then
            node_pods_usage[$node]=$mem_mi
        else
            node_pods_usage[$node]=$(echo "${node_pods_usage[$node]} + $mem_mi" | bc)
        fi
    fi
done < <(kubectl top pods -A --no-headers)

# Display pods usage by node
printf "\n%-34s %18s %18s %20s\n" "NODE" "PODS USAGE" "NODE USED" "DIFFERENCE"
echo "-----------------------------------------------------------------------------------------------------------------"

total_pods_gi=0
total_node_gi=0

for node in "${!node_capacity[@]}"; do
    pods_mi=${node_pods_usage[$node]:-0}
    pods_gi=$(mi_to_gi "$pods_mi")
    node_gi=${node_used[$node]}
    diff_gi=$(echo "scale=2; $node_gi - $pods_gi" | bc)

    total_pods_gi=$(echo "scale=2; $total_pods_gi + $pods_gi" | bc)
    total_node_gi=$(echo "scale=2; $total_node_gi + $node_gi" | bc)

    printf "%-30s %16.2f Gi %16.2f Gi %16.2f Gi\n" \
        "$node" "$pods_gi" "$node_gi" "$diff_gi"
done

echo ""
echo -e "${YELLOW}=== SUMMARY ===${NC}"
total_capacity=0
for cap in "${node_capacity[@]}"; do
    total_capacity=$(echo "scale=2; $total_capacity + $cap" | bc)
done

echo "Total Cluster Capacity:     $(printf "%8.2f" $total_capacity) Gi"
echo "Total Node Memory Used:     $(printf "%8.2f" $total_node_gi) Gi"
echo "Total Pods Memory Used:     $(printf "%8.2f" $total_pods_gi) Gi"
echo "System Overhead (approx):   $(printf "%8.2f" $(echo "scale=2; $total_node_gi - $total_pods_gi" | bc)) Gi"
echo "Total Available:            $(printf "%8.2f" $(echo "scale=2; $total_capacity - $total_node_gi" | bc)) Gi"

usage_pct=$(echo "scale=2; $total_node_gi * 100 / $total_capacity" | bc)
echo "Cluster Usage:              $(printf "%8.2f" $usage_pct)%"

echo ""
echo -e "${BLUE}=====================================================================${NC}"
