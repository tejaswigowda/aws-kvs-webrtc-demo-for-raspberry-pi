#!/bin/bash

sudo apt-get install -y jq

THING_TYPE=kvs_example_camera
IAM_ROLE=KVSCameraCertificateBasedIAMRole
IAM_POLICY=KVSCameraIAMPolicy
IOT_ROLE_ALIAS=KvsCameraIoTRoleAlias
IOT_POLICY=KvsCameraIoTPolicy

mkdir -p cmd-responses
mkdir -p certs

# prompt for thing name
echo -n "Enter a Name for your IoT Thing, followed by [ENTER]: "
read THING_NAME

echo "Using $THING_NAME as IoT Thing Name"
echo "$THING_NAME" >> thing-name
echo "$IOT_ROLE_ALIAS" >> role-alias

# create thing type and thing
if aws iot describe-thing-type --thing-type-name $THING_TYPE 2>&1 | grep -q 'ResourceNotFoundException'; then
  echo "Thing type $THING_TYPE does not exist; creating now..."
  aws iot create-thing-type --thing-type-name $THING_TYPE
fi

if aws iot describe-thing --thing-name $THING_NAME 2>&1 | grep -q 'ResourceNotFoundException'; then
  echo "Thing $THING_NAME does not exist; creating now..."
  aws iot create-thing --thing-name $THING_NAME --thing-type-name $THING_TYPE
fi

# create AWS_IOT_ROLE_ALIAS (IAM Role, IAM Policy, IoT Role Alias, IoT Policy)
# see https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/how-iot.html

if aws iam get-role --role-name $IAM_ROLE 2>&1 | grep -q 'NoSuchEntity'; then
  echo "IAM Role $IAM_ROLE does not exist; creating now..."
  aws iam create-role --role-name $IAM_ROLE \
    --assume-role-policy-document 'file://iam-policy-document.json' > ./cmd-responses/iam-role.json
else
  aws iam get-role --role-name $IAM_ROLE > ./cmd-responses/iam-role.json
fi

if aws iam get-role-policy --role-name $IAM_ROLE --policy-name $IAM_POLICY 2>&1 | grep -q 'NoSuchEntity'; then
  echo "IAM Role Policy $IAM_POLICY does not exist; creating now..."
  aws iam put-role-policy --role-name $IAM_ROLE \
    --policy-name $IAM_POLICY --policy-document 'file://iam-permission-document.json'
fi

if aws iot describe-role-alias --role-alias $IOT_ROLE_ALIAS 2>&1 | grep -q 'ResourceNotFoundException'; then
  echo "IoT Role Alias $IOT_ROLE_ALIAS does not exist; creating now..."
  aws iot create-role-alias --role-alias $IOT_ROLE_ALIAS \
    --role-arn $(jq --raw-output '.Role.Arn' ./cmd-responses/iam-role.json) \
    --credential-duration-seconds 3600 > ./cmd-responses/iot-role-alias.json
else
  aws iot describe-role-alias --role-alias $IOT_ROLE_ALIAS  > ./cmd-responses/iot-role-alias.json
fi

if aws iot get-policy --policy-name $IOT_POLICY 2>&1 | grep -q 'ResourceNotFoundException'; then

cat > iot-policy-document.json <<EOF
{
   "Version":"2012-10-17",
   "Statement":[
      {
	 "Effect":"Allow",
	 "Action":[
	    "iot:Connect"
	 ],
	 "Resource":"$(jq --raw-output '.roleAliasArn' ./cmd-responses/iot-role-alias.json)"
 },
      {
	 "Effect":"Allow",
	 "Action":[
	    "iot:AssumeRoleWithCertificate"
	 ],
	 "Resource":"$(jq --raw-output '.roleAliasArn' ./cmd-responses/iot-role-alias.json)"
 }
   ]
}
EOF

  aws iot create-policy --policy-name $IOT_POLICY \
    --policy-document 'file://iot-policy-document.json'
fi

# create keys and certificate
# certs to be saved in:
# ./certs/device.cert.pem
# ./certs/device.private.key
# ./certs/root-CA.crt

if [ ! -f "./certs/root-CA.crt" ]; then
  curl --silent 'https://www.amazontrust.com/repository/SFSRootCAG2.pem' \
    --output ./certs/root-CA.crt
fi

if [ ! -f "./certs/device.cert.pem" ]; then
  aws iot create-keys-and-certificate --set-as-active \
    --certificate-pem-outfile ./certs/device.cert.pem \
    --public-key-outfile ./certs/device.public.key \
    --private-key-outfile ./certs/device.private.key > ./cmd-responses/keys-and-certificate.json

  aws iot attach-policy --policy-name $IOT_POLICY \
    --target $(jq --raw-output '.certificateArn' ./cmd-responses/keys-and-certificate.json)

  aws iot attach-thing-principal --thing-name $THING_NAME \
    --principal $(jq --raw-output '.certificateArn' ./cmd-responses/keys-and-certificate.json)
fi

# get credential provider endpoint
if [ ! -f "credential-provider-endpoint" ]; then
  aws iot describe-endpoint --endpoint-type iot:CredentialProvider \
    --output text > ./credential-provider-endpoint
fi

IOT_GET_CREDENTIAL_ENDPOINT=`cat ./credential-provider-endpoint`
