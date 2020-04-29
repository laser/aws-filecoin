#!/usr/bin/env bash

# USAGE:
#
# Option 1: Build and run tests using specific lotus Git SHA:
#
# > ./test-storage-and-retrieval-local-dev-net.sh --lotus-git-sha=15b3e57634458af983082dcbb736140bba2abfdb
#
# Option 2: Build and run using binaries you've built previously (much faster)
#
# > cd $LOTUS_CHECKOUT_DIR && make clean deps debug lotus-shed fountain
# > ./test-storage-and-retrieval-local-dev-net.sh --copy-binaries-from-dir=$LOTUS_CHECKOUT_DIR
#

set -Exo pipefail

free_port() {
    python -c "import socket; s = socket.socket(); s.bind(('', 0)); print(s.getsockname()[1])"
}

genesis_daemon_port=$(free_port)
genesis_miner_port=$(free_port)
client_daemon_port=$(free_port)
go_filecoin_client_daemon_port=$(free_port)
tmux_session="interop"
tmux_window_go_filecoin_client_cli="g-clientcli"
tmux_window_go_filecoin_client_daemon="g-clientdaemon"
tmux_window_lotus_genesis_cli="l-minercli"
tmux_window_lotus_genesis_daemon="l-daemon"
tmux_window_lotus_genesis_faucet="l-faucet"
tmux_window_lotus_genesis_miner="l-miner"
tmux_window_lotus_client_cli="l-clientcli"
tmux_window_lotus_client_daemon="l-clientdaemon"
tmux_window_tmp_setup="setup"
genesis_miner_addr="t01000"
lotus_base_dir=$(mktemp -d -t "lotus-interopnet.XXXX")
go_filecoin_base_dir=$(mktemp -d -t "go-filecoin-interopnet.XXXX")
lotus_build_log_path=$(mktemp)
go_filecoin_build_log_path=$(mktemp)
deps=(printf paste jq python nc)
go_filecoin_git_sha=""
go_filecoin_copy_binaries_from_dir=""
lotus_git_sha=""
lotus_copy_binaries_from_dir=""
other_args=()

# ensure that script dependencies are met
#
for dep in ${deps[@]}; do
    if ! which "${dep}"; then
        (>&2 echo "please install ${dep} before running this script")
        exit 1
    fi
done

# grab shell arguments (see USAGE)
#
for arg in "$@"
do
    case $arg in
        --go-filecoin-git-sha=*)
        go_filecoin_git_sha="${arg#*=}"
        shift
        ;;
        --go-filecoin-copy-binaries-from-dir=*)
        go_filecoin_copy_binaries_from_dir="${arg#*=}"
        shift
        ;;
        --lotus-git-sha=*)
        lotus_git_sha="${arg#*=}"
        shift
        ;;
        --lotus-copy-binaries-from-dir=*)
        lotus_copy_binaries_from_dir="${arg#*=}"
        shift
        ;;
        *)
        other_args+=("$1")
        shift # Remove generic argument from processing
        ;;
    esac
done

if [[ -z "$lotus_git_sha" ]]; then
    if [[ -z "$lotus_copy_binaries_from_dir" ]]; then
        (>&2 echo "must provide either --lotus-git-sha or --lotus-copy-binaries-from-dir")
        exit 1
    fi
fi

if [[ -z "$go_filecoin_git_sha" ]]; then
    if [[ -z "$go_filecoin_copy_binaries_from_dir" ]]; then
        (>&2 echo "must provide either --go-filecoin-git-sha or --go-filecoin-copy-binaries-from-dir")
        exit 1
    fi
fi

# create some directories which we'll need later
#
mkdir -p "${lotus_base_dir}"
mkdir -p "${lotus_base_dir}/scripts"
mkdir -p "${lotus_base_dir}/bin"
mkdir -p "${go_filecoin_base_dir}"
mkdir -p "${go_filecoin_base_dir}"
mkdir -p "${go_filecoin_base_dir}/scripts"
mkdir -p "${go_filecoin_base_dir}/bin"

cat > "${lotus_base_dir}/scripts/env-genesis-lotus.bash" <<EOF
export RUST_LOG=info
export PATH=${lotus_base_dir}/bin:\$PATH
export LOTUS_PATH=${lotus_base_dir}/.genesis-lotus
export LOTUS_STORAGE_PATH=${lotus_base_dir}/.genesis-lotusstorage
export LOTUS_GENESIS_SECTORS=${lotus_base_dir}/.genesis-sectors
EOF

