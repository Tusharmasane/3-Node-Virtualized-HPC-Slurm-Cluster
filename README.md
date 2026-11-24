# Technical Documentation: 3-Node Virtualized HPC Slurm Cluster

![Screenshot From 2026-11-24 09-27-57.png](Technical%20Documentation%203-Node%20Virtualized%20HPC%20Slu/Screenshot_From_2026-11-24_09-27-57.png)

![Screenshot From 2026-11-24 09-31-37.png](Technical%20Documentation%203-Node%20Virtualized%20HPC%20Slu/Screenshot_From_2026-11-24_09-31-37.png)

## 1. Executive Summary & System Architecture

This document provides the complete, end-to-end engineering blueprint for provisioning host storage, configuring hypervisor networking, remediating enterprise proxy/DNS constraints, deploying a **3-node High-Performance Computing (HPC) cluster** using **VMware Workstation Pro**, **Ubuntu 24.04 LTS**, **NFS**, **MUNGE**, and the **Slurm Workload Manager**, and configuring a dynamic supercomputer-style MOTD telemetry banner.

### Cluster Logical Topology

- **Host Workstation:** `node-master` (Dell Precision 3640 Tower, Ubuntu Linux, VMware Workstation Pro)
- **Subnet:** VMware Private NAT (`172.16.248.0/24`, Gateway & DNS Relay: `172.16.248.2`)
- **Cluster Administrative User:** `acc-hpc` (`uid=1000`, `gid=1000`)
- **Host VM Storage Mount:** `/mnt/shared_data` (391 GB NTFS volume mounted via hardware UUID)
- **Guest Shared NFS Mount:** `/hpc_share` (exported from `node1` to `node2` and `node3`)

| **Node Role** | **Hostname** | **IP Address** | **Primary Daemons & Services** | **vCPUs** | **Allocated RAM** |
| --- | --- | --- | --- | --- | --- |
| **Head / Controller** | `node1` | `172.16.248.130` | `slurmctld`, `nfs-kernel-server`, `munge`, `chrony` | 4 | ~5.8 GB (`5878 MB`) |
| **Compute Worker 1** | `node2` | `172.16.248.132` | `slurmd`, `nfs-common`, `munge`, `chrony` | 4 | ~5.8 GB (`5878 MB`) |
| **Compute Worker 2** | `node3` | `172.16.248.131` | `slurmd`, `nfs-common`, `munge`, `chrony` | 4 | ~5.8 GB (`5878 MB`) |

## 2. Phase 1: Host Storage Provisioning & NTFS Partition Integration

### 2.1 Storage Bottleneck & Architecture

On the physical workstation (`node-master`), the Ubuntu root partition (`/dev/sda3`, 97 GB total) had only **27 GB free**—insufficient for storing guest OS ISOs and three full virtual machine disks (`90 GB` total). An unused 391 GB Windows NTFS partition (`/dev/sda2`) was cleared of Windows Fast Startup hibernation locks, mounted persistently into Ubuntu at `/mnt/shared_data`, and mapped as VMware's default storage directory.

### 2.2 Step-by-Step Host Storage Setup

1. **Inspect Physical Disk & Partition Table:**Bash
    
    ```
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS,LABEL
    sudo parted -l
    ```
    
2. **Audit Free Space on Existing NTFS Partitions (Read-Only):**Bash
    
    ```
    sudo mkdir -p /mnt/win_part1 /mnt/win_part2
    sudo mount -t ntfs-3g -o ro /dev/sda1 /mnt/win_part1
    sudo mount -t ntfs-3g -o ro /dev/sda2 /mnt/win_part2
    df -h /mnt/win_part1 /mnt/win_part2
    # Confirmed /dev/sda2: 391 GB total, 391 GB free (UUID: B00E61890E614984)
    ```
    
3. **Clear Windows Fast Startup Hibernation Flags:**Bash
    
    ```
    sudo umount /mnt/win_part1 /mnt/win_part2 /dev/sda2 2>/dev/null
    sudo ntfsfix -d /dev/sda2
    ```
    
4. **Mount `/dev/sda2` with Read/Write User Ownership & Persist in `/etc/fstab`:**Bash
    
    ```
    sudo mkdir -p /mnt/shared_data
    UUID=$(sudo blkid -s UUID -o value /dev/sda2)
    echo "UUID=${UUID}  /mnt/shared_data  ntfs-3g  uid=1000,gid=1000,umask=0022,nofail  0  0" | sudo tee -a /etc/fstab
    sudo systemctl daemon-reload
    sudo mount -a
    ```
    
