#!/bin/bash

# Exit on error
set -e

# Variables
ROLE_NAME="EC2SSMRole"
INSTANCE_PROFILE_NAME="EC2SSMInstanceProfile"
INSTANCE_NAME="SSM-CLI-Demo"
INSTANCE_TYPE="t2.micro"
REGION="ap-southeast-2"  # change this to your preferred region

# Get latest Amazon Linux 2 AMI
echo "Getting latest Amazon Linux 2 AMI..."
AMI_ID=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 \
  --query 'Parameters[0].Value' --output text --region "$REGION")

echo "Using AMI: $AMI_ID"

# Create IAM Role trust policy
echo "Creating IAM trust policy..."
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create IAM Role and attach policy
echo "Creating IAM Role..."
aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document file://trust-policy.json

echo "Attaching AmazonSSMManagedInstanceCore policy..."
aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Create Instance Profile and attach Role
echo "Creating instance profile..."
aws iam create-instance-profile \
  --instance-profile-name $INSTANCE_PROFILE_NAME

echo "Adding role to instance profile..."
aws iam add-role-to-instance-profile \
  --instance-profile-name $INSTANCE_PROFILE_NAME \
  --role-name $ROLE_NAME

# Wait for instance profile propagation
echo "Waiting for IAM propagation..."
sleep 20

# Launch EC2 instance
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type $INSTANCE_TYPE \
  --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --region "$REGION" \
  --query 'Instances[0].InstanceId' --output text)

echo "Instance launched: $INSTANCE_ID"
echo "Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region "$REGION"

# Wait for SSM registration
echo "Waiting for SSM to register the instance..."
sleep 60

# Confirm instance is SSM-managed
echo "Checking instance SSM status..."
aws ssm describe-instance-information --region "$REGION" \
  --query "InstanceInformationList[?InstanceId=='$INSTANCE_ID'].PingStatus" --output text

# Run patch scan
echo "Running patch compliance scan..."
COMMAND_ID=$(aws ssm send-command \
  --document-name "AWS-RunPatchBaseline" \
  --targets "Key=instanceIds,Values=$INSTANCE_ID" \
  --parameters 'Operation=Scan' \
  --region "$REGION" \
  --query 'Command.CommandId' --output text)

# Wait a bit for the command to complete
echo "Waiting for command to complete..."
sleep 20

# Fetch command output
echo "Fetching scan output..."
aws ssm get-command-invocation \
  --command-id $COMMAND_ID \
  --instance-id $INSTANCE_ID \
  --region "$REGION" \
  --query 'StandardOutputContent' \
  --output text
