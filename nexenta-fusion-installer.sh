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
    isLowMemory=false
    if [ -x "/usr/sbin/system_profiler" ]; then
        # mac os way to find total RAM
        totalMemory=$(system_profiler SPHardwareDataType | grep "  Memory:" | grep -Eo '[0-9]+')
        # for mac users we expect that they all have RAM more than 1g and which can be divided by 2
        # in other cases we set 1g as default
        if [[ $totalMemory -lt 2 ]]; then
            isLowMemory=true
        fi
        defaultHeapSize=$(( ${totalMemory} / 2 ))g
        if ! [[ $defaultHeapSize =~ ^[0-9]+g$ ]]; then
            defaultHeapSize="1g"
        fi
        totalMemory=${totalMemory}g
    elif [ -f "/proc/meminfo" ]; then
        # linux way to find total RAM
        totalMemory=$(cat /proc/meminfo | grep -Po "(?<=MemTotal:)(\s+)(\w+)" | grep -Eo "\w+")
        # converting to bytes
        # if total memory is lower than 2g
        if [[ $totalMemory -lt 1024*1024*2 ]]; then
            isLowMemory=true
        fi
        # total memory is presented in kib
        totalMemory=$(( totalMemory * 1024 ))
        defaultHeapSize=$(( totalMemory / 2))
        # 1024^2 = 1048576 // 1mb
        defaultHeapSize=$( numfmt --to-unit=1048576 --suffix=m ${defaultHeapSize})
        # converting to human readable value
        totalMemory=$( numfmt --to=iec ${totalMemory})
    fi
}

displayOptions() {
    local name=$1[@]
    local options=("${!name}");
    
    for ((i=0; i < ${#options[@]}; i++)) {
        echo "$(($i + 1))) ${options[$i]}"
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

# text functions 
echoBlue() {
    echo -e "${textBlue}${1}${textNc}"
}

echoRed() {
    echo -e "${textRed}${1}${textNc}"
}

echoError() {
    echo -e "${textRed}Error: ${1}${textNc}" >&2
}

echoDefaults() {
    ask "Defaults have been selected for the following parameters:" "ESDB heap size is the memory reserved for the analytics database. The default recommendation is half of the total system memory (your machine has $totalMemory of RAM)."
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
    dockerRunCommand="sudo docker run --name $containerName -v $path/elasticsearch:/var/lib/elasticsearch:z -v $path/nef:/var/lib/nef:z -e MGMT_IP=$managementIp --ulimit nofile=65536:65536 --ulimit memlock=-1:-1 -e ES_HEAP_SIZE=$heapSize -e TZ=$tz -p 8457:8457 -p 9200:9200 -p 8443:8443 -i -d nexenta/fusion"

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
echo "The required information will be requested and minimums confirmed."
echo
echo "Press ^C at any time to quit."
echo

# check if there is enough memory
calculateRAM

if $isLowMemory; then
    echoRed "The OS reports ${totalMemory}, which is less than the 2GB minimum."
    echoRed "Fusion may not operate properly."
    echoRed "Do you still want to continue?"
    echoRed "[y/N]"
    read lowMemoryContinue
    
    if [ "$lowMemoryContinue" != "y" ]; then
        exit 1
    fi
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
displayOptions ips
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
    ask "Type the ESDB heap size or press enter to retain the default ($defaultHeapSize)" "Enter the quantity of memory to reserve for the analytics database or press enter to accept the default. The default recommendation is half of the total system memory, with a minimum of 1 g and a maximum of 32 g.\nExample: 8g"
    echo "Your machine has $totalMemory of RAM"
    echo "Type a heap size and press enter"
    read typedHeapSize

    # check if heap size is correctly typed and more or equal to 1024m
    if [ -n "$typedHeapSize" ]; then
        heapSizeRegex="^[0-9]+[m,g]$"
        while true; do
            if ! [[ "$typedHeapSize" =~ $heapSizeRegex ]]; then
                echoRed "Invalid value. Please enter valid value. Example: 1536m"
            elif [[ "$typedHeapSize" =~ [0-9]+m ]]; then
                megabytes=$(echo ${typedHeapSize} | grep -Eo "[0-9]+")
                if [ $megabytes -lt 1024 ]; then
                    echoRed "Invalid value. Heap size must be more or equal to 1024m"
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
        rm -rf $path/*
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