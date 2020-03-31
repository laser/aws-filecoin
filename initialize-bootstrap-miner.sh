#!/usr/bin/env bash

set -Exo pipefail

free_port() {
  python -c "import socket; s = socket.socket(); s.bind(('', 0)); print(s.getsockname()[1])"
}

lotus_git_sha=$1
bootstrap_daemon_port=$(free_port)
bootstrap_miner_port=$(free_port)
tmux_session="lotus-interop"
tmux_window_bootstrap_daemon="daemon"
tmux_window_bootstrap_miner="miner"
tmux_window_tmp_setup="setup"
genesis_miner_addr="t01000"
base_dir=$(mktemp -d -t "lotus-interopnet.XXXX")

# set proper Git SHA
#
git clone https://github.com/filecoin-project/lotus.git "${base_dir}/build"
pushd "${base_dir}/build" && git reset --hard "${lotus_git_sha}" && popd

# create some directories which we'll need later
#
mkdir -p "${base_dir}/scripts"
mkdir -p "${base_dir}/bin"

cat > "${base_dir}/scripts/build.bash" <<EOF
#!/usr/bin/env bash
set -x
SCRIPTDIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
pushd \$SCRIPTDIR/../build
pwd
make clean deps debug lotus-shed
cp lotus lotus-storage-miner lotus-shed lotus-seed ../bin/
popd
EOF

cat > "${base_dir}/scripts/env.fish" <<EOF
set -x PATH ${base_dir}/bin \$PATH
set -x LOTUS_PATH ${base_dir}/.lotus
set -x LOTUS_STORAGE_PATH ${base_dir}/.lotusstorage
set -x LOTUS_GENESIS_SECTORS \$base_dir/.genesis-sectors/
EOF

cat > "${base_dir}/scripts/env.bash" <<EOF
export PATH=${base_dir}/bin:\$PATH
export LOTUS_PATH=${base_dir}/.lotus
export LOTUS_STORAGE_PATH=${base_dir}/.lotusstorage
export LOTUS_GENESIS_SECTORS=\$base_dir/.genesis-sectors/
EOF

cat > "${base_dir}/scripts/create_genesis_block.bash" <<EOF
#!/usr/bin/env bash
set -x

HOME="${base_dir}" lotus-seed pre-seal --sector-size 2048 --num-sectors 2 --miner-addr "${genesis_miner_addr}"
lotus-seed genesis new "${base_dir}/localnet.json"
lotus-seed genesis add-miner "${base_dir}/localnet.json" "\$LOTUS_GENESIS_SECTORS/pre-seal-${genesis_miner_addr}.json"
EOF

cat > "${base_dir}/scripts/create_miner.bash" <<EOF
#!/usr/bin/env bash
set -x

while [ ! -f \$LOTUS_PATH/api ]; do
  sleep 5
done

lotus wallet import "${base_dir}/.genesis-sectors/pre-seal-${genesis_miner_addr}.key"
lotus-storage-miner init --genesis-miner --actor="${genesis_miner_addr}" --sector-size=2048 --pre-sealed-sectors=\$LOTUS_GENESIS_SECTORS --pre-sealed-metadata="\$LOTUS_GENESIS_SECTORS/pre-seal-${genesis_miner_addr}.json" --nosync
EOF

chmod +x "${base_dir}/scripts/build.bash"
chmod +x "${base_dir}/scripts/create_genesis_block.bash"
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
tmux kill-window -t "$tmux_session":"$tmux_window_tmp_setup"

case $(basename $SHELL) in
  fish ) shell=fish ;;
  *    ) shell=bash ;;
esac

# ensure tmux sessions have identical environments
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_daemon}" "source ${base_dir}/scripts/env.$shell" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}"  "source ${base_dir}/scripts/env.$shell" C-m

# create genesis block and run bootstrap daemon
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_daemon}" "${base_dir}/scripts/create_genesis_block.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_daemon}" "lotus daemon --lotus-make-genesis=${base_dir}/dev.gen --genesis-template=${base_dir}/localnet.json --bootstrap=false --api=${bootstrap_daemon_port} 2>&1 | tee -a ${base_dir}/daemon.log" C-m

# start bootstrap miner
#
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}"   "${base_dir}/scripts/create_miner.bash" C-m
tmux send-keys -t "${tmux_session}:${tmux_window_bootstrap_miner}"   "lotus-storage-miner run --api=${bootstrap_miner_port} --nosync 2>&1 | tee -a ${base_dir}/miner.log" C-m

# select bootstrap daemon and view your handywork
#
tmux select-window -t "${tmux_session}:${tmux_window_bootstrap_daemon}"
tmux attach-session -t $tmux_session
