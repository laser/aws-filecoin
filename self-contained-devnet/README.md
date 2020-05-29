# Self-Contained Development Network

Run a development network on EC2 using CloudFormation. Connect your local
machine to that network and propose some storage deals.

## Use

### Deploy the Development Network to AWS

The following command brings up:

- a VPC in the provided region
- a public subnet
- a genesis node which:
    - serves its genesis block via HTTP
    - run the faucet
    - mines blocks
- some quantity of peered miner nodes

```shell
ec2_key_name=urfavkey
kvdb_bucket=U2v5qb7tNn9fwybtMDBhqB
kvdb_key_prefix=risky-dingle
lotus_git_sha=2ef3c845362b08538c0bb2eed04a50920c2a1cc2
region_name=ca-central-1
stack_name=laser-marmelade
```

```shell
./infrastructure/cloud-formation/scripts/deploy.sh ${region_name} ${stack_name} ${ec2_key_name} ${lotus_git_sha} ${kvdb_bucket} ${kvdb_key_prefix}
```

### Make Storage Deals

The following command launches a daemon locally, connects to the cluster, and
makes storage deals with each storage miner.

```shell
./scripts/local-client-node.sh \
    --kvdb-bucket=${kvdb_bucket} \
    --lotus-git-sha=${lotus_git_sha} \
    --kvdb-prefix=${kvdb_key_prefix}
```

### Destroy the Cluster

```shell
./infrastructure/cloud-formation/scripts/destroy.sh ${region_name} ${stack_name}
```
