#!/bin/bash

set -Exo pipefail

# Set CWD to the root of scripts directory
#
cd "$(dirname "${BASH_SOURCE[0]}")"

main() {
  local region=$1
  local env_name=$2
  local ec2_key_name=$3
  local bucket_stack_name="${env_name}-template-storage"

  # Create an S3 stack which holds our CloudFormation templates and an ECR stack
  # which will hold our application's Docker images
  #
  if ! aws cloudformation describe-stacks --stack-name "${bucket_stack_name}"; then
    (>&2 echo '[deploy/main] creating CloudFormation stack for templates')

    aws cloudformation deploy \
      --region "${region}" \
      --stack-name "${bucket_stack_name}" \
      --template-file ../templates/template-storage.yml \
      --parameter-overrides BucketName="${env_name}"
  fi

  # Ensure that S3 has the most recent revision of our CloudFormation templates
  #
  (>&2 echo '[deploy/main] synchronizing local template with S3')

  aws s3 sync \
    --region "${region}" \
    --acl public-read \
    --delete \
    ../templates/ "s3://${env_name}/infrastructure/cloud-formation/templates/"

  # Create the stack
  #
  (>&2 echo '[deploy/main] creating main CloudFormation stack')

  aws cloudformation deploy \
    --region "${region}" \
    --stack-name "${env_name}" \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM \
    --template-file ../templates/master.yml \
    --parameter-overrides \
    S3TemplateKeyPrefix="https://s3.amazonaws.com/${env_name}/infrastructure/cloud-formation/templates/" \
    EC2KeyName="${ec2_key_name}"

  echo "$(date):create:${env_name}:success"
}

main "$@"; exit





