#!/usr/bin/env bash

set -Exo pipefail

region=$1
env_name=$2
kvdb_bucket=$3
kvdb_prefix=$4


IFS=$'\n'
ip_addresses=( $(aws cloudformation describe-stacks --stack-name "${env_name}" --region "${region}" | jq -r '.Stacks[].Outputs[].OutputValue' | tr ' ' '\n') )

root_dir="/tmp/${kvdb_prefix}-$(date +%s)"
mkdir -p ${root_dir}

for ip_addr in ${ip_addresses[@]}; do
    miner_id=$(curl -s "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_${ip_addr}")

    if [[ "${miner_id}" = "Not Found" ]]; then
        miner_dir="${root_dir}/did-not-join-cluster-${ip_addr}"
        mkdir -p ${miner_dir}

        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${ip_addr}:/var/log/daemon.log" "${miner_dir}/daemon.log"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${ip_addr}:/var/log/miner.log" "${miner_dir}/miner.log"
    else
        miner_dir="${root_dir}/${miner_id}"
        mkdir -p ${miner_dir}

        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${ip_addr}:/var/log/daemon.log" "${miner_dir}/daemon.log"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${ip_addr}:/var/log/miner.log" "${miner_dir}/miner.log"
    fi
done

echo "done: ${root_dir}"
