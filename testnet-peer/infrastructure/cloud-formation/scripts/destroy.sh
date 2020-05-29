#!/bin/bash

set -Exo pipefail

# Set CWD to the root of scripts directory
#
cd "$(dirname "${BASH_SOURCE[0]}")"

main() {
    local region=""
    local env_name=""

    # grab shell arguments
    #
    for arg in "$@"
    do
        case $arg in
            --lotus-git-sha=*)
            lotus_git_sha="${arg#*=}"
            shift
            ;;
            --ec2-key-name=*)
            ec2_key_name="${arg#*=}"
            shift
            ;;
            --env-name=*)
            env_name="${arg#*=}"
            shift
            ;;
            --region=*)
            region="${arg#*=}"
            shift
            ;;
            *)
            other_args+=("$1")
            shift # Remove generic argument from processing
            ;;
        esac
    done

    local main_stack_name=${env_name}
    local template_storage_stack_name=${env_name}-template-storage
    local scripts_stack_name=${env_name}-scripts
    local all_stacks=("${template_storage_stack_name}" "${scripts_stack_name}" "${main_stack_name}")
    local all_s3_buckets=("${template_storage_stack_name}" "${scripts_stack_name}")

    # Delete the S3 buckets used to store Cloud Formation templates and Filecoin
    # node provisioning scripts. Cloud Formation won't delete a stack which
    # provisioned an S3 bucket which is non-empty - so this must happen first.
    #
    for bucket in "${all_s3_buckets[@]}"
    do
            if aws s3 ls "s3://${bucket}" --region "${region}"; then
                    aws s3 rb "s3://${bucket}" --region "${region}" --force || true
            fi
    done

    # Delete all the stacks we've created.
    #
    for stack in "${all_stacks[@]}"
    do
        if aws cloudformation describe-stacks --stack-name "${stack}" --region "${region}"; then
            (>&2 echo "[destroy/main] destroying '${stack}' CloudFormation stack")
            aws cloudformation delete-stack --stack-name "${stack}" --region "${region}" || true
            aws cloudformation wait stack-delete-complete --stack-name "${stack}" --region "${region}"
        fi
    done

    echo "$(date):delete:${env_name}:success"
}

main "$@"; exit
