#!/bin/bash

defaultFusionPath="$(eval echo ~$SUDO_USER)/fusion"
containerName="nexenta-fusion"
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

getIps() {
    # CentOS 7 does not have ifconfig preinstalled
    # MacOS does not have ip preinstalled
    if [ -x "$(which ifconfig 2> /dev/null)" ]; then
        ips=$(ifconfig)
    elif [ -x "$(which ip)" ]; then 
        ips=$(ip addr)
    fi

    ips=($(echo "${ips}" | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*'))
}

getTimezone() {
    # Ubuntu
    if [ -f /etc/timezone ]; then
        OLSONTZ=$(cat /etc/timezone)
    elif [ -x "$(sudo command -v systemsetup)" ]; then
    # MacOS
        OLSONTZ=$(sudo systemsetup -gettimezone | grep -Eo '(\w+\/\w+)')
    elif [ -h /etc/localtime ]; then
    # CentOS
        OLSONTZ=$(readlink /etc/localtime | grep -Eo "\w+\/\w+$")
    else
        checksum=$(md5sum /etc/localtime | cut -d' ' -f1)
        OLSONTZ=$(find /usr/share/zoneinfo/ -type f -exec md5sum {} \; | grep "^$checksum" | sed "s/.*\/usr\/share\/zoneinfo\///" | head -n 1)
    fi
}

calculateRAM() {
    # NOTE: ESDB heap size is calculated in units defined as powers of 2
    isLowMemory=false
    if [ -x "/usr/sbin/system_profiler" ]; then
        # mac os way to find total RAM
        totalMemory=$(system_profiler SPHardwareDataType | grep "  Memory:" | grep -Eo '[0-9]+')
        # for mac users we expect that they all have RAM more than 1g and which can be divided by 2
        # in other cases we set 1g as default
        defaultHeapSize=$(( ${totalMemory} / 2 ))
        
        if [ $defaultHeapSize -gt $defaultHeapSizeLimitG ]; then
            defaultHeapSize=$defaultHeapSizeLimitG
        fi

        defaultHeapSize="${defaultHeapSize}g"

        if ! [[ $defaultHeapSize =~ ^[0-9]+g$ ]]; then
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
        defaultHeapSize=$(( totalMemory / 2))
        if [ $defaultHeapSize -gt $defaultHeapSizeLimitBytes ]; then
            # if half of memory is more than 31gib we set 31gib as default heap size
            defaultHeapSize="31g"
        # if there is more than 1gib but less than 2gib of total RAM
        # set default heap size 1gib
        # 1024^3bytes = 1gib
        elif [[ $defaultHeapSize -lt $onegib ]]; then
            defaultHeapSize="1g"
        else 
            # converting to mibibytes since result of division may be not an integer number
            # of gibibytes
            # 1mib = 1024^2
            defaultHeapSize=$( numfmt --to-unit=1048576 --suffix=m ${defaultHeapSize})
        fi 
       
        # converting to human readable value
        totalMemory=$( numfmt --round=nearest --to=iec ${totalMemory})
    fi
}

displayIpOptions() {
    local name=$1[@]
    local options=("${!name}");
    
    for ((i=0; i < ${#options[@]}; i++)) {
        if [[ "$previouslyUsedManagementIp" ==  ${options[$i]} ]]; then
            local comment="(previously used by NexentaFusion container)"
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
        if [[ "$input" =~ [1-${#options[@]}] ]]; then
            correct=1;
        else
            echoRed "Invalid option. Please enter valid option"    
        fi
    done

    return $input
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
    ask "Defaults have been selected for the following parameters:" "ESDB heap size is the memory reserved for the analytics database. The default recommendation is half of the total system memory, but not more than 31g (your machine has $totalMemory of RAM)."
    echo "ESDB heap size:${textBold} ${defaultHeapSize} ${textNormal}"
    echo "Timezone:${textBold} $OLSONTZ ${textNormal}"
    echo "NexentaFusion folders path:${textBold} $defaultFusionPath ${textNormal}"
}
#

prepareContainerParams() {
    managementIp=${ips[$selectedIpIndex]}
    heapSize=$typedHeapSize
    
    if [ -z "$typedTZ" ]; then
        tz=$OLSONTZ
    else
        tz=$typedTZ
    fi

    if [ -z "$typedFusionPath" ]; then
        path=$defaultFusionPath
    else 
        path=$typedFusionPath
    fi

    if [ -z "$typedHeapSize" ]; then
        heapSize=$defaultHeapSize
    else 
        heapSize=$typedHeapSize
    fi
}

runContainer() {
    # show summary if defaults were not accepted
    if [ "$1" = "n" ]; then
        echoBlue "The NexentaFusion container will be run with the following parameters:"
        echo "Management IP:${textBold} $managementIp${textNormal}"
        echo "ESDB heap size:${textBold} ${heapSize} ${textNormal}"
        echo "Timezone:${textBold} $tz ${textNormal}"
        echo "NexentaFusion folders path:${textBold} $path ${textNormal}"
        echo
        echo "Press any key to continue"
        read
    fi

    # checking if there is new image
    echoBlue "Checking the NexentaFusion container image..."
    docker pull nexenta/fusion

    echoBlue "Running the NexentaFusion container..."
    dockerRunCommand="sudo docker run --name $containerName -v $path/elasticsearch:/var/lib/elasticsearch:z -v $path/nef:/var/lib/nef:z -e MGMT_IP=$managementIp --ulimit nofile=65536:65536 --ulimit memlock=-1:-1 -e ES_HEAP_SIZE=$heapSize -e TZ=$tz -p 8457:8457 -p 9200:9200 -p 8443:8443 -p 2000:2000 -i -d nexenta/fusion"

    # hide docker run output in case of existing image (we don't want to display a created container id)
    $dockerRunCommand 1> /dev/null

    if [ $? -gt 0 ]; then
        echoRed "Error during running a container"
        exit 1
    fi

    echo -e "Container with name ${textLightGray}$containerName${textNc} was created" 
    
    echoBlue "Waiting for NexentaFusion to start"
    uiStatus="down"
    while [ $uiStatus = "down" ]; do
        echo -n .
        uiStatus=$(getFusionUiStatus ${managementIp})
        sleep 1
    done
    echo
    echoBlue "NexentaFusion is available at https://${managementIp}:8457"
}

### WIZARD START

# start script as sudo
if (( $EUID != 0 )); then
    echo "Starting nexenta-fusion-installer as sudo"
    echo
    exec sudo $0 "$@"
fi

# welcome message
echo "This utility will walk you through installing NexentaFusion to run as a Docker container."
echo "Refer to the NexentaFusion Installation QuickStart guide for additional details."
echo
echo "The required information will be requested and minimums confirmed."
echo 
echo "NexentaFusion uses ports 2000, 8443, 8457 and 9200"
echo "Ensure that your firewall allows access to the above."

if isCentOS; then
    echo
    echo "The container must be able to access port 9200 using the the management address. This may require changes to iptables."
fi

echo
echo "Press ^C at any time to quit."
echo



# check if there is enough memory
calculateRAM

if $isLowMemory; then
    echoRed "The OS reports ${totalMemory}, which is less than the 1g minimum."
    echoRed "NexentaFusion may not operate properly."
    echo
    echoRed "Exiting..."
    
    exit 1
fi

# check if docker is installed
if ! [ -x "$(which docker)" ]; then
    echoRed "Docker is not installed. Please install Docker (https://www.docker.com/community-edition#/download) and then run the nexenta-fusion-installer again" >&2
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

# check if fusion container is already exists
if [ -n "$(docker ps -a -f "name=${containerName}" | grep ${containerName})" ]; then
    echo "You already have an existing NexentaFusion container"
    echo "Do you want to stop and remove the current container and run a new one?"
    echo "This will not effect your NexentaFusion data"
    echo "[y/N]"
    read removeCurrentContainer

    previouslyUsedManagementIp=$(docker inspect nexenta-fusion | grep MGMT | grep -Eo '([0-9]+\.){3}[0-9]+')

    if [ "$removeCurrentContainer" = "y" ]; then
        echoBlue "Removing current container..." 
        sudo docker rm -f $containerName 1>/dev/null
    else 
        echoBlue "Exiting..." 
        exit 0
    fi
fi

getTimezone

### Questions

### Question 0
getIps
ask "Please select the management address:" "This IP address is used by appliances for pushing analytics data, logs, events"
displayIpOptions ips
readSelectedOption ips
selectedIpIndex=$(( $? - 1 ))

### Question 1
echoDefaults

echo
echo "Type y to accept the defaults. Type n to change the values"
echo "[Y/n]"
read isDefaultsAccpeted

if [ "$isDefaultsAccpeted" = "n" ]; then
    ### Question 2
    ask "Type the timezone or press enter to retain the default ($OLSONTZ)" "Timezone is used for correct processing of logs"
    read typedTZdd

    ### Question 3
    ask "Type the ESDB heap size or press enter to retain the default ($defaultHeapSize)" "Enter the quantity of memory to reserve for the analytics database or press enter to accept the default. The default recommendation is half of the total system memory, with a minimum of 1g and a maximum of 31g.\nExample: 8g"
    echo "Your machine has $totalMemory of RAM"
    echo "Type a heap size and press enter"
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
    fi

    ### Question 4
    ask "Type NexentaFusion path or press enter to retain the default ($defaultFusionPath)" "This directory is used to store NexentaFusion and ESDB data"
    read typedFusionPath
fi

prepareContainerParams

# clean install means that data is not exported from other NexentaFusion container
isCleanInstall=true

if [ -d "${path}/nef" ] && [ -d "${path}/elasticsearch" ]; then
    echo 
    echo "There is data from previous NexentaFusion container in specified path";
    echo "Do you want to use it?"
    echo "[Y/n]"
    read useOldData
    if [ "$useOldData" = "n" ]; then
        echoBlue "Removing previous NexentaFusion container data..."
        rm -rf $path/nef
        rm -rf $path/elasticsearch
        else 
        isCleanInstall=false
    fi 
fi

runContainer $isDefaultsAccpeted

if "$isCleanInstall" = true; then
    echo
    echo "Default login/password: admin/nexenta"
    echo
fi