5. **Provision VMware Directories & Download Ubuntu 24.04 LTS ISO:**Bash
    
    ```
    mkdir -p /mnt/shared_data/VMs /mnt/shared_data/ISOs
    wget -P /mnt/shared_data/ISOs/ https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso
    ```
    
6. **Configure VMware Workstation Workspace:**
Set **Edit -> Preferences -> Workspace -> Default location for virtual machines** to `/mnt/shared_data/VMs`.

## 3. Phase 2: Virtual Machine Hardware & Base Node Creation (`node1`)

### 3.1 VMware Resource Budgeting (Per VM)

| **Resource Parameter** | **Per-VM Setting** | **3-Node Total** | **Engineering Rationale** |
| --- | --- | --- | --- |
| **CPU Topology** | 2 Processors × 2 Cores/Proc (`4 vCPUs`) | 12 vCPUs | Leaves 4 hardware threads (out of 16) free for host OS stability. |
| **Virtualization Engine** | `Intel VT-x/EPT` Enabled | Enabled | Exposes hardware virtualization registers for parallel execution and nested threading. |
| **Memory (RAM)** | ~6 GB (`5878 MB` guest usable) | ~18 GB | Leaves ~14 GB RAM buffer for the host OS while allocating `5000 MB` per node to Slurm. |
| **Virtual Disk** | 30 GB Single File (`.vmdk`) | 90 GB | Single-file allocation avoids 2 GB chunk header overhead during parallel scratch I/O. |
| **Network Adapter** | VMware NAT (`172.16.248.0/24`) | Private Switch | Isolates inter-node cluster traffic from corporate Wi-Fi/LAN restrictions. |
| **Graphics Memory** | 1 GB vRAM (3D Accelerated) | 3 GB vRAM | Prevents vRAM over-allocation faults on headless server instances. |

### 3.2 Ubuntu 24.04 LTS Installation & Identity

1. Boot `node1` from `/mnt/shared_data/ISOs/ubuntu-24.04.1-live-server-amd64.iso`.
2. **Partitioning:** Uncheck **`Set up this disk as an LVM group`** so the full 30 GB virtual disk mounts directly to `/`.
3. **SSH & Identity:** Enable **`[X] Install OpenSSH server`** and **`[X] Allow password authentication over SSH`**. Set hostname to `node1` and username to `acc-hpc`.

## 4. Phase 3: Corporate Network & APT Repository Remediation

Behind the corporate network perimeter, three network issues blocked `sudo apt update`:

1. **Stale Campus Proxy (`172.16.0.248`):** Hardcoded proxy rules in `/etc/apt/apt.conf.d/99proxy` and `/etc/environment` caused connection timeouts.
2. **Blocked Public DNS (`8.8.8.8` / `8.8.4.4`):** Outbound DNS queries to Google DNS were dropped by the firewall; switching Netplan to VMware's local NAT DNS relay (`172.16.248.2`) routed DNS cleanly through the host machine.
3. **Invalid Mirror URL:** `/etc/apt/sources.list.d/ubuntu.sources` lacked a valid `/ubuntu/` repository path (`404 Not Found / no Release file`).

### Automated Remediation & Toolchain Install (Run on `node1` Before Cloning)

Bash

```
# 1. Remove stale proxy settings
sudo mv /etc/apt/apt.conf.d/99proxy /etc/apt/apt.conf.d/99proxy.bak 2>/dev/null
sudo sed -i '/172\.16/d' /etc/environment
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY

# 2. Switch DNS to VMware NAT DNS relay (172.16.248.2)
sudo sed -i 's/8.8.8.8/172.16.248.2/g; /8.8.4.4/d' /etc/netplan/50-cloud-init.yaml
sudo netplan apply

# 3. Point APT sources to official Ubuntu 24.04 (noble) archive
sudo sed -i 's|URIs: .*|URIs: http://archive.ubuntu.com/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources

# 4. Update OS and pre-install compilers & MPI headers
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential mpi-default-dev openssh-server net-tools
```

## 5. Phase 4: Full Clone Replication, Networking & Passwordless SSH

### 5.1 Execute Full Clones (`node2` and `node3`)

