#!/usr/bin/env bash

set -Exo pipefail

free_port() {
    python -c "import socket; s = socket.socket(); s.bind(('', 0)); print(s.getsockname()[1])"
}

genesis_daemon_multiaddr=""
genesis_miner_multiaddr=""
faucet_url=""
genesis_block_url=""
daemon_port=$(free_port)
storageminer_port=$(free_port)
tmux_session="lotus"
tmux_window_daemon="daemon"
tmux_window_miner="miner"
tmux_window_cli="cli"
tmux_window_poller="poller"
tmux_window_tmp_setup="setup"
base_dir=$(mktemp -d -t "lotus-interopnet.XXXX")
deps=(printf paste jq python nc)
lotus_git_sha=""
copy_binaries_from_dir=""
other_args=()
kvdb_prefix=""
kvdb_bucket=""

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
        --kvdb-prefix=*)
        kvdb_prefix="${arg#*=}"
        shift
        ;;
        --kvdb-bucket=*)
        kvdb_bucket="${arg#*=}"
        shift
        ;;
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

# ensure that script dependencies are met
#
for dep in ${deps[@]}; do
    if ! which "${dep}"; then
        (>&2 echo "please install ${dep} before running this script")
        exit 1
    fi
done

# wait for correct values to show up in kvdb
#
end=$(( $(date +%s) + ((60 * 10)) )) # 10 minutes
url="https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_genesis_block_url"
while [[ "$(curl -sL -w "%{http_code}\\n" ${url} -o /dev/null)" != "200" ]]; do
    if [[ ! $(date +%s) -lt ${end} ]]; then
        (>&2 echo "timed out waiting for genesis block to become available (${url})")
        exit 1
    fi

    (>&2 echo "genesis block (${url}) not yet available - sleeping 5s")
    sleep 5
done

# download all genesis info from kvdb
#
genesis_daemon_multiaddr=$(curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_genesis_daemon_multiaddr")
genesis_miner_multiaddr=$(curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_genesis_miner_multiaddr")
faucet_url=$(curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_faucet_url")
genesis_block_url=$(curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_genesis_block_url")

# create some directories which we'll need later
#
mkdir -p "${base_dir}"
mkdir -p "${base_dir}/scripts"
mkdir -p "${base_dir}/bin"

cat > "${base_dir}/scripts/env-bootstrap.bash" <<EOF
export RUST_LOG=info
export PATH=${base_dir}/bin:\$PATH
export LOTUS_PATH=${base_dir}/.bootstrap-lotus
export LOTUS_STORAGE_PATH=${base_dir}/.bootstrap-lotusstorage
export LOTUS_GENESIS_SECTORS=${base_dir}/.genesis-sectors
EOF

cat > "${base_dir}/scripts/build.bash" <<EOF
#!/usr/bin/env bash
set -x

if [[ ! -z "${copy_binaries_from_dir}" ]]; then
    pushd ${copy_binaries_from_dir}
    cp lotus ${base_dir}/bin/
    popd
fi

if [[ ! -z "${lotus_git_sha}" ]]; then
    git clone https://github.com/filecoin-project/lotus.git "${base_dir}/build"
    pushd "${base_dir}/build" && git reset --hard "${lotus_git_sha}" && popd

    SCRIPTDIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    pushd \$SCRIPTDIR/../build
    pwd
    make clean deps debug
    cp lotus ${base_dir}/bin/
    popd
fi
EOF

cat > "${base_dir}/scripts/hit_faucet.bash" <<EOF
#!/usr/bin/env bash
set -x

owner=\$(lotus wallet new bls)
msg_cid=\$(curl -D - -XPOST -F "sectorSize=2048" -F "address=\$owner" ${faucet_url}/send | tail -1)

lotus state wait-msg \$msg_cid
EOF

cat > "${base_dir}/scripts/connect_to_network.bash" <<EOF
#!/usr/bin/env bash
set -x

lotus net connect ${genesis_daemon_multiaddr}
lotus net connect ${genesis_miner_multiaddr}

curl https://kvdb.io/${kvdb_bucket}/ | grep "${kvdb_prefix}_t" | xargs -I % curl -s https://kvdb.io/${kvdb_bucket}/% -w '\n' | xargs -I % lotus net connect %

lotus net peers
EOF

cat > "${base_dir}/scripts/propose_deals.bash" <<EOF
#!/usr/bin/env bash
set -x

cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 1016 | head -n 1 > ${base_dir}/original-data.txt
original_data_cid=\$(lotus client import ${base_dir}/original-data.txt)

miners=\$(lotus state list-miners)

SAVEIFS=\$IFS   # Save current IFS
IFS=\$'\n'      # Change IFS to new line
miners=(\$(lotus state list-miners))
IFS=\$SAVEIFS   # Restore IFS

for (( i=0; i<\${#miners[@]}; i++ ))
do
    lotus client deal "\${original_data_cid}" \${miners[\$i]} 0.000000000001 5
done

EOF

chmod +x "${base_dir}/scripts/build.bash"
chmod +x "${base_dir}/scripts/connect_to_network.bash"
chmod +x "${base_dir}/scripts/hit_faucet.bash"
chmod +x "${base_dir}/scripts/propose_deals.bash"

# build various lotus binaries
#
bash "${base_dir}/scripts/build.bash"

# configure tmux session
#
tmux new-session -d -s "$tmux_session" -n "$tmux_window_tmp_setup"
tmux set-environment -t "$tmux_session" base_dir "$base_dir"
tmux new-window -t "$tmux_session" -n "$tmux_window_daemon"
tmux new-window -t "$tmux_session" -n "$tmux_window_cli"
tmux new-window -t "$tmux_session" -n "$tmux_window_poller"
tmux kill-window -t "$tmux_session":"$tmux_window_tmp_setup"

# ensure tmux sessions have identical environments
#
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_poller}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m

# download genesis block and run daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "lotus daemon --genesis=<(curl ${genesis_block_url}) --bootstrap=false --api=${daemon_port} 2>&1 | tee -a ${base_dir}/daemon.log" C-m

# connect to all nodes and miners in network
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "while ! nc -z 127.0.0.1 ${daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "${base_dir}/scripts/connect_to_network.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus sync wait" C-m

# launch poller
#
tmux send-keys -t "${tmux_session}:${tmux_window_poller}" "while ! nc -z 127.0.0.1 ${daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_poller}" "while true; do lotus client list-deals; lotus state list-miners | xargs -I % sh -c 'echo \"miner: %, power: \$(lotus state power %)\"'; sleep 10; done" C-m

# hit faucet
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "${base_dir}/scripts/hit_faucet.bash" C-m

# make deals!
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "${base_dir}/scripts/propose_deals.bash" C-m

# select a window and view your handywork
#
tmux select-window -t "${tmux_session}:${tmux_window_poller}"
tmux attach-session -t "${tmux_session}"
