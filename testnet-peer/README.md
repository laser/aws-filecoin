# Testnet / Peered Storage Miner and Daemon

Run a storage miner and daemon on EC2 using CloudFormation. Connect your local
machine to the miner and make some deals!

## Use

### Create Cluster

The following command brings up:

- a VPC in the provided region
- a public subnet
- a daemon, which mines and validates blocks and manages the chain
- a storage miner, which seals sectors and generates PoSts

```shell
./infrastructure/cloud-formation/scripts/deploy.sh --region=ca-central-1 --lotus-git-sha=8bea0e02d77a6d36c3fc72746a9b38c7018608e9 --ec2-key-name=your-ec2-key-here --env-name=your-env-name-here
```

### Destroy Cluster

```shell
./infrastructure/cloud-formation/scripts/destroy.sh --region=ca-central-1 --env-name=your-env-name-here
```
