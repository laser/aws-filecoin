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
tmux_window_tmp_setup="setup"
base_dir=$(mktemp -d -t "lotus-interopnet.XXXX")
deps=(printf paste jq python nc)
lotus_git_sha=""
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
        *)
        other_args+=("$1")
        shift # Remove generic argument from processing
        ;;
    esac
done

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

git clone https://github.com/filecoin-project/lotus.git "${base_dir}/build"
pushd "${base_dir}/build" && git reset --hard "${lotus_git_sha}" && popd

SCRIPTDIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
pushd \$SCRIPTDIR/../build
pwd
make clean deps debug
cp lotus lotus-storage-miner ${base_dir}/bin/
popd
EOF

cat > "${base_dir}/scripts/create_miner.bash" <<EOF
#!/usr/bin/env bash
set -x

owner=\$(lotus wallet new bls)

msg_cid=\$(curl -D - -XPOST -F "sectorSize=2048" -F "address=\$owner" ${faucet_url}/send | tail -1)
lotus state wait-msg \$msg_cid

result=\$(curl -D - -XPOST -F "sectorSize=2048" -F "address=\$owner" ${faucet_url}/mkminer | grep Location)
query_string=\$(grep -o "\bf=.*\b" <<<\$(echo \$result))
declare -A param
while IFS='=' read -r -d '&' key value && [[ -n "\$key" ]]; do
    param["\$key"]=\$value
done <<<"\${query_string}&"
lotus state wait-msg "\${param[f]}"
maddr=\$(curl "${faucet_url}/msgwaitaddr?cid=\${param[f]}" | jq -r '.addr')
lotus-storage-miner init --actor=\$maddr --owner=\$owner
EOF

cat > "${base_dir}/scripts/publish_state.bash" <<EOF
#!/usr/bin/env bash
set -x

public_ip=\$(curl -m 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "127.0.0.1")
daemon_multiaddr=\$(lotus net listen | grep 127 | sed -En "s/127\.0\.0\.1/\${public_ip}/p")
miner_multiaddr=\$(lotus-storage-miner net listen | grep 127 | sed -En "s/127\.0\.0\.1/\${public_ip}/p")
miner_id=\$(lotus-storage-miner info | grep Miner | cut -d ' ' -f2)

curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_\${miner_id}_daemon_multiaddr" -d "\${daemon_multiaddr}"
curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_\${miner_id}_miner_multiaddr" -d "\${miner_multiaddr}"
curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_\${public_ip}" -d "\${miner_id}"
EOF

chmod +x "${base_dir}/scripts/build.bash"
chmod +x "${base_dir}/scripts/create_miner.bash"
chmod +x "${base_dir}/scripts/publish_state.bash"

# build various lotus binaries
#
bash "${base_dir}/scripts/build.bash"

# configure tmux session
#
tmux new-session -d -s "$tmux_session" -n "$tmux_window_tmp_setup"
tmux set-environment -t "$tmux_session" base_dir "$base_dir"
tmux new-window -t "$tmux_session" -n "$tmux_window_daemon"
tmux new-window -t "$tmux_session" -n "$tmux_window_miner"
tmux new-window -t "$tmux_session" -n "$tmux_window_cli"
tmux kill-window -t "$tmux_session":"$tmux_window_tmp_setup"

# ensure tmux sessions have identical environments
#
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m

# download genesis block and run daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "lotus daemon --genesis=<(curl ${genesis_block_url}) --bootstrap=false --api=${daemon_port} 2>&1 | tee -a /var/log/daemon.log" C-m

# connect to genesis node
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "while ! nc -z 127.0.0.1 ${daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus net connect ${genesis_daemon_multiaddr}" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus net connect ${genesis_miner_multiaddr}" C-m

# wait for 10-120 seconds and then attempt to sync chain
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "sleep \$(shuf -i 10-120 -n 1)" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus sync wait" C-m

# start storage miner
#
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "while ! nc -z 127.0.0.1 ${daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "(timeout --kill-after=60 60 ${base_dir}/scripts/create_miner.bash) || (rm -rf \${LOTUS_STORAGE_PATH} && timeout --kill-after=120 120 ${base_dir}/scripts/create_miner.bash) || (rm -rf \${LOTUS_STORAGE_PATH} && timeout --kill-after=180 180 ${base_dir}/scripts/create_miner.bash)" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "lotus-storage-miner run --api=${storageminer_port} --nosync 2>&1 | tee -a /var/log/miner.log" C-m

# connect storage miner to genesis node, too
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "while ! nc -z 127.0.0.1 ${storageminer_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus-storage-miner net connect ${genesis_daemon_multiaddr}" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus-storage-miner net connect ${genesis_miner_multiaddr}" C-m

# set the miner price
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus-storage-miner set-price 0.00000000049" C-m

# publish state
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "${base_dir}/scripts/publish_state.bash" C-m