1. Shut down `node1` cleanly: `sudo poweroff`
2. In VMware Workstation: Right-click `node1` **> Manage -> Clone... -> Current state -> Create a full clone**.
3. Create `node2` and `node3` inside `/mnt/shared_data/VMs`, then power on all three VMs.

### 5.2 Assign Unique Hostnames on Clones

On **`node2`**:

Bash

```
sudo hostnamectl set-hostname node2 && sudo reboot
```

On **`node3`**:

Bash

```
sudo hostnamectl set-hostname node3 && sudo reboot
```

### 5.3 Static `/etc/hosts` Mapping & Passwordless SSH

1. Append the cluster IP matrix to `/etc/hosts` on **all 3 nodes**:Bash
    
    ```
    sudo tee -a /etc/hosts <<EOF
    172.16.248.130 node1
    172.16.248.132 node2
    172.16.248.131 node3
    EOF
    ```
    
2. Generate and distribute Ed25519 SSH keys from **`node1`** to all nodes:
    
    Bash
    
    ```
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
    for node in node1 node2 node3; do
      ssh-copy-id acc-hpc@$node
    done
    ```
    

## 6. Phase 5: Clock Synchronization (Chrony) & Shared NFS Storage (`/hpc_share`)

### 6.1 Cluster-Wide NTP Time Sync (All 3 Nodes)

MUNGE enforces a strict **300-second TTL** on authentication tokens; clock drift will reject Slurm job dispatches.

Bash

```
sudo apt install -y chrony
sudo systemctl enable --now chrony
sudo chronyc -a makestep
timedatectl
```

### 6.2 Shared NFS Workspace (`/hpc_share`)

Export `/hpc_share` from `node1` and mount it across `node2` and `node3` so compiled MPI binaries, input datasets, and Slurm job outputs are identically accessible across all nodes.

1. **On `node1` (NFS Server):**Bash
    
    ```
    sudo apt install -y nfs-kernel-server
    sudo mkdir -p /hpc_share
    sudo chown -R acc-hpc:acc-hpc /hpc_share
    echo "/hpc_share 172.16.248.0/24(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
    sudo exportfs -ra
    sudo systemctl enable --now nfs-kernel-server
    ```
    
2. **On `node2` and `node3` (NFS Clients):**Bash
    
    ```
    sudo apt install -y nfs-common
    sudo mkdir -p /hpc_share
    echo "node1:/hpc_share /hpc_share nfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab
    sudo mount -a
    ```
    

## 7. Phase 6: Cryptographic Authentication (MUNGE)

1. **Install MUNGE & Verify Identical UID/GID (`uid=112`, `gid=110`) on All 3 Nodes:**Bash
    
    ```
    sudo apt install -y munge libmunge2 libmunge-dev
    id munge
    ```
    
2. **Reset State & Lock Permissions on All 3 Nodes:**Bash
    
    ```
    sudo systemctl stop munge
    sudo rm -rf /etc/munge/munge.key /var/run/munge/* /var/log/munge/*
    sudo mkdir -p /run/munge
    sudo chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge /run/munge
    sudo chmod 0700 /etc/munge /var/lib/munge /var/log/munge
    sudo chmod 0755 /run/munge
    ```
    
3. **Generate Key on `node1` and Distribute to `node2` & `node3`:**Bash
    
    ```
    # On node1:
    sudo /usr/sbin/mungekey --verbose --create --keyfile=/etc/munge/munge.key
    sudo chown munge:munge /etc/munge/munge.key
    sudo chmod 0400 /etc/munge/munge.key
    
    # Distribute to workers:
    for node in node2 node3; do
      sudo cat /etc/munge/munge.key | ssh acc-hpc@$node "sudo tee /etc/munge/munge.key > /dev/null && sudo chown munge:munge /etc/munge/munge.key && sudo chmod 0400 /etc/munge/munge.key"
    done
    ```
    
4. **Start & Verify MUNGE Across Cluster:**Bash
    
    ```
    # Run on all 3 nodes:
    sudo systemctl enable --now munge
    
    # Test from node1 (both must return STATUS: Success (0)):
    munge -n | ssh node2 unmunge
    munge -n | ssh node3 unmunge
    ```
    

## 8. Phase 7: Slurm Workload Manager Deployment

### 8.1 Install Daemons & Create Spool Directories

1. **On `node1` (Controller Node):**Bash
    
    ```
    sudo apt install -y slurmctld slurm-client
    sudo mkdir -p /var/spool/slurmctld /var/log/slurm /etc/slurm
    sudo chown -R slurm:slurm /var/spool/slurmctld /var/log/slurm
    ```
    
