#!/bin/bash

set -Exo pipefail

# Set CWD to the root of scripts directory
#
cd "$(dirname "${BASH_SOURCE[0]}")"

main() {
  local region=$1
  local env_name=$2
  local main_stack_name=${env_name}
  local template_storage_stack_name=${env_name}-template-storage
  local all_stacks=("${template_storage_stack_name}" "${main_stack_name}")

  ###############################################################################
  # Delete the S3 bucket used to store Cloud Formation templates. Cloud Formation
  # won't delete a stack which provisioned an S3 bucket which is non-empty - so
  # this must happen first.
  #

  if aws s3 ls "s3://${env_name}" --region "${region}"; then
      aws s3 rb "s3://${env_name}" --region "${region}" --force || true
  fi

  ###############################################################################
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
