# UOFI AWS Bastion Host

This is a terraform to deploy and maintain AWS bastion hosts that connect to
the UOFI AD for authentication. Features:

- UOFI AD Authentication: supports password authentication and SSH Public
  Keys in uiucEduSSHPublicKey.
- High Availability: the host is launched with an AutoScaling Group (ASG). If
  the host is terminated or the availability zone goes down then the ASG will
  automatically launch a new instance.
- Host Intrusion Detection (ossec) and optionally CrowdStrike Falcon. Repeated
  failed login attempts will cause an IP to be banned.
- Advanced Networking: an ElasticIP (EIP) will automatically be assigned to
  newly launched hosts when they are ready, and hosts support additional
  Elastic Network Interfaces (ENI) with custom routes.

Running bastion instances are designed to be temporary, and configuration
changes or AWS cloud events can cause a running one to be terminated and a new
one launched. Any customizations you make to an instance through SSH will be
lost.

However, there are two locations on every instance that are preserved. You can
use these two store your data or scripts:

- `/mnt/sharedfs`
- `/home/ad.uillinois.edu`

## Prerequisites

There are several things required before you can deploy this terraform.

### Enterprise VPC

You must have deployed an [Enterprise VPC](https://answers.uillinois.edu/illinois/71015)
with peering to the campus Transit Gateway (recommended) or the Core Services
VPC (deprecated). The bastion host uses these peers to connect to AD for
authentication.

Additionally, you must have these features enabled on the VPC:

- [Recursive DNS Option 1 or 3](https://answers.uillinois.edu/illinois/74081)
  deployed. **You will not be able to use this terraform with Recursive DNS
  Option 2**.
- VPC Gateway Endpoints for S3. Newer versions of the Enterprise VPC terraform
  deploy these automatically and in older versions they were optional. You can
  check if you have VPC Gateway Endpoints by going to "VPC" in the AWS Console,
  selecting "Endpoints", and check if there is an entry for the VPC you want
  to use and the service `com.amazonaws.us-east-2.s3`.

### Terraform Remote State

You should have an S3 bucket and DynamoDB table for storing the terraform
remote state. You can use the same bucket (but with a different state key) and
table you used for the Enterprise VPC.

### UOFI Active Directory

You need to create an AD user with a secure password and request from the
[UIUC Tech Help Center](https://help.uillinois.edu/TDClient/42/UIUC/Home/) that
it have "memberOf access".

You will also need one or more groups who can access the bastion host as normal
users, and one or more groups who can access it with administrator (root)
access. These groups can be nested groups.


## Host Parameters

Some settings are stored in SSM Parameter Store and read each time a new
bastion host is launched. If you change one of these parameters after the
deployment then you will need to terminate the current bastion host and the
newly launched one will have the updated parameters.

### /bastion/falcon-sensor/CID (SecureString)

If you would like to run CrowdStrike Falcon Sensor on the hosts then you will
need to get the CID and store it in this parameter.

### /bastion/ossec/whitelists/* (StringList)

You can create one or more whitelists under this SSM Parameter Store path that
contain a comma separated list of IPs for ossec to ignore. The format of each
IP is defined by ossec, but generally CIDRs and regexs are allowed.

### /bastion/ssh/* (SecureString)

You will need to generate a set of SSH Host Keys for the bastion host to use.
They are stored in SSM Parameter Store so that each newly launched bastion host
uses the same keys, and the users are not presented with warnings on the host
keys changing.

You can generate a set of host keys by running the
`mkdir bastion-keys && ssh-keygen -A -f bastion-keys` command. The keys will be
in `bastion-keys/etc/ssh`. You only need to create SSM Parameters for the
private key parts (you can ignore the `.pub` files):

| File                   | SSM Parameter |
| ---------------------- | ------------- |
| `ssh_host_ecdsa_key`   | `/bastion/ssh/ssh_host_ecdsa_key` |
| `ssh_host_ed25519_key` | `/bastion/ssh/ssh_host_ed25519_key` |
| `ssh_host_rsa_key`     | `/bastion/ssh/ssh_host_rsa_key` |

**Linux Workstations**: if you have OpenSSH and AWS CLI installed then you can
use the `codebuild/bin/update-hostkeys.sh <bastion project name> <bastion hostname>`
script to generate and upload host keys.

**CodeBuild**: the CodeBuild deployment will generate these keys for you.

### /bastion/sss/bind-username (String) and /bastion/sss/bind-password (SecureString)

These two parameters are the AD user with memberOf access that the bastion
hosts will use to authenticate users.

### /bastion/sss/admin-groups and /bastion/sss/allow-groups (StringList)

Comma separated list of AD groups that should have admin access or allowed
shell access. When specifying multiple groups do not include any extra spaces
before or after the group name.

Corrent Format: `Group 1,Group2`. Wrong Format: `Group 1, Group2`.

- `admin-groups`: groups allowed to SSH and use sudo to become root. This
  parameter is required.
- `allow-groups`: groups allowed to SSH but not use sudo. All groups listed in
  `admin-groups` are automatically included in `allow-groups`. This parameter
  is optional.

## Deploy Variables

These variables are used by the terraform and set when it is deployed. To
change them you will need to change the terraform and redeploy it.