cat > "${go_filecoin_base_dir}/scripts/env-client-go-filecoin.bash" <<EOF
export RUST_LOG=info
export PATH=${go_filecoin_base_dir}/bin:\$PATH
export FIL_PATH=${go_filecoin_base_dir}/.client-go-filecoin
export FIL_SECTOR_PATH=${go_filecoin_base_dir}/.client-go-filecoin
EOF

cat > "${lotus_base_dir}/scripts/env-client-lotus.bash" <<EOF
export RUST_LOG=info
export PATH=${lotus_base_dir}/bin:\$PATH
export LOTUS_PATH=${lotus_base_dir}/.client-lotus
export LOTUS_STORAGE_PATH=${lotus_base_dir}/.client-lotusstorage
EOF

cat > "${lotus_base_dir}/scripts/build-lotus.bash" <<EOF
#!/usr/bin/env bash
set -xe

if [[ ! -z "${lotus_copy_binaries_from_dir}" ]]; then
    pushd ${lotus_copy_binaries_from_dir}
    cp lotus lotus-storage-miner lotus-shed lotus-seed fountain ${lotus_base_dir}/bin/
    popd
fi

if [[ ! -z "${lotus_git_sha}" ]]; then
    git clone https://github.com/filecoin-project/lotus.git "${lotus_base_dir}/build"
    pushd "${lotus_base_dir}/build" && git reset --hard "${lotus_git_sha}" && popd

    SCRIPTDIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    pushd \$SCRIPTDIR/../build
    pwd
    make clean deps debug lotus-shed fountain
    cp lotus lotus-storage-miner lotus-shed lotus-seed fountain ${lotus_base_dir}/bin/
    popd
fi
EOF

cat > "${go_filecoin_base_dir}/scripts/build-go-filecoin.bash" <<EOF
#!/usr/bin/env bash
set -xe

if [[ ! -z "${go_filecoin_copy_binaries_from_dir}" ]]; then
    pushd ${go_filecoin_copy_binaries_from_dir}
    cp go-filecoin ${go_filecoin_base_dir}/bin/
    popd
fi

if [[ ! -z "${go_filecoin_git_sha}" ]]; then
    git clone https://github.com/filecoin-project/go-filecoin.git "${go_filecoin_base_dir}/build"
    pushd "${go_filecoin_base_dir}/build" && git reset --hard "${go_filecoin_git_sha}"
    git submodule update --init --recursive
    popd

    SCRIPTDIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    pushd \$SCRIPTDIR/../build
    pwd
    make deps all
    cp go-filecoin ${go_filecoin_base_dir}/bin/
    popd
fi
EOF

cat > "${lotus_base_dir}/scripts/create_genesis_block-lotus.bash" <<EOF
#!/usr/bin/env bash
set -xe

HOME="${lotus_base_dir}" lotus-seed pre-seal --sector-size 2048 --num-sectors 2 --miner-addr "${genesis_miner_addr}"
lotus-seed genesis new "${lotus_base_dir}/localnet.json"
lotus-seed genesis add-miner "${lotus_base_dir}/localnet.json" "\$LOTUS_GENESIS_SECTORS/pre-seal-${genesis_miner_addr}.json"
jq '.Accounts[0].Balance = "1234567890123456789"' "${lotus_base_dir}/localnet.json" > "${lotus_base_dir}/localnet.json.tmp" && mv "${lotus_base_dir}/localnet.json.tmp" "${lotus_base_dir}/localnet.json"
EOF

cat > "${lotus_base_dir}/scripts/create_miner-lotus.bash" <<EOF
#!/usr/bin/env bash
set -xe

lotus wallet import "\$LOTUS_GENESIS_SECTORS/pre-seal-${genesis_miner_addr}.key"
lotus-storage-miner init --genesis-miner --actor="${genesis_miner_addr}" --sector-size=2048 --pre-sealed-sectors=\$LOTUS_GENESIS_SECTORS --pre-sealed-metadata="\$LOTUS_GENESIS_SECTORS/pre-seal-${genesis_miner_addr}.json" --nosync
EOF

cat > "${lotus_base_dir}/scripts/start_faucet-lotus.bash" <<EOF
#!/usr/bin/env bash
set -xe

