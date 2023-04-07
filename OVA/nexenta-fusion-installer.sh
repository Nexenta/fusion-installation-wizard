#!/bin/bash

echo "$(dirname "$0")"
fusionImage="nexenta/fusion:2.0.4"
defaultFusionVol="fusion2_fusdata"
containerName="fusion2"
esNodesCount=3
# text formatting variables
textBold=$(tput bold)
textNormal=$(tput sgr0)
textRed='\033[0;31m'
textBlue='\033[0;36m'
textYellow='\033[38;5;226m'
textLightGray='\033[1;37m'
textNc='\033[0m' # N

# it is recommended to set heap size less or equal to 31gib
# 31g = 1000 * 1000 * 1000 * 31 bytes
defaultHeapSizeLimitBytes=$(( 1024 * 1024 * 1024 * 31 ))
defaultHeapSizeLimitG=31

ask() {
    echo
    # echo question
    echo -e "${textBlue}$1${textNc}"
    # echo description
    echo "----------------"
    echo -e "${textLightGray}$2${textNc}"
    echo "----------------"
}

getIfs() {
    ifs=$(ip -details -json address show | jq --join-output '
    .[] | 
      if .linkinfo.info_kind // .link_type == "loopback" then
          empty
      else
          .ifname, " "
      end
    ')
    ifs=($ifs)
}

getIps() {
    ips=$(for i in ${ifs[@]}; do ip a show $i| grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*'; done)
    ips=($ips)
}

calculateRAM() {
    # NOTE: ESDB heap size is calculated in units defined as powers of 2
    isLowMemory=false
    if [ -x "/usr/sbin/system_profiler" ]; then
        # mac os way to find total RAM
        totalMemory=$(system_profiler SPHardwareDataType | grep "  Memory:" | grep -Eo '[0-9]+')
        # for mac users we expect that they all have RAM more than 1g and which can be divided by 2
        # in other cases we set 1g as default
        defaultHeapSizeTotal=$(( totalMemory / 2 ))
        defaultHeapSize=$(( defaultHeapSizeTotal / esNodesCount ))

        if [ $defaultHeapSizeTotal -gt $defaultHeapSizeLimitG ]; then
            defaultHeapSizeTotal=$defaultHeapSizeLimitG
            defaultHeapSize=$(( defaultHeapSizeTotal / esNodesCount ))
        fi

        defaultHeapSizeTotal="${defaultHeapSizeTotal}g"
        defaultHeapSize="${defaultHeapSize}g"

        if ! [[ $defaultHeapSizeTotal =~ ^[0-9]+g$ ]]; then
            defaultHeapSizeTotal="3g"
            defaultHeapSize="1g"
        fi
        totalMemory=${totalMemory}g
    elif [ -f "/proc/meminfo" ]; then
        # linux way to find total RAM
        # total memory is presented in kb
        totalMemory=$(cat /proc/meminfo | grep -Po "(?<=MemTotal:)(\s+)(\w+)" | grep -Eo "\w+")
        # converting totalMemory to bytes
        totalMemory=$(( totalMemory * 1000 ))
        onegib=$(( 1024*1024*1024 ))
        # if total memory is lower than 1gib
        # we won't allow to run a container via this script
        if [[ $totalMemory -lt $onegib ]]; then
            isLowMemory=true
        fi
        defaultHeapSizeTotal=$(( totalMemory / 2 ))
        defaultHeapSize=$(( defaultHeapSizeTotal / esNodesCount ))
        if [ $defaultHeapSizeTotal -gt $defaultHeapSizeLimitBytes ]; then
            # if half of memory is more than 31gib we set 31gib as default heap size
            defaultHeapSizeTotal="31744m"
            defaultHeapSize="10581m"
        # if there is more than 1gib but less than 2gib of total RAM
        # set default heap size 1gib
        # 1024^3bytes = 1gib
        elif [[ $defaultHeapSizeTotal -lt $onegib ]]; then
            defaultHeapSizeTotal="1g"
            defaultHeapSize="341m"
        else 
            # converting to mibibytes since result of division may be not an integer number
            # of gibibytes
            # 1mib = 1024^2
            defaultHeapSizeTotal=$( numfmt --to-unit=1048576 --suffix=m ${defaultHeapSizeTotal})
            defaultHeapSize=$( numfmt --to-unit=1048576 --suffix=m ${defaultHeapSize})
        fi

        # converting to human readable value
        totalMemory=$( numfmt --round=nearest --to=iec ${totalMemory})
    fi
}

displayIfs() {
    local index=1
    for i in ${ifs[@]}; do echo "${index})  ${i}"; ((index=index+1)); done
    echo "Type a number and press enter"
}

displayNetworkOptions() {
    local index=1
    for opt in ${opts[@]}; do echo "${index})  ${opt}"; ((index=index+1)); done
    echo "Type a number and press enter"
}

displayIpOptions() {
    local name=$1[@]
    local options=("${!name}");
    
    for ((i=0; i < ${#options[@]}; i++)) {
        if [[ "$previouslyUsedManagementIp" ==  ${options[$i]} ]]; then
            local comment="(previously used by Fusion container)"
        else 
            local comment=""
        fi
        echo "$(($i + 1))) ${options[$i]} ${comment}"
    }
    echo "Type a number and press enter"
}

readSelectedOption() {
    local name=$1[@]
    local options=("${!name}");

    local correct=0
    while [ $correct -eq 0 ]; do 
        read input
        if [[ "$input" =~ ^[1-${#options[@]}]$ ]]; then
            correct=1;
        else
            echoRed "Invalid option. Please enter valid option"    
        fi
    done

    return $input
}

verify_ip(){
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS="." read -r -a ip_array <<< $ip
        for i in "${ip_array[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

verify_ip_list(){
    local ip_list=$1
    IFS="," read -r -a ip_arr <<< $ip_list
    for i in "${ip_arr[@]}"; do
        if ! verify_ip $i; then
            return 1
        fi
    done
    return 0
}

verify_ip_cidr(){
    local cidr=$1
    IFS="/" read -r -a cidr <<< $cidr
    if [ ${#cidr[@]} -gt 2 ]; then
        return 1
    fi
    if ! verify_ip ${cidr[0]}; then
        return 1
    fi
    if ! [[ ${cidr[1]} =~ ^[0-9]{1,2}$ ]]; then
        return 1
    fi
    if [[ ${cidr[1]} -gt 32 ]]; then
        return 1
    fi
    return 0
}

configureNetwork() {
    if [[ $useDhcp ]]; then
        echo
        cat > /etc/netplan/01-fusion-installer.yaml <<EOF
network:
  version: 2
  ethernets:
    $nic:
      dhcp4: true
EOF
    else
        local correct=0
        while [ $correct -eq 0 ]; do
            read -p "Enter the static IP in CIDR format (eg:- 1.1.1.1/24): " staticip
            if verify_ip_cidr $staticip; then
                correct=1;
            else
                echoRed "Invalid IP address format. Please enter valid IP in CIDR format (eg:- 1.1.1.1/24)"
            fi
        done

        local correct=0
        while [ $correct -eq 0 ]; do
            read -p "Enter the IP of your gateway: " gatewayip
            if verify_ip $gatewayip; then
                correct=1;
            else
                echoRed "Invalid gateway IP format. Please enter valid gateway"
            fi
        done

        local correct=0
        while [ $correct -eq 0 ]; do
            read -p "Enter the IP of preferred nameservers (seperated by a comma if more than one): " nameservers
            if verify_ip_list $nameservers; then
                correct=1;
            else
                echoRed "Invalid nameserver format. Please enter valid nameserver"
            fi
        done

        echo
        cat > /etc/netplan/01-fusion-installer.yaml <<EOF
network:
  version: 2
  ethernets:
    $nic:
      addresses:
      - $staticip
      gateway4: $gatewayip
      nameservers:
          addresses: [$nameservers]
EOF
    fi
    set -eo pipefail
    sudo netplan apply
    set +e
}

waitForIp() {
    counter=0
    addr=$(ip a show $nic | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
    echoBlue "Waiting for ip address to become avaiable"
    while [ ${#addr} = 0 ]; do
        echo -n .
        if [ $counter -gt 120 ]; then
            echoError "IP address not available after 120s"
            exit
        fi
        sleep 1
        ((counter=counter+1))
        addr=$(ip a show $nic | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
    done
    managementIp=$addr
}

getFusionUiStatus() {
    if curl --output /dev/null --silent --head --insecure --fail http://$1:8457; then
        echo up
    else 
        echo down
    fi
}

isMacOS() {
    if [[ "$OSTYPE" = "darwin"* ]]; then
        return 0
    else 
        return 1
    fi
}

isCentOS() {
    if [ -f /etc/redhat-release ]; then
        return 0
    else
        return 1
    fi
}

# text functions 
echoBlue() {
    echo -e "${textBlue}${1}${textNc}"
}

echoRed() {
    echo -e "${textRed}${1}${textNc}"
}

echoYellow() {
    echo -e "${textYellow}${1}${textNc}"
}

echoError() {
    echo -e "${textRed}Error: ${1}${textNc}" >&2
}

echoDefaults() {
    ask "Defaults have been selected for the following parameters:" \
        "ESDB heap size is the memory reserved for the analytics database cluster nodes. The default recommendation is half of the total system memory, but not more than 31g (your machine has ${totalMemory} of RAM)."
    echo "ESDB cluster total heap size:${textBold} ${defaultHeapSizeTotal} ${textNormal}"
    echo "ESDB heap size for each of${textBold} ${esNodesCount} ${textNormal}nodes:${textBold} ${defaultHeapSize} ${textNormal}"
    echo "Fusion volume name:${textBold} $defaultFusionVol ${textNormal}"
}

prepareContainerParams() {
    if [ -z "$typedFusionVol" ]; then
        fusionVol=$defaultFusionVol
    else 
        fusionVol=$typedFusionVol
    fi

    if [ -z "$typedHeapSize" ]; then
        heapSizeTotal=$defaultHeapSizeTotal
        heapSize=$defaultHeapSize
    else
        heapSizeTotal=$typedHeapSizeTotal
        heapSize=$typedHeapSize
    fi
}

runContainer() {
    # show summary if defaults were not accepted
    if [ "$1" = "n" ]; then
        echoBlue "The Fusion container will be run with the following parameters:"
        echo "Management address:${textBold} $managementIp${textNormal}"
        echo "ESDB cluster total heap size:${textBold} ${heapSizeTotal} ${textNormal}"
        echo "ESDB heap size for each of${textBold} ${esNodesCount} ${textNormal}nodes:${textBold} ${heapSize} ${textNormal}"
        echo "Fusion volume name:${textBold} $fusionVol ${textNormal}"
        echo
        echo "Press any key to continue"
        read
    fi
    echoBlue "Installing ElasticSearch cluster..."
    export ES_HEAP_SIZE=$heapSize
    docker-compose -f $(dirname "$0")/docker-compose.yml up -d

    echoBlue "Running the Fusion container..."
    dockerRunCommand="docker run -d -i
                        --name $containerName
                        -v $fusionVol:/var/lib/nef
                        -e ELASTICSEARCH_SERVERS=https://admin:admin@$managementIp:9200
                        -e MANAGEMENT_ADDRESS=$managementIp
                        --network fusion2_esnet
                        --ulimit nofile=65536:65536
                        --ulimit memlock=-1:-1
                        -p 8457:8457
                        -p 8443:8443
                        --restart always
                        $fusionImage"
    # hide docker run output in case of existing image (we don't want to display a created container id)
    $dockerRunCommand 1> /dev/null

    if [ $? -gt 0 ]; then
        echoRed "Error during running a container"
        exit 1
    fi

    echo -e "Container with name ${textLightGray}$containerName${textNc} was created" 
    
    echoBlue "Waiting for Fusion to start"
    uiStatus="down"
    while [ $uiStatus = "down" ]; do
        echo -n .
        uiStatus=$(getFusionUiStatus ${managementIp})
        sleep 1
    done
    echo
    docker exec -it $containerName /bin/nefclient sysconfig setProperty "{id:'fusion.eulaAccepted', value: 1}" > /dev/null
    echoBlue "Fusion is available at https://${managementIp}:8457"
}

### WIZARD START

# start script as sudo
if (( $EUID != 0 )); then
    echo "Starting fusion-installer as sudo"
    echo
    exec sudo $0 "$@"
fi

# welcome message
echo
echo "${textBold}This utility will walk you through installing Fusion to run as a Docker container.${textNormal}"
echo "Refer to the Fusion Installation Guide for additional details."
echo
echo "The required information will be requested and minimums confirmed."
echo 
echo "Fusion uses ports 8443, 8457 and 9200"
echo "Ensure that your firewall allows access to the above."

if isCentOS; then
    echo
    echo "The container must be able to access port 9200 using the the Management address. This may require changes to iptables."
fi

echo
echo "Press ^C (Ctrl+C) at any time to quit."
echo



# check if there is enough memory
calculateRAM

if $isLowMemory; then
    echoRed "The OS reports ${totalMemory}, which is less than the 1g minimum."
    echoRed "Fusion may not operate properly."
    echo
    echoRed "Exiting..."
    
    exit 1
fi

# check if docker is installed
if ! [ -x "$(which docker)" ]; then
    echoRed "Docker is not installed. Please install Docker (https://www.docker.com/products/container-runtime#/download) and then run the fusion-installer again" >&2
    exit 1
fi

# check if docker daemon is up
dockerDaemonStarted=true
# docker info will exit with error code, if docker daemon is no up
docker info &> /devnull || dockerDaemonStarted=false

if ! $dockerDaemonStarted; then
    echoRed "Docker daemon is not running"
    echoBlue "Starting docker daemon..."
    if isMacOS; then
        open --background -a Docker
    else
        sudo service docker start
    fi
    # wait until docker daemon is up
    while ! docker info &> /devnull; do sleep 1; done
fi

# check if fusion container already exists
if [ -n "$(docker ps -a -f "name=${containerName}" | grep ${containerName})" ]; then
    echo "You already have an existing Fusion container"
    echo "Do you want to stop and remove the current container and run a new one?"
    echo "This will not effect your Fusion data"
    echo "[y/N]"
    read removeCurrentContainer

    previouslyUsedManagementIp=$(docker inspect $containerName | grep MANAGEMENT_ADDRESS | grep -Eo '([0-9]+\.){3}[0-9]+')

    if [ "$removeCurrentContainer" = "y" ]; then
        echoBlue "Removing current container..." 
        sudo docker rm -f $containerName 1>/dev/null
    else 
        echoBlue "Exiting..." 
        exit 0
    fi
fi

### Questions

### Question 0
oldHostName=$(hostname)
echoBlue "Use current hostname ($oldHostName) or enter new one?"
echo "----------------"
opts=("New" "Existing")
displayNetworkOptions
readSelectedOption opts
selectedOptIndex=$(( $? ))
if [ $selectedOptIndex = 1 ]; then
    echoBlue "Enter new hostname: "
    read newHostName
    hostnamectl set-hostname $newHostName
    sed -i "s/$oldHostName/$newHostName/g" /etc/hosts
fi

getIfs
getIps
if [[ ${#ips[@]} > 0 ]]; then
    ask "Do you want to set a management IP address or use existing?" "
    This IP address is used by appliances
    for pushing analytics data, logs, events.
    Please make sure that specified address is accessible by appliances.
    Typically, this address is equal to address you use to access UI."
    displayNetworkOptions
    readSelectedOption opts
    selectedOptIndex=$(( $? ))
else
    echo -e "${textBlue}No IP address is available, proceed to configure network${textNc}"
    selectedOptIndex=1
fi

if [ $selectedOptIndex = 1 ]; then
    echoBlue "Select which interface you want to configure"
    echo "----------------"
    displayIfs
    readSelectedOption ifs
    selectedNicIndex=$(( $? - 1 ))
    nic=${ifs[selectedNicIndex]}

    echoBlue "Do you want to use DHCP or static IP?"
    echo "----------------"
    opts=("DHCP" "Static")
    displayNetworkOptions
    readSelectedOption opts
    selectedOptIndex=$(( $? ))
    if [[ $selectedOptIndex == 1 ]]; then useDhcp=true; fi

    configureNetwork
    waitForIp
    managementIp=$(ip a show $nic| grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
else
    echoBlue "Select which IP address you want to use"
    echo "----------------"
    displayIpOptions ips
    readSelectedOption ips
    selectedIpIndex=$(( $? - 1 ))
    managementIp=${ips[$selectedIpIndex]}
fi

### Question 1
echoDefaults

echo
echo "Type y to accept the defaults. Type n to change the values"
echo "[Y/n]"
read isDefaultsAccpeted

if [ "$isDefaultsAccpeted" = "n" ]; then
    ### Question 2
    ask "Type the ESDB heap size or press enter to retain the default ($defaultHeapSize)" \
        "Enter the quantity of memory to reserve for the analytics database or press enter to accept the default. The default recommendation for cluster is half of the total system memory, with a minimum of 1g and a maximum of 31g.\nExample: 8g"
    echo "Your machine has $totalMemory of RAM"
    echo "Type a heap size for one ESDB cluster node and press enter. Total nodes count:${textBold} ${esNodesCount} ${textNormal}"
    read typedHeapSize

    # check if heap size is correctly typed and more or equal to 1000m
    if [ -n "$typedHeapSize" ]; then
        heapSizeRegex="^[0-9]+[m,g]$"
        while true; do
            if ! [[ "$typedHeapSize" =~ $heapSizeRegex ]]; then
                echoRed "Invalid value. Please enter valid value. Examples: 2048m, 16g"
            # validate mebibytes input
            elif [[ "$typedHeapSize" =~ [0-9]+m ]]; then
                mebibytes=$(echo ${typedHeapSize} | grep -Eo "[0-9]+")
                if [[ $mebibytes -lt 1024 ]]; then
                    echoRed "Invalid value. Heap size must be greater or equal to 1g. Please type correct value"
                    echo "Type a heap size and press enter"
                elif [[ $mebibytes -gt 1024*31 ]]; then
                    echoRed "Invalid value. Heap size must be less or equal to 31g. Please type correct value"
                    echo "Type a heap size and press enter"
                else
                    break
                fi
            # validate gibibytes input
            elif [[ "$typedHeapSize" =~ [0-9]+g ]]; then
                gibibytes=$(echo ${typedHeapSize} | grep -Eo "[0-9]+")
                if [[ $gibibytes -gt $defaultHeapSizeLimitG ]]; then
                    echoRed "Invalid value. Heap size must be less or equal to 31g. Please type correct value"
                    echo "Type a heap size and press enter"
                else
                    break
                fi
            else
                break
            fi 
            read typedHeapSize
        done
        typedHeapSizeTotal=$(( ${typedHeapSize::-1} * esNodesCount ))${typedHeapSize: -1}
    fi

    ### Question 3
    ask "Type Fusion volume name or press enter to retain the default ($defaultFusionVol)"
    read typedFusionVol
fi

### Question 4
fusionVersion=$(echo $fusionImage |  cut -d ":" -f 2)
echoBlue "Do you want to use current fusion version ($fusionVersion)? Type n to change the values"
echo "----------------"
echo "[Y/n]"
read isVersionAccpeted
if [ "$isVersionAccpeted" = "n" ]; then
    ### Question 5
    echoBlue "Input the preferred fusion version"
    read fusionVersionInput
    fusionImage="nexenta/fusion:"$fusionVersionInput
fi

### Question 6
opensearchVersion=$(grep -m1 'image: nexenta/fusion-open' $(dirname "$0")/docker-compose.yml | awk '{print $2}' | cut -d ":" -f 2)
echoBlue "Do you want to use current opensearch version ($opensearchVersion)? Type n to change the values"
echo "----------------"
echo "[Y/n]"
read isVersionAccpeted
if [ "$isVersionAccpeted" = "n" ]; then
    ### Question 7
    echoBlue "Input the preferred opensearch version"
    read opensearchVersionInput
    sed -i "s/$opensearchVersion/$opensearchVersionInput/g" $(dirname "$0")/docker-compose.yml
fi

prepareContainerParams

# clean install means that data is not exported from other Fusion container
isCleanInstall=true
fusVol=$(sudo docker volume ls | grep fusion2_fusdata)
esVol=$(sudo docker volume ls | grep fusion2_esdata1)

if [ ! -z "$fusVol" ] && [ ! -z "$esVol" ]; then
    echo 
    echo "There is data from previous Fusion and ESDB containers in specified volumes";
    echo "Do you want to use them?"
    echo "[Y/n]"
    read useOldData
    if [ "$useOldData" = "n" ]; then
        echoBlue "Removing previous ElasticSearch container data..."
        export ES_HEAP_SIZE=512m
        docker-compose -f $(dirname "$0")/docker-compose.yml down -v
        echoBlue "Removing previous Fusion container data..."
        docker volume prune -f
        else 
        isCleanInstall=false
    fi 
fi

runContainer $isDefaultsAccpeted

if "$isCleanInstall" = true; then
    echo
    echo "Default login/password: admin/fusion"
    echo
fi
