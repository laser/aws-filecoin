#!/bin/bash

set -Exo pipefail

# Set CWD to the root of scripts directory
#
cd "$(dirname "${BASH_SOURCE[0]}")"

main() {
    local region=$1
    local env_name=$2
    local ec2_key_name=$3
    local lotus_git_sha=$4
    local config_bucket_name=$5
    local config_key_prefix=$6
    local templates_stack_name="${env_name}-template-storage"
    local scripts_stack_name="${env_name}-scripts"

    # Create an S3 stack which holds our CloudFormation templates
    #
    if ! aws cloudformation describe-stacks --stack-name "${templates_stack_name}"; then
        (>&2 echo '[deploy/main] creating CloudFormation stack for templates')

        aws cloudformation deploy \
            --region "${region}" \
            --stack-name "${templates_stack_name}" \
            --template-file ../templates/s3-bucket.yml \
            --parameter-overrides BucketName="${templates_stack_name}" || exit 1
    fi

    # Create an S3 stack which holds our scripts
    #
    if ! aws cloudformation describe-stacks --stack-name "${scripts_stack_name}"; then
        (>&2 echo '[deploy/main] creating CloudFormation stack for scripts')

        aws cloudformation deploy \
            --region "${region}" \
            --stack-name "${scripts_stack_name}" \
            --template-file ../templates/s3-bucket.yml \
            --parameter-overrides BucketName="${scripts_stack_name}" || exit 1
    fi

    # Ensure that S3 has the most recent revision of our CloudFormation templates
    #
    (>&2 echo '[deploy/main] synchronizing local assets with S3')

    aws s3 sync \
        --region "${region}" \
        --acl public-read \
        --delete \
        ../templates/ "s3://${templates_stack_name}/infrastructure/cloud-formation/templates/" || exit 1

    # Ensure that S3 has the most recent revision of our node configuring-scripts
    #
    aws s3 sync \
        --region "${region}" \
        --acl public-read \
        --delete \
        ../../../scripts/ "s3://${scripts_stack_name}/scripts" || exit 1

    # Create (or update) the stack
    #
    aws cloudformation deploy \
        --region "${region}" \
        --stack-name "${env_name}" \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM \
        --template-file ../templates/master.yml \
        --parameter-overrides \
        TemplateS3Prefix="s3://${templates_stack_name}/infrastructure/cloud-formation/templates/" \
        TemplateURLPrefix="https://${templates_stack_name}.s3.amazonaws.com/infrastructure/cloud-formation/templates/" \
        GenesisMinerScriptURL="https://${scripts_stack_name}.s3.amazonaws.com/scripts/genesis-node.sh" \
        PeeredMinerScriptURL="https://${scripts_stack_name}.s3.amazonaws.com/scripts/peer-mining-node.sh" \
        LotusGitSHA="${lotus_git_sha}" \
        ConfigKeyPrefix="${config_key_prefix}" \
        ConfigBucketName="${config_bucket_name}" \
        LotusGitSHA="${lotus_git_sha}" \
        EC2KeyName="${ec2_key_name}" || exit 1

    aws cloudformation describe-stacks --stack-name "${env_name}" --region "${region}" | jq '.Stacks[].Outputs'
}

main "$@"; exit





