#!/usr/bin/env bash

# set -x
set -e

aws sts get-caller-identity 1>/dev/null 2>/dev/null || ( echo "Cannot talk to AWS -- \`aws sts get-caller-identity\` failed -- bailing out." ; exit 99 )

confirm(){
  __PROMPT=${1:-"Continue?"}" (y/N) > "
  read -p "$__PROMPT" __CONT
  if [[ "$__CONT" = "y" ]]; then
    echo "continuing..."
  else
    echo "confirmation negative; bailing out!"
    exit 99
  fi
}

if [[ -z "$1" ]]; then
  read -p "Hosted zone name: " _HOSTED_ZONE_NAME
else
  _HOSTED_ZONE_NAME="$1"
fi

if [[ -z "$2" ]]; then
  read -p "This computers hostname (or any name to remember it by): " _MY_HOSTNAME
else
  _MY_HOSTNAME="$2"
fi
SAFE_HOSTNAME=$( echo "$_MY_HOSTNAME" | sed 's/\./-/g' )

echo "Using hosted zone: $_HOSTED_ZONE_NAME"
echo "Using hostname (this pc): $_MY_HOSTNAME (safe: $SAFE_HOSTNAME)"

confirm

# remove trailing periods if they exist
HOSTED_ZONE_NAME=$( echo "$_HOSTED_ZONE_NAME" |  sed 's/\.$//g' )

# trailing period important
HOSTED_ZONE_ID=$( aws route53 list-hosted-zones-by-name | jq -r '.HostedZones | map(select( .Name ==  "'$HOSTED_ZONE_NAME'." )) | .[0]' )

if [[ "$HOSTED_ZONE_ID" = "null" ]]; then
  echo "Error: hosted zone not found. try 'aws route53 list-hosted-zones-by-name'"
  exit 2
fi

HOSTED_ZONE_ID=$( echo "$HOSTED_ZONE_ID" | jq -r '.Id' | sed 's/\/hostedzone\///g' )

echo -n "Hosted Zone ID: $HOSTED_ZONE_ID"

HOSTED_ZONE_NAME_SAFE=$( echo "$HOSTED_ZONE_NAME" | sed 's/\./-/g' )
#POLICY_PATH=/ddns/host-$SAFE_HOSTNAME/zone-$HOSTED_ZONE_NAME_SAFE/
POLICY_PATH=/ddns/updater/
POLICY_NAME=ddns-update-zone--$HOSTED_ZONE_NAME_SAFE
POLICY_FULL="$POLICY_PATH$POLICY_NAME"

IAM_USER_NAME="ddns.updater.$HOSTED_ZONE_NAME_SAFE"

echo "Policy: $POLICY_FULL"

echo "Checking if it exists..."

CHECK_EXISTING=$(aws iam list-policies --query "Policies[?PolicyName == '$POLICY_NAME' && Path ==  '$POLICY_PATH']" | jq -r .[0])

if [[ "$CHECK_EXISTING" != "null" ]]; then
  POLICY_ARN=$( echo ${CHECK_EXISTING} | jq -r '.Arn' )
  echo "Existing policy: $POLICY_ARN"
  echo "Skipping creation of new policy..."
else
  confirm "Really set this up?"
  POLICY_RESP=$(aws iam create-policy --path "$POLICY_PATH" --policy-name "$POLICY_NAME" --policy-document "$(cat ddns_iam_policy.json | sed 's/{YOUR_ZONEID_HERE}/'$HOSTED_ZONE_ID'/g')")
  POLICY_ARN=$( echo "$POLICY_RESP" | jq -r .Policy.Arn )
  echo "Policy created! ARN: ${POLICY_ARN}"
  GET_POLICY_OUTPUT=$(aws iam get-policy --policy-arn $( echo "$POLICY_RESP" | jq -r .Policy.Arn ))
  echo "get-policy: $GET_POLICY_OUTPUT"
fi


echo "Creating user: $IAM_USER_NAME"
IAM_USER_ARN=$( aws iam create-user --user-name $IAM_USER_NAME --query 'User.Arn' --output text || echo 'Error: Failed to create user... continuing.' >&2 )

echo "Attaching policy to IAM user"
aws iam attach-user-policy --user-name $IAM_USER_NAME --policy-arn ${POLICY_ARN} || echo "Error: Failed to attach policy... continuing."

echo "Creating access keys"
ACCESS_KEY_OUTPUT=$( aws iam create-access-key --user-name $IAM_USER_NAME --query 'AccessKey' | jq -r )

echo "Created keys: $ACCESSS_KEY_OUTPUT"
AAKI=$( echo "$ACCESS_KEY_OUTPUT" | jq -r '.AccessKeyId' )
ASAK=$( echo "$ACCESS_KEY_OUTPUT" | jq -r '.SecretAccessKey' )

PROFILE_NAME="ddns-$HOSTED_ZONE_NAME_SAFE"

aws configure --profile $PROFILE_NAME set aws_access_key_id ${AAKI}
aws configure --profile $PROFILE_NAME set aws_secret_access_key ${ASAK}

echo -e "add to cron or where-ever:\n  */3 * * * * /usr/bin/env bash -l -c 'cd $PWD && python3 dns_update.py --profile $PROFILE_NAME --zone $HOSTED_ZONE_ID --domain $HOSTED_ZONE_NAME --ttl 180 --record YOUR.SUB.DOMAIN'"

echo -e "\nDONE!"
echo "aws user $IAM_USER_NAME configured under profile $PROFILE_NAME."
