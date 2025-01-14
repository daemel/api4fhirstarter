#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# -e: immediately exit if any command has a non-zero exit status
# -o: prevents errors in a pipeline from being masked
# IFS new value is less likely to cause confusing bugs when looping arrays or arguments (e.g. $@)
#
# FHIR API and keyVaultName setup --- Author Steve Ordahl Principal Architect Health Data Platform
#


#########################################
# HealthArchitecture Deployment Settings 
#########################################
declare TAG="HealthArchitectures: FHIR-API"


#########################################
# Script / App Default Name settings (sf = secure function, fhir = fhir api, kv = key vault) 
#########################################
declare distribution="../distribution/publish.zip"
declare defAppInstallPrefix="fhir"$RANDOM
declare defKeyVaultName=$defAppInstallPrefix"kv"

#########################################
# Script Control Variables
#########################################
# set for workflow


#########################################
# Variables
#########################################

# common 
declare defSubscriptionId=""
declare subscriptionId=""
declare resourceGroupName=""
declare resourceGroupLocation=""
declare storageAccountNameSuffix="store"
declare storageConnectionString=""
declare serviceplanSuffix="asp"
declare stepresult=""

# FHIR
declare fhirServiceUrl=""
declare fhirServiceClientId=""
declare fhirServiceClientSecret=""
declare fhirServiceTenant=""
declare fhirServiceAudience=""
declare fhirResourceId=""

# SyncAgent
declare syncAgentServicePrincipalId=""

# Proxy 
declare deployPrefix=""
declare defDeployPrefix=""
declare stepresult=""
declare functionAppName=""
declare functionAppHost=""
declare functionAppKey=""
declare functionAppResourceId=""
declare roleAdmin="Administrator"
declare roleReader="Reader"
declare roleWriter="Writer"
declare rolePatient="Patient"
declare roleParticipant="Practitioner,RelatedPerson"
declare roleGlobal="DataScientist"
declare spappid=""
declare spsecret=""
declare sptenant=""
declare spreplyurls=""
declare tokeniss=""
declare preprocessors=""
declare postprocessors=""
declare msi=""
declare count="0"

# keyvault
declare keyVaultNameAccountNameSuffix="kv"$RANDOM
declare keyVaultName=""
declare keyVaultExists=""



declare fsresourceid=""
declare fhirServiceName=""
declare fsexists=""
declare fhirServiceClientId=""
declare fhirServiceTenantid=""
declare fhirServiceClientSecret=""
declare fhirServiceAudienceience=""
declare fsoid=""
declare spname=""
declare repurls=""


declare genpostman=""
declare pmenv=""
declare pmuuid=""
declare pmfhirurl=""

#########################################
#  Script Functions 
#########################################

function intro {
	# Display the intro - give the user a chance to cancel 
	#
	echo " "
	echo "FHIR-API Application deployment script... "
	echo " - Prerequisite:  User must have rights to provision Resources within the Subscription scope (ie Contributor) "
    echo " - Prerequisite:  Azure CLI (bash) access from the Azure Portal"
	echo " "
	echo "The script gathers information then lets users choose to use a template or script deployment.  Users without CLI Access "
    echo "can use the template deployment from the templates directory in this repo."
	echo " "
	read -p 'Press Enter to continue, or Ctrl+C to exit'
}

usage() { echo "Usage: $0  -i <subscriptionId> -g <resourceGroupName> -l <resourceGroupLocation> -k <keyVaultNameName> -n <fhirServiceName> -p (to generate postman environment)" 1>&2; exit 1; }


function retry {
	# Retry logic  
    local n=1
    local max=5
    local delay=20
    while true; do
      "$@" && break || {
        if [[ $n -lt $max ]]; then
          ((n++))
          echo "Command failed. Retry Attempt $n/$max in $delay seconds:" >&2
          sleep $delay;
        else
          echo "The command has failed after $n attempts."
		  exit 1 ;
        fi
      }
    done
}

function kvuri {
	echo "@Microsoft.keyVault(SecretUri=https://"$kvname".vault.azure.net/secrets/"$@"/)"
}

