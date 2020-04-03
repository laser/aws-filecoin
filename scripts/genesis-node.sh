#!/usr/bin/env bash

set -Exo pipefail

free_port() {
    python -c "import socket; s = socket.socket(); s.bind(('', 0)); print(s.getsockname()[1])"
}

bootstrap_daemon_port=$(free_port)
bootstrap_miner_port=$(free_port)
genesis_server_port=$(free_port)
faucet_port=$(free_port)
faucet_ip=$(ifconfig | grep -E "([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -v 127.0.0.1 | awk '{ print $2 }' | cut -f2 -d:)
tmux_session="bootstrap"
tmux_window_daemon="daemon"
tmux_window_faucet="faucet"
tmux_window_miner="miner"
tmux_window_cli="cli"
tmux_window_genesis_server="genesis"
tmux_window_tmp_setup="setup"
genesis_miner_addr="t01000"
base_dir=$(mktemp -d -t "lotus.XXXX")
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

if [[ -z "$kvdb_bucket" ]]; then
    (>&2 echo "must provide --kvdb-bucket")
    exit 1
fi

if [[ -z "$kvdb_prefix" ]]; then
    (>&2 echo "must provide --kvdb-prefix")
    exit 1
fi

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
    cp lotus lotus-storage-miner lotus-shed lotus-seed fountain ${base_dir}/bin/
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

cat > "${base_dir}/scripts/serve_genesis_file.bash" <<EOF
#!/usr/bin/env bash
set -x

while true; do { echo -ne "HTTP/1.0 200 OK\r\nContent-Length: \$(wc -c <${base_dir}/dev.gen)\r\n\r\n"; cat ${base_dir}/dev.gen; } | nc -l ${genesis_server_port}; done
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

fountain run --from=\$wallet --front=${faucet_ip}:${faucet_port}
EOF

cat > "${base_dir}/scripts/publish_state.bash" <<EOF
#!/usr/bin/env bash
set -x

public_ip=\$(curl -m 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "127.0.0.1")
ma1=\$(cat ${base_dir}/.daemon-multiaddr | sed -En "s/127\.0\.0\.1/\${public_ip}/p")
ma2=\$(cat ${base_dir}/.miner-multiaddr | sed -En "s/127\.0\.0\.1/\${public_ip}/p")

curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_genesis_daemon_multiaddr" -d "\${ma1}"
curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_genesis_miner_multiaddr" -d "\${ma2}"
curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_faucet_url" -d "http://\${public_ip}:${faucet_port}"
curl "https://kvdb.io/${kvdb_bucket}/${kvdb_prefix}_genesis_block_url" -d "http://\${public_ip}:${genesis_server_port}"
EOF

chmod +x "${base_dir}/scripts/build.bash"
chmod +x "${base_dir}/scripts/create_genesis_block.bash"
chmod +x "${base_dir}/scripts/create_miner.bash"
chmod +x "${base_dir}/scripts/publish_state.bash"
chmod +x "${base_dir}/scripts/serve_genesis_file.bash"
chmod +x "${base_dir}/scripts/start_faucet.bash"

# build various lotus binaries
#
bash "${base_dir}/scripts/build.bash"

# configure tmux session
#
tmux new-session -d -s "${tmux_session}" -n "$tmux_window_tmp_setup"
tmux set-environment -t "${tmux_session}" base_dir "$base_dir"
tmux new-window -t "${tmux_session}" -n "${tmux_window_daemon}"
tmux new-window -t "${tmux_session}" -n "${tmux_window_faucet}"
tmux new-window -t "${tmux_session}" -n "${tmux_window_miner}"
tmux new-window -t "${tmux_session}" -n "${tmux_window_cli}"
tmux new-window -t "${tmux_session}" -n "${tmux_window_genesis_server}"
tmux kill-window -t "${tmux_session}":"${tmux_window_tmp_setup}"

# ensure tmux sessions have identical environments
#
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_faucet}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_genesis_server}" "source ${base_dir}/scripts/env-bootstrap.bash" C-m

# create genesis block and run bootstrap daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "${base_dir}/scripts/create_genesis_block.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "lotus daemon --lotus-make-genesis=${base_dir}/dev.gen --genesis-template=${base_dir}/localnet.json --bootstrap=false --api=${bootstrap_daemon_port} 2>&1 | tee -a ${base_dir}/daemon.log" C-m

# serve genesis file server
#
tmux send-keys -t "${tmux_session}:${tmux_window_genesis_server}" "while ! nc -z 127.0.0.1 ${bootstrap_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_genesis_server}" "${base_dir}/scripts/serve_genesis_file.bash" C-m

# start bootstrap miner
#
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "while ! nc -z 127.0.0.1 ${bootstrap_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "${base_dir}/scripts/create_miner.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "lotus-storage-miner run --api=${bootstrap_miner_port} --nosync 2>&1 | tee -a ${base_dir}/miner.log" C-m

# dump multiaddr sfor networking client and miner daemons
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "while ! nc -z 127.0.0.1 ${bootstrap_daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus net listen | grep 127 > ${base_dir}/.daemon-multiaddr" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "while ! nc -z 127.0.0.1 ${bootstrap_miner_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus-storage-miner net listen | grep 127 > ${base_dir}/.miner-multiaddr" C-m

# start bootstrap faucet
#
tmux send-keys -t "${tmux_session}:${tmux_window_faucet}" "while ! nc -z 127.0.0.1 ${bootstrap_miner_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_faucet}" "${base_dir}/scripts/start_faucet.bash" C-m

# publish state
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "${base_dir}/scripts/publish_state.bash" C-m
