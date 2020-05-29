#!/usr/bin/env bash

set -Exo pipefail

free_port() {
    python -c "import socket; s = socket.socket(); s.bind(('', 0)); print(s.getsockname()[1])"
}

base_dir=$(mktemp -d -t "lotus-testnet.XXXX")
daemon_port=$(free_port)
deps=(printf paste jq python nc)
faucet_url="https://faucet.testnet.filecoin.io"
lotus_git_sha=""
other_args=()
storageminer_port=$(free_port)
tmux_session="lotus"
tmux_window_cli="cli"
tmux_window_daemon="daemon"
tmux_window_miner="miner"
tmux_window_tmp_setup="setup"

# ensure that script dependencies are met
#
for dep in ${deps[@]}; do
    if ! which "${dep}"; then
        (>&2 echo "please install ${dep} before running this script")
        exit 1
    fi
done

# grab shell arguments
#
for arg in "$@"
do
    case $arg in
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

# create some directories which we'll need later
#
mkdir -p "${base_dir}"
mkdir -p "${base_dir}/scripts"
mkdir -p "${base_dir}/bin"

cat > "${base_dir}/scripts/env.bash" <<EOF
export RUST_LOG=info
export PATH=${base_dir}/bin:\$PATH
export LOTUS_PATH=${base_dir}/.lotus
export LOTUS_STORAGE_PATH=${base_dir}/.lotus-storage
EOF

cat > "${base_dir}/scripts/build.bash" <<EOF
#!/usr/bin/env bash
set -x

git clone https://github.com/filecoin-project/lotus.git "${base_dir}/build"
pushd "${base_dir}/build" && git reset --hard "${lotus_git_sha}" && popd

SCRIPTDIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
pushd \$SCRIPTDIR/../build
pwd
make clean
make all
cp lotus lotus-storage-miner ${base_dir}/bin/
popd
EOF

cat > "${base_dir}/scripts/create_miner.bash" <<EOF
#!/usr/bin/env bash
set -x

owner=\$(lotus wallet new bls)

msg_cid=\$(curl -D - -XPOST -F "sectorSize=34359738368" -F "address=\$owner" ${faucet_url}/send | tail -1)
lotus state wait-msg \$msg_cid

result=\$(curl -D - -XPOST -F "sectorSize=34359738368" -F "address=\$owner" ${faucet_url}/mkminer | grep Location)
query_string=\$(grep -o "\bf=.*\b" <<<\$(echo \$result))
declare -A param
while IFS='=' read -r -d '&' key value && [[ -n "\$key" ]]; do
    param["\$key"]=\$value
done <<<"\${query_string}&"
lotus state wait-msg "\${param[f]}"
maddr=\$(curl "${faucet_url}/msgwaitaddr?cid=\${param[f]}" | jq -r '.addr')
lotus-storage-miner init --actor=\$maddr --owner=\$owner
EOF

chmod +x "${base_dir}/scripts/build.bash"
chmod +x "${base_dir}/scripts/create_miner.bash"

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
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "source ${base_dir}/scripts/env.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "source ${base_dir}/scripts/env.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "source ${base_dir}/scripts/env.bash" C-m

# run daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_daemon}" "lotus daemon --api=${daemon_port} 2>&1 | tee -a /var/log/daemon.log" C-m

# wait for daemon to come online and then sync chain
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "while ! nc -z 127.0.0.1 ${daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus sync wait" C-m

# create and start storage miner
#
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "while ! nc -z 127.0.0.1 ${daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "${base_dir}/scripts/create_miner.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_miner}" "lotus-storage-miner run --api=${storageminer_port} --nosync 2>&1 | tee -a /var/log/miner.log" C-m

# set the miner price
#
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "while ! nc -z 127.0.0.1 ${storageminer_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_cli}" "lotus-storage-miner set-price 0.00000000049" C-m