function result () {
    if [[ $1 = "ok" ]]; then
        echo -e "..................... [ \033[32m ok \033[37m ] \r" 
      else
        echo -e "..................... [ \033[31m failed \033[37m ] \r"
        exit 1
      fi
    echo -e "\033[37m \r"
    sleep 1
}

function appState () {
	az functionapp show --name $1 --resource-group $2 | grep state
	sleep 2
}

function healthCheck () {
	# Create a healthcheck varibales list to test the FHIR-SyncAgent deployment 
	#
	local functionname1=""
	local functionname2=""

	functionname1=$(echo $1 | awk -F= '{ print $1 }')
	functionname2=$(echo $1 | awk -F= '{ print $2 }')

	if [[ $count -eq 0 ]]; then
		echo "# FHIR Sync Agent Healthcheck variables" > ./healthcheck.txt
		echo "declare $functionname1=\"$functionname2\"" >> ./healthcheck.txt ;
	else 
		echo "declare $functionname1=\"$functionname2\"" >> ./healthcheck.txt ;
	fi 
	((count++))
}







#########################################
#  Script Main Body (start script execution here)
#########################################

# Initialize parameters specified from command line
#
while getopts ":k:n:p" arg; do
	case "${arg}" in
		k)
			keyVaultName=${OPTARG}
			;;
		n)
			fhirServiceName=${OPTARG}
			;;
		p)
			genpostman="yes"
			;;
		i)
			subscriptionId=${OPTARG}
			;;
		g)
			resourceGroupName=${OPTARG}
			;;
		l)
			resourceGroupLocation=${OPTARG}
			;;
	esac
done
shift $((OPTIND-1))
echo "Deploy Azure API for FHIR..."
echo "Checking Azure Authentication..."
#login to azure using your credentials
az account show 1> /dev/null

if [ $? != 0 ];
then
	az login
fi
defSubscriptionId=$(az account show --query "id" --out json | sed 's/"//g') 


# Call the Introduction function 
#
intro

#Prompt for common parameters if some required parameters are missing
#
echo " "
echo "Collecting Azure Parameters (unless supplied on the command line) "

if [[ -z "$subscriptionId" ]]; then
	echo "Enter your subscription ID <press Enter to accept default> ["$defSubscriptionId"]: "
	read subscriptionId
	if [ -z "$subscriptionId" ] ; then
		subscriptionId=$defSubscriptionId
	fi
	[[ "${subscriptionId:?}" ]]
fi

if [[ -z "$resourceGroupName" ]]; then
	echo "This script will look for an existing resource group, otherwise a new one will be created "
	echo "You can create new resource groups with the CLI using: az group create "
    echo " "
	echo "Enter a resource group name []: "
	read resourceGroupName
	[[ "${resourceGroupName:?}" ]]
fi

if [[ -z "$resourceGroupLocation" ]]; then
	echo "If creating a *new* resource group, you need to set a location "
	echo "You can lookup locations with the CLI using: az account list-locations "
	echo " "
	echo "Enter resource group location []: "
	read resourceGroupLocation
	[[ "${resourceGroupLocation:?}" ]]
fi

# Ensure there are subscriptionId and resourcegroup names 
#
if [ -z "$subscriptionId" ] || [ -z "$resourceGroupName" ]; then
	echo "Either one of subscriptionId, resourceGroupName is empty, exiting..."
	exit 1
fi


# Prompt for script parameters if some required parameters are missing
#
echo " "
echo "Collecting Script Parameters (unless supplied on the command line).."