wallet=\$(lotus wallet list)
while [ "\$wallet" = "" ]; do
  sleep 5
  wallet=\$(lotus wallet list)
done

fountain run --from=\$wallet
EOF

cat > "${lotus_base_dir}/scripts/hit_faucet-lotus.bash" <<EOF
#!/usr/bin/env bash
set -xe

faucet="http://127.0.0.1:7777"
owner=\$(lotus wallet new bls)
msg_cid=\$(curl -D - -XPOST -F "sectorSize=2048" -F "address=\$owner" \$faucet/send | tail -1)
lotus state wait-msg \$msg_cid
EOF

cat > "${lotus_base_dir}/scripts/propose_storage_deal-lotus.bash" <<EOF
#!/usr/bin/env bash
set -xe

cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 900 | head -n 1 > "${lotus_base_dir}/original-data.txt"
lotus client import "${lotus_base_dir}/original-data.txt" > "${lotus_base_dir}/original-data.cid"
lotus client deal \$(cat ${lotus_base_dir}/original-data.cid) t01000 0.000000000001 5
EOF

cat > "${lotus_base_dir}/scripts/retrieve_stored_file-lotus.bash" <<EOF
#!/usr/bin/env bash
set -xe

lotus client retrieve \$(cat "${lotus_base_dir}/original-data.cid") "${lotus_base_dir}/retrieved-data.txt"

set +xe

paste <(printf "%-50s\n\n" "${lotus_base_dir}/original-data.txt") <(printf "%-50s\n\n" "${lotus_base_dir}/retrieved-data.txt")
paste <(printf %s "\$(cat "${lotus_base_dir}/original-data.txt" | fold -s -w 50)") <(printf %s "\$(cat "${lotus_base_dir}/retrieved-data.txt" | fold -s -w 50)")

diff "${lotus_base_dir}/original-data.txt" "${lotus_base_dir}/retrieved-data.txt" && echo "retrieved file matches stored file"
EOF

chmod +x "${lotus_base_dir}/scripts/build-lotus.bash"
chmod +x "${lotus_base_dir}/scripts/build-go-filecoin.bash"
chmod +x "${lotus_base_dir}/scripts/create_genesis_block-lotus.bash"
chmod +x "${lotus_base_dir}/scripts/create_miner-lotus.bash"
chmod +x "${lotus_base_dir}/scripts/hit_faucet-lotus.bash"
chmod +x "${lotus_base_dir}/scripts/propose_storage_deal-lotus.bash"
chmod +x "${lotus_base_dir}/scripts/retrieve_stored_file-lotus.bash"
chmod +x "${lotus_base_dir}/scripts/start_faucet-lotus.bash"

# build go-filecoin
#
bash "${go_filecoin_base_dir}/scripts/build-go-filecoin.bash" 2>&1 | tee -a "${go_filecoin_build_log_path}"

if [ $? -eq 0 ]
then
  echo "go-filecoin built successfully"
else
  echo "failed to build: check ${go_filecoin_build_log_path} for more details" >&2
  exit 1
fi

# build lotus binaries
#
bash "${lotus_base_dir}/scripts/build-lotus.bash" 2>&1 | tee -a "${lotus_build_log_path}"

if [ $? -eq 0 ]
then
  echo "lotus built successfully"
else
  echo "failed to build: check ${lotus_build_log_path} for more details" >&2
  exit 1
fi

# configure tmux session
#
tmux new-session -d -s "$tmux_session" -n "$tmux_window_tmp_setup"
tmux set-environment -t "$tmux_session" base_dir "$lotus_base_dir"
tmux new-window -t "$tmux_session" -n "$tmux_window_lotus_genesis_daemon"
tmux new-window -t "$tmux_session" -n "$tmux_window_lotus_genesis_faucet"
tmux new-window -t "$tmux_session" -n "$tmux_window_lotus_genesis_miner"
tmux new-window -t "$tmux_session" -n "$tmux_window_lotus_genesis_cli"
tmux new-window -t "$tmux_session" -n "$tmux_window_lotus_client_cli"
tmux new-window -t "$tmux_session" -n "$tmux_window_lotus_client_daemon"
tmux new-window -t "$tmux_session" -n "$tmux_window_go_filecoin_client_cli"
tmux new-window -t "$tmux_session" -n "$tmux_window_go_filecoin_client_daemon"
tmux kill-window -t "$tmux_session":"$tmux_window_tmp_setup"