2. **On `node2` and `node3` (Compute Nodes):**Bash
    
    ```
    sudo apt install -y slurmd slurm-client
    sudo mkdir -p /var/spool/slurmd /var/log/slurm /etc/slurm
    sudo chown -R slurm:slurm /var/spool/slurmd /var/log/slurm
    ```
    

### 8.2 Hardware-Matched `slurm.conf` & `cgroup.conf` (`node1`)

Configured directly from `lscpu` (`CPUs=4`, `Sockets=2`, `CoresPerSocket=2`, `ThreadsPerCore=1`) and `free -m` (`5878 MB` total RAM, reserving `878 MB` for OS overhead and allocating `RealMemory=5000` per compute node):

Bash

```
sudo tee /etc/slurm/slurm.conf <<EOF
ClusterName=hpccluster
SlurmctldHost=node1
SlurmUser=slurm
SlurmctldPort=6817
SlurmdPort=6818
AuthType=auth/munge
CryptoType=crypto/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

# Process Tracking, Backfill Scheduling & Cgroup Isolation
ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
ReturnToService=2

# Compute Node Hardware Topology
NodeName=node[2-3] CPUs=4 Sockets=2 CoresPerSocket=2 ThreadsPerCore=1 RealMemory=5000 State=UNKNOWN

# Default Partition
PartitionName=compute Nodes=node[2-3] Default=YES MaxTime=INFINITE State=UP
EOF

sudo tee /etc/slurm/cgroup.conf <<EOF
CgroupAutomount=yes
ConstrainCores=yes
ConstrainRAMSpace=yes
EOF
```

### 8.3 Sync Configs & Start Cluster Daemons

Bash

```
# 1. Distribute configs from node1 to node2 and node3:
for node in node2 node3; do
  scp /etc/slurm/slurm.conf /etc/slurm/cgroup.conf acc-hpc@$node:/tmp/
  ssh acc-hpc@$node "sudo mv /tmp/slurm.conf /tmp/cgroup.conf /etc/slurm/ && sudo chown root:root /etc/slurm/*.conf"
done

# 2. Start controller on node1:
sudo systemctl enable --now slurmctld

# 3. Start worker daemons on node2 and node3:
ssh node2 "sudo systemctl enable --now slurmd"
ssh node3 "sudo systemctl enable --now slurmd"

# 4. Resume nodes and verify cluster state on node1:
sudo scontrol update NodeName=node[2-3] State=RESUME
sinfo
```

## 9. Phase 8: Supercomputer Dynamic Login Banner (`MOTD`)

To provide immediate cluster visibility upon SSH login without Ubuntu news/ESM clutter or network timeout delays:

1. **Disable Default Ubuntu MOTD Noise (All 3 Nodes):**Bash
    
    ```
    for node in node1 node2 node3; do
      ssh -t acc-hpc@$node "sudo chmod -x /etc/update-motd.d/00-header /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news /etc/update-motd.d/90-updates-available /etc/update-motd.d/91-contract-ua-esm-status /etc/update-motd.d/91-release-upgrade /etc/update-motd.d/95-hwe-eol 2>/dev/null"
    done
    ```
    
2. **Configure Top-Level ASCII Cluster Banner (`00-hpc-header`) & Live Slurm Telemetry (`99-hpc-status`) on `node1`:**Bash
    
    ```
    sudo tee /etc/update-motd.d/00-hpc-header <<'EOF'
    #!/bin/bash
    cat <<'BANNER'
    ================================================================================
      _   _ ____   ____    ____ _    _   _ ____ _____ _____ ____
     | | | |  _ \ / ___|  / ___| |  | | | / ___|_   _| ____|  _ \
     | |_| | |_) | |     | |   | |  | | | \___ \ | | |  _| | |_) |
     |  _  |  __/| |___  | |___| |__| |_| |___) || | | |___|  _ <
     |_| |_|_|    \____|  \____|_____\___/|____/ |_| |_____|_| \_\
    
      Cluster    : hpccluster (3-Node VMware Slurm Cluster)
      Head Node  : node1 (172.16.248.130)
      Compute    : node2, node3 (8 vCPUs | 10 GB Slurm RAM)
      Shared Dir : /hpc_share (NFS)
      Commands   : sinfo | squeue | sbatch | scancel
    ================================================================================
    BANNER
    EOF
    
    sudo chmod +x /etc/update-motd.d/00-hpc-header
    sudo truncate -s 0 /etc/motd
    
    sudo tee /etc/update-motd.d/99-hpc-status <<'EOF'
    #!/bin/bash
    echo ""
    echo " [ Live Slurm Partition & Node Status ]"
    sinfo -o "  %12P %8a %10l %6D %8t %N" 2>/dev/null || echo "  Slurm controller offline"
    echo ""
    echo " [ Shared Storage (/hpc_share) ]"
    df -h /hpc_share | awk 'NR==2 {printf "  Path: /hpc_share     Used: %s / %s (%s)\n", $3, $2, $5}'
    echo "================================================================================"
    echo ""
    EOF
    
    sudo chmod +x /etc/update-motd.d/99-hpc-status
    ```
    