# Set a Default Deployment Prefix
#
defDeployPrefix=${defAppInstallPrefix:0:12}
defDeployPrefix=${defDeployPrefix//[^[:alnum:]]/}
defDeployPrefix=${defDeployPrefix,,}

# Prompt for deployment prefix, otherwise use the defaulf 
#
if [[ -z "$deployPrefix" ]]; then
	echo "Enter your application install prefix <press Enter to accept default> ["$defDeployPrefix"]:"
	read deployPrefix
	if [ -z "$deployPrefix" ] ; then
		deployPrefix=$defDeployPrefix
	fi
	deployPrefix=${deployPrefix:0:12}
	deployPrefix=${deployPrefix//[^[:alnum:]]/}
    deployPrefix=${deployPrefix,,}
	[[ "${deployPrefix:?}" ]]
fi

# Set a Default KeyVault Name 
#
defKeyVaultName=${defKeyVaultName:0:14}
defKeyVaultName=${defKeyVaultName//[^[:alnum:]]/}
defKeyVaultName=${defKeyVaultName,,}

# Prompt for remaining details 
#
echo " "
if [[ -z "$keyVaultName" ]]; then
	echo "Enter your application install prefix <press Enter to accept default> ["$defKeyVaultName"]:"
	read defKeyVaultName
	if [ -z "$defKeyVaultName" ] ; then
		defKeyVaultName=$defKeyVaultName
	fi
	defKeyVaultName=${defKeyVaultName:0:14}
	defKeyVaultName=${defKeyVaultName//[^[:alnum:]]/}
    defKeyVaultName=${defKeyVaultName,,}
	[[ "${defKeyVaultName:?}" ]]
fi


# Check KV exists and load information 
#
echo " "
echo "Checking for Key Vault "$keyVaultName"..."
keyVaultExists=$(az keyvault list --query "[?name == '$keyVaultName'].name" --out tsv)
if [[ -n "$keyVaultExists" ]]; then
	set +e
	echo "  "$keyVaultName "found"
	echo "  Checking ["$keyVaultName"] for FHIR Service configuration..."
	fhirServiceUrl=$(az keyvault secret show --vault-name $keyVaultName --name FS-URL --query "value" --out tsv)
	if [ -n "$fhirServiceUrl" ]; then
		echo "  found FHIR Service ["$fhirServiceUrl"]"
        fhirResourceId=$(az keyvault secret show --vault-name $keyVaultName --name FS-URL --query "value" --out tsv | awk -F. '{print $1}' | sed -e 's/https\:\/\///g') ;
		echo "  FHIR Resource ID set to: ["$fhirResourceId"]"
	else	
		echo "  unable to read FS-URL from " $keyVaultName 
        echo "  setting script to create new FS-URL Entry in "$keyVaultName
	fi 
else
	echo "Failed to find Key Vault..." $keyVaultName ;
	result "fail";
fi


# Prompt for FHIR-SyncAgent Information  
#
echo " "
echo "Enter the FHIR-SyncAgent app name <press Enter to accept default> ["$deffhirSyncAgentAppName"]:"
	read fhirSyncAgentAppName
	if [ -z "$fhirSyncAgentAppName" ] ; then
		fhirSyncAgentAppName=$deffhirSyncAgentAppName
	fi
	[[ "${fhirSyncAgentAppName:?}" ]]



# set the default subscription id
#
echo "Setting default subscription....."
az account set --subscription $subscriptionId

set +e

# Check for existing RG
#
if [ $(az group exists --name $resourceGroupName) = false ]; then
	echo "Resource group with name" $resourceGroupName "could not be found.   Exiting..."
	usage ;
else
	echo "Using $resourceGroupName as resource group..."
fi

#
echo "Ready to start deployment of ["$fhirSyncAgentAppName"] with the following values:"
echo "Subscription ID: " $subscriptionId
echo "Resource Group Name: " $resourceGroupName 
echo "Resource Group Location: " $resourceGroupLocation 
echo "Application Prefix: " $deployPrefix
echo " FHIR-Proxy App Name: "$fpappname 
echo " FHIR Service Name: "$fhirResourceId
echo " "
echo "Please validate the settings above and... "
read -p 'Press Enter to continue, or Ctrl+C to exit'


#############################################
#  Setup healthCheck variables file  
#############################################
# update healthcheck file 
healthCheck keyVaultNamename=$kvname
healthCheck subscriptionId=$subscriptionId
healthCheck resourceGroupName=$resourceGroupName
healthCheck resourceGroupLocation=$resourceGroupLocation
healthCheck fhirProxy=$fpappname
healthCheck fhirService=$fhirResourceId
healthCheck fhirSyncAgent=$fhirSyncAgentAppName
