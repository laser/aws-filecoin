#!/usr/bin/env bash

set -Exo pipefail

# USAGE
#
# ./run-storage-miner.sh --lotus-git-sha=a249aea9c444cde2bd9039bce68a26bc51aa7681 \
#   --genesis-node-multiaddr=/ip4/35.182.194.127/tcp/43287/p2p/12D3KooWKtngxxzSJtgG57cRJSRYCxjMpYKjGKGMZqfouVHvQPFT \
#   --faucet-root-url=http://35.182.194.127:41111 \
#   --genesis-file-url=http://35.182.194.127:45077
#

genesis_node_multiaddr=""
faucet_root_url=""
genesis_file_url=""
daemon_port=45000
storageminer_port=45001
tmux_session="lotus-interop"
tmux_window_bootstrap_daemon="daemon"
tmux_window_bootstrap_miner="storageminer"
tmux_window_bootstrap_cli="cli"
tmux_window_tmp_setup="setup"
base_dir=$(mktemp -d -t "lotus-interopnet.XXXX")
deps=(printf paste jq python nc)
lotus_git_sha=""
copy_binaries_from_dir=""
other_args=()

# grab shell arguments (see USAGE)
#
for arg in "$@"
do
    case $arg in
        --lotus-git-sha=*)
        lotus_git_sha="${arg#*=}"
        shift
        ;;
        --genesis-node-multiaddr=*)
        genesis_node_multiaddr="${arg#*=}"
        shift
        ;;
        --faucet-root-url=*)
        faucet_root_url="${arg#*=}"
        shift
        ;;
        --genesis-file-url=*)
        genesis_file_url="${arg#*=}"
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

cat > "${base_dir}/scripts/create_miner.bash" <<EOF
#!/usr/bin/env bash
set -x

owner=\$(lotus wallet new bls)
result=\$(curl -D - -XPOST -F "sectorSize=2048" -F "address=\$owner" ${faucet_root_url}/mkminer | grep Location)
query_string=\$(grep -o "\bf=.*\b" <<<\$(echo \$result))
declare -A param
while IFS='=' read -r -d '&' key value && [[ -n "\$key" ]]; do
    param["\$key"]=\$value
done <<<"\${query_string}&"
lotus state wait-msg "\${param[f]}"
maddr=\$(curl "${faucet_root_url}/msgwaitaddr?cid=\${param[f]}" | jq -r '.addr')
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
tmux new-window -t "$tmux_session" -n "$tmux_window_bootstrap_daemon"
tmux new-window -t "$tmux_session" -n "$tmux_window_bootstrap_miner"
tmux new-window -t "$tmux_session" -n "$tmux_window_bootstrap_cli"
tmux kill-window -t "$tmux_session":"$tmux_window_tmp_setup"

case $(basename $SHELL) in
  fish ) shell=fish ;;
  *    ) shell=bash ;;
esac

# ensure tmux sessions have identical environments
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_daemon}" "source ${base_dir}/scripts/env-bootstrap.$shell" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}" "source ${base_dir}/scripts/env-bootstrap.$shell" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_cli}" "source ${base_dir}/scripts/env-bootstrap.$shell" C-m

# download genesis block and run daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_daemon}" "lotus daemon --genesis=<(curl ${genesis_file_url}) --bootstrap=false --api=${daemon_port} 2>&1 | tee -a ${base_dir}/daemon.log" C-m

# connect to genesis node
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_cli}" "while ! nc -z 127.0.0.1 ${daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_cli}" "lotus net connect ${genesis_node_multiaddr}" C-m

sleep 10

# start storage miner
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}" "while ! nc -z 127.0.0.1 ${daemon_port} </dev/null; do sleep 5; done" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}" "${base_dir}/scripts/create_miner.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}" "lotus-storage-miner run --api=${storageminer_port} --nosync 2>&1 | tee -a ${base_dir}/miner.log" C-m

# select a window and view your handywork
#
tmux select-window -t "${tmux_session}:${tmux_window_bootstrap_miner}"
tmux attach-session -t "${tmux_session}"
