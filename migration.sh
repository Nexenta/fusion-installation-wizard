#!/bin/bash

defaultDirectory="$HOME/fusion"
# text formatting variables
textNc='\033[0m'
textBlue='\033[0;36m'

echo
read -p "Enter IP address of NexentaFusion: " ipAddress

echo "Specify folder or press enter to retain default ($defaultDirectory)"
read typedDirectory

if [ -z "$typedDirectory" ]; then
    directory=$defaultDirectory
else
    directory=$typedDirectory
fi

if ! [ -d $directory ]; then
    mkdir $directory
fi

echo -e "${textBlue}Changing owner of nef folder...${textNc}"
ssh -tt fusion@$ipAddress 'sudo service nexenta-fusion stop && sudo service elasticsearch stop && sudo chown -R fusion:fusion /var/lib/nef'
echo -e "${textBlue}Copying nef folder...${textNc}"
scp -r fusion@$ipAddress:/var/lib/nef $directory/nef
echo -e "${textBlue}Copying elasticsearch folder...${textNc}"
scp -r fusion@$ipAddress:/var/lib/elasticsearch $directory

