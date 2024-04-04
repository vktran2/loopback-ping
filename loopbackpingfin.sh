#!/bin/bash

# Function to filter and transform all node IDs containing 'network' to 'network'
filter_network_node_ids() {
    local xml_file="$1"
    local network_ids=($(xmlstarlet sel -t -v "//node[contains(@id, 'network')][@class='network']/@id" "$xml_file"))

    for id in "${network_ids[@]}"; do
        # Transform the node ID to "network"
        transformed_id="network"

        # Replace the original node ID with the transformed one in the XML file
        xmlstarlet ed -L -u "//node[contains(@id, '$id')][@class='network']/@id" -v "$transformed_id" "$xml_file"
    done
}

option_select=false

# Parse script options
while getopts "c" opt; do
    option_select=true
    case $opt in
        c)
            echo "testing output $opt and $OPTARG"
            read -p "Specify the SKU you would like to configure: (E.x NCA-5520A-AW1, NCA-4010D): " model
            echo "Creating xml file for: $model"
            /usr/sbin/lshw -xml > "/home/user/Windows/$model.xml"
            ;;

        \?)
            echo "Unsupported option. Please configure with option -c or run the script as is to test normally."
            exit 1
            ;;
    esac
done

if [ "$option_select" = false ]; then
    # Prompt user for the model used
    read -p "Enter the SKU used (E.x. NCA-5520A-AW1, NCA-4010D) " model
fi

echo "Model entered: $model"
xml_file="/home/user/Windows/$model.xml"
echo "Searching for: $xml_file"

if [ -e "$xml_file" ]; then
    echo "Proceeding with Loopback Test..."
else
    echo "The main configuration file has not been found. Please generate one first using options \"-c\" or \"-configure\""
    exit 1
fi

# Stop NetworkManager service
systemctl stop NetworkManager.service

# Filter and transform network node IDs in the XML file
filter_network_node_ids "$xml_file"

# Retrieve interface names from the XML file and store in an array
itf=($(xmlstarlet sel -t -v "//node[@id='network'][@class='network']/logicalname" "$xml_file"))

#variable to hold interfaces
itff=()

# Check if the number of interfaces is odd
if [ $(( ${#itf[@]} % 2 )) -eq 1 ]; then
    echo "${itf[*]}"
    read -p "Number of network interfaces is odd. Enter an interface name to remove: " interface_to_remove
    # Remove the specified interface from the array
    if [[ "${itf[*]}" =~ .*$interface_to_remove.* ]]; then
        for element in "${itf[@]}"; do
            [ "$element" != "$interface_to_remove" ] && itff+=("$element")
        done
    else
	echo "Enter a correct interface. Exiting."
	exit 1
    fi
else
    itff=("${itf[@]}")
fi

# Prompt for device serial number
echo "Enter device serial number"
read serial

# Check the length of the serial number
if [ ${#serial} -eq 14 ]; then
    fileP="/home/user/Windows/$serial"
    mkdir -p "$fileP" || { echo "Error creating folder $fileP"; exit 1; }
    echo "File folder created: $fileP"
else
    echo "Serial must be a string length of 14. Exiting."
    exit 1
fi

# Calculate the total number of namespaces to be created
let "nmsp=${#itff[@]}/2"

# Create array to hold namespaces
counter=1
while [ $counter -le $nmsp ]; do
    nsarray+=("netns$counter")
    counter=$((counter + 1))
done

# Create namespaces
for n in "${nsarray[@]}"; do
    ip netns add "$n"
    echo "Added $n namespace"
done

# Bring interfaces down
for i in "${itff[@]}"; do
    echo "$i is down"
    ip link set dev "$i" down
done

# IP Configurations
counter=0
counter2=1
for i in "${!itff[@]}"; do
    if [ $((i % 2)) -eq 0 ]; then
        echo ""
        echo "Added 192.168.$counter2.5/24 dev ${itff[$i]}"
        ip address add "192.168.$counter2.5/24" dev "${itff[$i]}"
        echo "IP:${itff[$i]} is up"
        ip link set dev "${itff[$i]}" up
        echo ""
    else
        echo ""
        echo "Set device ${itff[$i]} to ${nsarray[$counter]}"
        ip link set dev "${itff[$i]}" netns "${nsarray[$counter]}"
        echo "Added ${nsarray[$counter]} IP 192.168.$counter2.6/24 to ${itff[$i]}"
        ip netns exec "${nsarray[$counter]}" ip address add 192.168."$counter2".6/24 dev "${itff[$i]}"
        echo "Namespace:${nsarray[$counter]} IP:${itff[$i]} is up"
        ip netns exec "${nsarray[$counter]}" ip link set dev "${itff[$i]}" up
        echo "${nsarray[$counter]} dev lo up"
        ip netns exec "${nsarray[$counter]}" ip link set dev lo up
        echo ""
        counter=$((counter + 1))
        counter2=$((counter2 + 1))
    fi
done

sleep 2

# Ping Test
counter=0
counter2=1
for i in "${!itff[@]}"; do
    if [ $((i % 2)) -eq 0 ]; then
        echo "The ${itff[i]} ping test is now starting, please wait for 30 pings"
        ping -c 30 "192.168.$counter2.6" > "$fileP"/"${itff[i]}".log
    else
        echo "The ${itff[i]} ping test is now starting, please wait for 30 pings"
        ip netns exec "${nsarray[$counter]}" ping -c 30 "192.168.$counter2.5" > "$fileP"/"${itff[i]}".log
        counter=$((counter + 1))
        counter2=$((counter2 + 1))
    fi
done

#check if there was a solo interface
if [ -n "${interface_to_remove}" ]; then
    echo "testing solo interface"
    ping -c 30 -I $interface_to_remove "192.168.1.1" > "$fileP"/"$interface_to_remove".log
    sResult=$(tail -3 "$fileP"/"$interface_to_remove".log)
    echo -e "\033[0;36mResult of $fileP/$interface_to_remove.log is:"
    echo -e "\033[0m"
    echo "$sResult"
    echo ""
fi

# Output the results of ping test
for i in "${itff[@]}"; do
    result=$(tail -3 "$fileP"/"$i".log)
    echo -e "\033[0;36mResult of $fileP/$i.log is:"
    echo -e "\033[0m"
    echo "$result"
    echo ""
done

# Cleanup namespaces
for n in "${nsarray[@]}"; do
    ip netns del "$n"
    echo -e "\033[0;32mConfiguration reset"
    echo -e "\033[0m"
done

echo ""
echo -e "\033[0;32mLoopback test completed, logs available in $fileP"
echo -e "\033[0m"

# Start NetworkManager service
systemctl start NetworkManager.service

dmesg -E

sleep 2

# Prompt for CPU testing
read -r -p "Would you like to run CPU testing? [y/N] " response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    stress-ng --class cpu --all 1 -t 60s --times --perf --tz --verify > "$fileP"/cpu.log
    sleep 2
    stress-ng --class cpu-cache --all 1 -t 60s --times --perf --tz --verify > "$fileP"/cpu_cache.log
else
    exit
fi
