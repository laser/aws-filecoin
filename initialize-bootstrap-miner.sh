#!/usr/bin/env bash

set -Exo pipefail

free_port() {
  python -c "import socket; s = socket.socket(); s.bind(('', 0)); print(s.getsockname()[1])"
}

lotus_git_sha=""
copy_binaries_from_dir=""
other_args=()

# Loop through arguments and process them
#
for arg in "$@"
do
    case $arg in
        --lotus-git-sha=*)
        lotus_git_sha="${arg#*=}"
        shift
        ;;
        --copy-binaries-from-dir=*)
        copy_binaries_from_dir="${arg#*=}"
        shift
        ;;
        *)
        other_args+=("$1")
        shift # Remove generic argument from processing
        ;;
    esac
done

if [[ -z "$lotus_git_sha" ]]; then
    if [[ -z "$copy_binaries_from_dir" ]]; then
        (>&2 echo "must provide either --lotus-git-sha or --copy-binaries-from-dir")
        exit 1
    fi
fi

bootstrap_daemon_port=$(free_port)
bootstrap_miner_port=$(free_port)
client_daemon_port=$(free_port)
tmux_session="lotus-interop"
tmux_window_client_daemon="clientdaemon"
tmux_window_client_cli="clientcli"
tmux_window_bootstrap_daemon="daemon"
tmux_window_bootstrap_faucet="faucet"
tmux_window_bootstrap_miner="miner"
tmux_window_bootstrap_cli="minercli"
tmux_window_tmp_setup="setup"
genesis_miner_addr="t01000"
base_dir=$(mktemp -d -t "lotus-interopnet.XXXX")

# create some directories which we'll need later
#
mkdir -p "${base_dir}"
mkdir -p "${base_dir}/scripts"
mkdir -p "${base_dir}/bin"

cat > "${base_dir}/scripts/env-bootstrap.fish" <<EOF
set -x PATH ${base_dir}/bin \$PATH
set -x LOTUS_PATH ${base_dir}/.bootstrap-lotus
set -x LOTUS_STORAGE_PATH ${base_dir}/.bootstrap-lotusstorage
set -x LOTUS_GENESIS_SECTORS ${base_dir}/.genesis-sectors
EOF

cat > "${base_dir}/scripts/env-bootstrap.bash" <<EOF
export PATH=${base_dir}/bin:\$PATH
export LOTUS_PATH=${base_dir}/.bootstrap-lotus
export LOTUS_STORAGE_PATH=${base_dir}/.bootstrap-lotusstorage
export LOTUS_GENESIS_SECTORS=${base_dir}/.genesis-sectors
EOF

cat > "${base_dir}/scripts/env-client.fish" <<EOF
set -x PATH ${base_dir}/bin \$PATH
set -x LOTUS_PATH ${base_dir}/.client-lotus
set -x LOTUS_STORAGE_PATH ${base_dir}/.client-lotusstorage
EOF

cat > "${base_dir}/scripts/env-client.bash" <<EOF
export PATH=${base_dir}/bin:\$PATH
export LOTUS_PATH=${base_dir}/.client-lotus
export LOTUS_STORAGE_PATH=${base_dir}/.client-lotusstorage
EOF

cat > "${base_dir}/scripts/build.bash" <<EOF
#!/usr/bin/env bash
set -x

if [[ ! -z "${copy_binaries_from_dir}" ]]; then
    pushd ${copy_binaries_from_dir}
    cp lotus lotus-storage-miner lotus-shed lotus-seed fountain ${base_dir}/bin/
    popd
fi

if [[ ! -z "${lotus_git_sha}" ]]; then
    git clone https://github.com/filecoin-project/lotus.git "${base_dir}/build"
    pushd "${base_dir}/build" && git reset --hard "${lotus_git_sha}" && popd

    SCRIPTDIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    pushd \$SCRIPTDIR/../build
    pwd
    make clean deps debug lotus-shed fountain
    cp lotus lotus-storage-miner lotus-shed lotus-seed fountain ../bin/
    popd
fi
EOF

cat > "${base_dir}/scripts/create_genesis_block.bash" <<EOF
#!/usr/bin/env bash
set -x

HOME="${base_dir}" lotus-seed pre-seal --sector-size 2048 --num-sectors 2 --miner-addr "${genesis_miner_addr}"
lotus-seed genesis new "${base_dir}/localnet.json"
lotus-seed genesis add-miner "${base_dir}/localnet.json" "\$LOTUS_GENESIS_SECTORS/pre-seal-${genesis_miner_addr}.json"
jq '.Accounts[0].Balance = "1234567890123456789"' "${base_dir}/localnet.json" > "${base_dir}/localnet.json.tmp" && mv "${base_dir}/localnet.json.tmp" "${base_dir}/localnet.json"
EOF

cat > "${base_dir}/scripts/create_miner.bash" <<EOF
#!/usr/bin/env bash
set -x