## 10. Phase 9: End-to-End Cluster Validation (OpenMPI + Slurm)

Execute a distributed 8-task MPI job across `node2` and `node3` from the shared NFS directory (`/hpc_share`):

1. **Create MPI Source File (`/hpc_share/mpi_test.c`):**Bash
    
    ```
    cat << 'EOF' > /hpc_share/mpi_test.c
    #include <mpi.h>
    #include <stdio.h>
    #include <unistd.h>
    
    int main(int argc, char** argv) {
        MPI_Init(&argc, &argv);
        int rank, size;
        char hostname[256];
        MPI_Comm_rank(MPI_COMM_WORLD, &rank);
        MPI_Comm_size(MPI_COMM_WORLD, &size);
        gethostname(hostname, sizeof(hostname));
        printf("Hello from MPI rank %d of %d running on %s\n", rank, size, hostname);
        MPI_Finalize();
        return 0;
    }
    EOF
    ```
    
2. **Compile Binary on Shared Volume:**Bash
    
    ```
    mpicc /hpc_share/mpi_test.c -o /hpc_share/mpi_test
    ```
    
3. **Create & Submit Batch Script (`/hpc_share/job.sh`):**Bash
    
    ```
    cat << 'EOF' > /hpc_share/job.sh
    #!/bin/bash
    #SBATCH --job-name=mpi_verify
    #SBATCH --nodes=2
    #SBATCH --ntasks=8
    #SBATCH --output=/hpc_share/mpi_output_%j.log
    
    mpirun /hpc_share/mpi_test
    EOF
    
    sbatch /hpc_share/job.sh
    ```
    
4. **Verified Execution Output (`/hpc_share/mpi_output_4.log`):**Plaintext
    
    ```
    Hello from MPI rank 0 of 8 running on node2
    Hello from MPI rank 1 of 8 running on node2
    Hello from MPI rank 2 of 8 running on node2
    Hello from MPI rank 3 of 8 running on node2
    Hello from MPI rank 4 of 8 running on node3
    Hello from MPI rank 5 of 8 running on node3
    Hello from MPI rank 6 of 8 running on node3
    Hello from MPI rank 7 of 8 running on node3
    ```
    

## 11. Troubleshooting Quick-Reference Matrix

| **Symptom / Error** | **Root Cause** | **Resolution** |
| --- | --- | --- |
| **`sinfo` shows `down*` or `drain`** | `slurmd` booted prior to `slurmctld` or `RealMemory` exceeded physical RAM. | Inspect `/var/log/slurm/slurmctld.log`, then execute `sudo scontrol update NodeName=node[2-3] State=RESUME`. |
| **`munge: Credential expired`** | Clock skew between `node1` and compute nodes exceeds 300 seconds. | Run `sudo chronyc -a makestep` across all 3 nodes. |
| **`slurmd` fails cgroup initialization** | Ubuntu 24.04 defaults to `cgroup v2`. | Add `CgroupPlugin=cgroup/v2` to `/etc/slurm/cgroup.conf`, copy to workers, and restart `slurmd`. |
| **`/mnt/shared_data` fails to mount on boot** | NTFS volume marked dirty after an unclean host shutdown. | Run `sudo ntfsfix -d /dev/sda2 && sudo mount -a` on the host machine (`node-master`). |
| **SSH login hangs on MOTD** | `91-release-upgrade` attempting to reach `changelogs.ubuntu.com` behind proxy. | Ensure `sudo chmod -x /etc/update-motd.d/91-release-upgrade` is applied. |