# ensure tmux sessions have identical environments
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_daemon}" "source ${lotus_base_dir}/scripts/env-genesis-lotus.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_miner}" "source ${lotus_base_dir}/scripts/env-genesis-lotus.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_faucet}" "source ${lotus_base_dir}/scripts/env-genesis-lotus.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_cli}" "source ${lotus_base_dir}/scripts/env-genesis-lotus.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_daemon}" "source ${lotus_base_dir}/scripts/env-client-lotus.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "source ${lotus_base_dir}/scripts/env-client-lotus.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_daemon}" "source ${go_filecoin_base_dir}/scripts/env-client-go-filecoin.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_cli}" "source ${go_filecoin_base_dir}/scripts/env-client-go-filecoin.bash" C-m

# create genesis block and run genesis daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_daemon}" "${lotus_base_dir}/scripts/create_genesis_block-lotus.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_daemon}" "lotus daemon --lotus-make-genesis=${lotus_base_dir}/dev.gen --genesis-template=${lotus_base_dir}/localnet.json --bootstrap=false --api=${genesis_daemon_port} 2>&1 | tee -a ${lotus_base_dir}/daemon.log" C-m

# dump multiaddr for networking client and miner daemons
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_cli}" "while ! nc -z 127.0.0.1 ${genesis_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_cli}" "lotus net listen | grep 127 > ${lotus_base_dir}/.genesis-multiaddr" C-m

# start genesis miner
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_miner}" "while ! nc -z 127.0.0.1 ${genesis_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_miner}" "${lotus_base_dir}/scripts/create_miner-lotus.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_miner}" "lotus-storage-miner run --api=${genesis_miner_port} --nosync 2>&1 | tee -a ${lotus_base_dir}/miner.log" C-m

# start faucet
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_faucet}" "while ! nc -z 127.0.0.1 ${genesis_miner_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_genesis_faucet}" "${lotus_base_dir}/scripts/start_faucet-lotus.bash" C-m

# start lotus client daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_daemon}" "while [ ! -f ${lotus_base_dir}/dev.gen ]; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_daemon}" "lotus daemon --genesis=${lotus_base_dir}/dev.gen --bootstrap=false --api=${client_daemon_port} 2>&1 | tee -a ${lotus_base_dir}/client.log" C-m

# start go-filecoin client daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_daemon}" "while [ ! -f ${lotus_base_dir}/dev.gen ]; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_daemon}" "go-filecoin init --genesisfile=${lotus_base_dir}/dev.gen 2>&1 | tee -a ${go_filecoin_base_dir}/client.log" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_daemon}" "go-filecoin daemon --swarmlisten=/ip4/127.0.0.1/tcp/${go_filecoin_client_daemon_port} --block-time=2s 2>&1 | tee -a ${go_filecoin_base_dir}/client.log" C-m

# go-filecoin client networks nodes
#
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_cli}" "while ! nc -z 127.0.0.1 ${go_filecoin_client_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_cli}" "while [ ! -f ${lotus_base_dir}/.genesis-multiaddr ]; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_cli}" "go-filecoin swarm connect \$(cat ${lotus_base_dir}/.genesis-multiaddr)" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_go_filecoin_client_cli}" "go-filecoin drand configure drand-test3.nikkolasg.xyz:5003" C-m

# lotus client hits the faucet (after networking two nodes)
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "while ! nc -z 127.0.0.1 ${client_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "while [ ! -f ${lotus_base_dir}/.genesis-multiaddr ]; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "lotus net connect \$(cat ${lotus_base_dir}/.genesis-multiaddr)" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "while ! nc -z 127.0.0.1 7777 </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "${lotus_base_dir}/scripts/hit_faucet-lotus.bash" C-m

# propose a lotus-to-lotus storage deal
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "${lotus_base_dir}/scripts/propose_storage_deal-lotus.bash" C-m

# retrieve data (from lotus) and be overjoyed
#
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "while ! lotus client list-deals | grep StorageDealActive; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_lotus_client_cli}" "${lotus_base_dir}/scripts/retrieve_stored_file-lotus.bash" C-m

# select a window and view your handywork
#
tmux select-window -t "${tmux_session}:${tmux_window_go_filecoin_client_daemon}"
tmux attach-session -t "${tmux_session}"