lotus wallet import "\$LOTUS_GENESIS_SECTORS/pre-seal-${genesis_miner_addr}.key"
lotus-storage-miner init --genesis-miner --actor="${genesis_miner_addr}" --sector-size=2048 --pre-sealed-sectors=\$LOTUS_GENESIS_SECTORS --pre-sealed-metadata="\$LOTUS_GENESIS_SECTORS/pre-seal-${genesis_miner_addr}.json" --nosync
EOF

cat > "${base_dir}/scripts/start_faucet.bash" <<EOF
#!/usr/bin/env bash
set -x

wallet=\$(lotus wallet list)
while [ "\$wallet" = "" ]; do
  sleep 5
  wallet=\$(lotus wallet list)
done

fountain run --from=\$wallet
EOF

cat > "${base_dir}/scripts/hit_faucet.bash" <<EOF
#!/usr/bin/env bash
set -x

faucet="http://127.0.0.1:7777"
owner=\$(lotus wallet new bls)
msg_cid=\$(curl -D - -XPOST -F "sectorSize=2048" -F "address=\$owner" \$faucet/send | tail -1)
lotus state wait-msg \$msg_cid
EOF

chmod +x "${base_dir}/scripts/build.bash"
chmod +x "${base_dir}/scripts/create_genesis_block.bash"
chmod +x "${base_dir}/scripts/create_miner.bash"
chmod +x "${base_dir}/scripts/start_faucet.bash"
chmod +x "${base_dir}/scripts/hit_faucet.bash"

# build various lotus binaries
#
bash "${base_dir}/scripts/build.bash"

# configure tmux session
#
tmux new-session -d -s "$tmux_session" -n "$tmux_window_tmp_setup"
tmux set-environment -t "$tmux_session" base_dir "$base_dir"
tmux new-window -t "$tmux_session" -n "$tmux_window_bootstrap_daemon"
tmux new-window -t "$tmux_session" -n "$tmux_window_bootstrap_faucet"
tmux new-window -t "$tmux_session" -n "$tmux_window_bootstrap_miner"
tmux new-window -t "$tmux_session" -n "$tmux_window_bootstrap_cli"
tmux new-window -t "$tmux_session" -n "$tmux_window_client_cli"
tmux new-window -t "$tmux_session" -n "$tmux_window_client_daemon"
tmux kill-window -t "$tmux_session":"$tmux_window_tmp_setup"

case $(basename $SHELL) in
  fish ) shell=fish ;;
  *    ) shell=bash ;;
esac

# ensure tmux sessions have identical environments
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_daemon}" "source ${base_dir}/scripts/env-bootstrap.$shell" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}" "source ${base_dir}/scripts/env-bootstrap.$shell" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_faucet}" "source ${base_dir}/scripts/env-bootstrap.$shell" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_cli}" "source ${base_dir}/scripts/env-bootstrap.$shell" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_client_daemon}" "source ${base_dir}/scripts/env-client.$shell" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_client_cli}" "source ${base_dir}/scripts/env-client.$shell" C-m

# create genesis block and run bootstrap daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_daemon}" "${base_dir}/scripts/create_genesis_block.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_daemon}" "lotus daemon --lotus-make-genesis=${base_dir}/dev.gen --genesis-template=${base_dir}/localnet.json --bootstrap=false --api=${bootstrap_daemon_port} 2>&1 | tee -a ${base_dir}/daemon.log" C-m

# dump multiaddr for networking client and miner daemons
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_cli}" "while ! nc -z 127.0.0.1 ${bootstrap_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_cli}" "lotus net listen | grep 127 > ${base_dir}/.bootstrap-multiaddr" C-m

# start bootstrap miner
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}" "while ! nc -z 127.0.0.1 ${bootstrap_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}" "${base_dir}/scripts/create_miner.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}" "lotus-storage-miner run --api=${bootstrap_miner_port} --nosync 2>&1 | tee -a ${base_dir}/miner.log" C-m

# start bootstrap faucet
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_faucet}" "while ! nc -z 127.0.0.1 ${bootstrap_miner_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_faucet}" "${base_dir}/scripts/start_faucet.bash" C-m

# start client daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_client_daemon}" "while [ ! -f ${base_dir}/dev.gen ]; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_client_daemon}" "lotus daemon --genesis=${base_dir}/dev.gen --bootstrap=false --api=${client_daemon_port} 2>&1 | tee -a ${base_dir}/client.log" C-m

# hit the faucet (after networking two nodes)
#
tmux send-keys -t "${tmux_session}:${tmux_window_client_cli}" "while ! nc -z 127.0.0.1 ${client_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_client_cli}" "while [ ! -f ${base_dir}/.bootstrap-multiaddr ]; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_client_cli}" "lotus net connect \$(cat ${base_dir}/.bootstrap-multiaddr)" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_client_cli}" "while ! nc -z 127.0.0.1 7777 </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_client_cli}" "${base_dir}/scripts/hit_faucet.bash" C-m

# select a window and view your handywork
#
tmux select-window -t "${tmux_session}:${tmux_window_client_cli}"
tmux attach-session -t "${tmux_session}"
