# UOFI AWS Bastion Host

This is a terraform to deploy and maintain AWS bastion hosts that connect to
the UOFI AD for authentication. Features:

- UOFI AD Authentication: supports password authentication and SSH Public
  Keys in `uiucEduSSHPublicKey`.
- High Availability: the host is launched with an AutoScaling Group (ASG). If
  the host is terminated or the availability zone goes down then the ASG will
  automatically launch a new instance.
- Host Intrusion Detection (ossec) and optionally CrowdStrike Falcon. Repeated
  failed login attempts will cause an IP to be banned.
- Advanced Networking: an ElasticIP (EIP) will automatically be assigned to
  newly launched hosts when they are ready, and hosts support additional
  Elastic Network Interfaces (ENI) with custom routes.
- Duo Push integration for SSH Password authentication.

Bastion hosts are designed to be temporary, and configuration changes or AWS
cloud events can cause a running one to be terminated and a new one launched.
Any customizations you make to an instance through SSH will be lost. However,
there are two locations on every instance that are preserved. You can use these
two store your data or scripts:

- `/mnt/bastion-sharedfs`
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

You will also need one or more AD groups who can access the bastion host as
normal users, and one or more AD groups who can access it with administrator
(root) access. These AD groups can be nested groups (groups of groups).


## Host Parameters

Some settings are stored in SSM Parameter Store and read each time a new
bastion host is launched. If you change one of these parameters after the
deployment then you will need to terminate the current bastion host and the
newly launched one will have the updated parameters.

The SSM Parameter Store paths all begin with `/$project/`, where the project
value is what you use for the `project` deploy variable. You will need to know
what value you plan on using for `project` to create these SSM Parmeters:

- Terraform: If you do not specify the `project` variable then the default
  value of `"bastion"` is used. Your SSM paths then all begin with `/bastion/`.
- CodeBuild: The value of the CloudFormation Stack name is used as the `project`
  variable. Your SSM paths then all begin with `/$STACK_NAME/`. If you are
  unsure, then assume it will be `"bastion"` and use that value for the stack
  name when you do the CodeBuild deployment.

**Some of these parameters are required before deploying the bastion host.**

### Cron

* Parameters:
  - `/$project/cron/allow` (StringList)
* Required: No

Allows you to specify a list of users who are allowed to use cron. Specify
users separated by commas; groups are not supported. By default, no users are
allowed to use cron.

**Caution:** it is not recommended you run cron jobs on the bastion host. A
more native solution like a scheduled AWS Lambda or ECS Task would be better.
However, if you do run cron jobs be aware that a job might run at the same time
on more than one host. This shouldn't happen in normal operations, but
frequently scheduled jobs might run more than once if the ASG is replacing an
instance.

### Duo

* Parameters:
  - `/$project/duo/integration-key` (String)
  - `/$project/duo/secret-key` (SecureString)
  - `/$project/duo/hostname` (String)
* Required: No

If these parameters are specified then Duo will be installed and configured for
AD users who login with a password. Locally created users will not get a Duo
push. Duo is configured to automatically use the push method.

If you do not specify all of these parameters then Duo is not installed.

### CrowdStrike Falcon

* Parameters:
  - `/$project/falcon-sensor/CID` (SecureString)
* Required: No

If you would like to run CrowdStrike Falcon Sensor on the hosts then you will
need to get the CID and store it in this parameter. CrowdStrike also requires
setting a value for the `falcon_sensor_package` variable.

### OSSEC

* Parameters:
  - `/$project/ossec/whitelists/example1` (StringList)
  - `/$project/ossec/whitelists/example2` (StringList)
  - `/$project/ossec/whitelists/example2` (StringList)
  - ...
* Required: No

You can create one or more whitelists under this SSM Parameter Store path that
contain a comma separated list of IPs for ossec to ignore. The format of each
IP is defined by ossec, but generally CIDRs and regexs are allowed.

### SSH

* Parameters:
  - `/$project/ssh/ssh_host_dsa_key` (SecureString)
  - `/$project/ssh/ssh_host_ecdsa_key` (SecureString)
  - `/$project/ssh/ssh_host_ed25519_key` (SecureString)
  - `/$project/ssh/ssh_host_rsa_key` (SecureString)
* **Required: Yes for terraform deployments.**

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
| `ssh_host_dsa_key`     | `/bastion/ssh/ssh_host_dsa_key` |
| `ssh_host_ecdsa_key`   | `/bastion/ssh/ssh_host_ecdsa_key` |
| `ssh_host_ed25519_key` | `/bastion/ssh/ssh_host_ed25519_key` |
| `ssh_host_rsa_key`     | `/bastion/ssh/ssh_host_rsa_key` |

- *Linux Workstations:* if you have OpenSSH and AWS CLI installed then you can
  use the `codebuild/bin/update-hostkeys.sh <bastion project name> <bastion hostname>`
  script to generate and upload host keys.
- *CodeBuild Deployments:* the CodeBuild deployment will generate these keys
  for you. You do not need to create them manually.

### SSS

* Parameters:
  - `/$project/sss/bind-username` (String)
  - `/$project/sss/bind-password` (SecureString)
  - `/$project/sss/admin-groups` (StringList)
  - `/$project/sss/allow-groups` (StringList)
* **Required: Yes for bind and admin-groups**

The two bind parameters are the AD user with memberOf access that the bastion
hosts will use to authenticate users. The bastion host will use this to get
group information about the user and as part of the authentication process.

The two group parameters are a comma separated list of AD groups that should
have admin access or allowed shell access. When specifying multiple groups do
not include any extra spaces before or after the group name.

Corrent Format: `Group 1,Group2`. Wrong Format: `Group 1, Group2`.

- `admin-groups`: AD groups allowed to SSH and use sudo to become root. This
  parameter is required.
- `allow-groups`: AD groups allowed to SSH but not use sudo. All AD groups
  listed in `admin-groups` are automatically included in `allow-groups`. This
  parameter is optional.

## Deploy Variables

These variables are used by the terraform and set when it is deployed. To
change them you will need to change the terraform and redeploy it.

- *Direct Deployment:* create a `terraform.tfvars` file to store these
  variables and values, or create your own tfvar file and specify it with the
  `-var-file` parameter to commands.
- *Module Deployment:* specify these variables on your module resource.
- *CodeBuild Deployment:* CloudFormation will prompt for values when you create
  or update the stack.

### Tagging

These variables are primarily used for tagging resources.

| Name                | Description |
| ------------------- | ----------- |
| service             | Service Catalog name for these resources. |
| contact             | Service email address. |
| data_classification | Data Classification value for what's stored and available through this host. Allowed values: Public, Internal, Sensitive, HighRisk. |
| environment         | Environment name: Allowed values: prod, production, test, dev, development, devtest, poc. |

### project (string)

This is the name of the project in you service, and the value will be used as
the prefix for resource names. Because it is used for naming, there are
restrictions on the allowed values:

- Must start with a letter.
- Must end with a letter or number.
- The rest must only be letters, numbers, or a hyphen.

Default: `"bastion"`

*CodeBuild Deployment:* the stack name is used for the project name.

### hostname (string)

The hostname you will associate with the IP. This is the name the instance
will use for logging and to register with CrowdStrike. It must be a valid
domain name.

### instance_type (string)

One of the valid [EC2 x86-64 instance types](https://aws.amazon.com/ec2/instance-types/).
The value you choose will determine the cost of the instance and also
[how many extra ENIs you can attach](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html#AvailableIpPerENI).

Default: `t3.micro`

### key_name (string)

The name of an existing EC2 Key Pair. This is used as the key pair to allow
emergency access to the bastion host as the `ec2-user`. You should not use this
key pair for normal bastion host access; instead use your AD credentials or
AD stored key pair.

### enhanced_monitoring (bool)

Collect more fine grained metrics about various services. Enabling this incurs
extra costs. The bastion host does not use this, although it might be useful
for your own monitoring.

Default: `false`.

### falcon_sensor_package (string)

An S3 URL (`s3://bucket/path/to/sensor.rpm`) to download the CrowdStrike Falcon
Sensor. This bucket should be private (no public access) and the bastion hosts
will use their instance roles to download the package.

If you do not specify this then CrowdStrike Falcon Sensor is not installed on
the instance.

Default: `null`

### shell_idle_timeout (number)

The number of seconds before an idle shell is closed/disconnected. CIS
recommends no longer than 900s (15mins). If this variable is `0` then idle
shells are not closed.

Default: `900`.

### public_subnets (list of strings)

List of public subnet names or IDs where the primary network interface will be
created, and the public IP assigned. At least one value must be specified, and
ideally more than one for increased availability. Even with multiple subnets
specified, only one instance should be running most of the time.

### internal_subnets (list of strings)

List of internal subnet names or IDs where private, internal resources should
be created. There must be an internal subnet specified for every availability
zone of the the public subnets.

Ideally you should use private subnets or internal subnets, but it is OK to
use campus subnets or even the same public subnets specified above.

### extra_enis (list of objects)

*(This is an advanced networking option)*

You can optionally have additional ENIs attached to the bastion hosts to reach
resources in other subnets or VPCs, not local to your VPC. For instance, you
could create a Management VPC for your bastion hosts, and use an additional ENI
to connect to the application VPC. The number of additional ENIs you can have
is limited by the `instance_type` you choose.

Each element in the `extra_enis` list is a map of keys:

| Name         | Required | Description |
| ------------ | -------- | ----------- |
| subnets      | Yes      | List of subnet names or IDs to allocate the ENI in. You must specify one in each availability zone of the public subnets. |
| description  | No       | Optional description to set for the ENI when it is created. |
| prefix_lists | Yes      | List of prefix list names or IDs, used to adjust the routing table to properly route traffic through this ENI. |

Default: `[]`

### extra_efs (map of objects)

*(This is an advanced file system option)*

You can optionally have additional EFS's mounted on the bastion hosts to access
file systems used by your projects.

The key in the map is the name of the EFS for the configuration and default
mount point (although you can override this). Each value of the map is an
object with these keys:

| Name          | Required | Description |
| ------------- | -------- | ----------- |
| filesystem_id | Yes      | The EFS ID for the filesystem to mount. |
| mount_point   | No       | Where to mount the filesystem. Default: `/mnt/$name`. |
| options       | No       | Options to pass to the mount command. Default: `tls,noresvport`. |

Default: `{}`

### cloudinit_scripts (list of strings)

*(This is an advanced customization option)*

You can run your own shell scripts after the default set of cloud-init scripts
when instances launch. This supports both boothooks and scripts, although we
strongly suggest you only use scripts. Each item of the list can be one of
two things:

- file: full path to a file to run as a script. The script will be uploaded to
  the S3 assets bucket and run on each instance launch.
- inline: a full script specified as a string. The script will be uploaded to
  the S3 assets bucket and run on each instance launch.

The scripts (file or inline) must begin with either `#!` (recommended)
or `#cloud-boothook` (dangerous). Please refer to the [cloud-init docs for more
information on scripts](https://cloudinit.readthedocs.io/en/latest/topics/format.html#user-data-script).

Default: `[]`

*CodeBuild Deployment:* this parameter is not available.

### cloudinit_config (string)

*(This is an advanced customization option)*

You can specify your own YAML file with cloud-init configuration commands to
run when instances launch. This is a good way to install additional packages,
run simple commands, and write simple files. [AWS has some customizations to
cloud-init for installing packages](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html#user-data-cloud-init), although you can also use most of the
[cloud-init modules](https://cloudinit.readthedocs.io/en/latest/topics/modules.html).

The script you provide must begin with `#cloud-config`. This terraform will
automatically add an additional line at the end of your config to make sure it
merges properly with the default configs.

Default: `null`

*CodeBuild Deployment:* this parameter is not available.

## Deployment

Before doing any deployment method you should create all the required "Host
Parameters" above and decide on values for the "Deploy Variables". How you
specify the "Deploy Variables" depends on what option you choose for
deployment.

### Direct

If you are comfortable with terraform then you can deploy this directly as you
would any other terraform.

1. Setup a [terraform environment in your account](https://www.terraform.io/docs/language/settings/backends/s3.html).
1. Create your tfvar file with values for the deploy variables (either
   `terraform.tfvars` or your own specified with the `-var-file` option).
1. Customize `terraform/_providers.tf` to specify your state bucket and key
   names, and uncomment the default aws provider.
1. Run terraform plan and apply as you normally would.

The terraform should be deployable on all platforms, including Windows, Linux,
and macOS.

### Module

You can include this terraform as a module in other terraforms. The deploy
variables become module variables.

### CodeBuild

**This is an experimental method.**

There is an included `template.yaml` file that you can use with CloudFormation
to create 2 CodeBuild Projects to manage the terraform deployments. This
simplifies using terraform for people who are not used to it.

1. Create a new CloudFormation Stack with the `template.yaml`.
1. Choose a stack name. This will be used for the `project` deploy variable
   value.
1. The `TerraformMode` selects if you will get a CodeBuild project to apply
   the terraform (create and update), or if you will get a CodeBuild Project
   to destroy the terraform. The apply mode also limits the terraform role so
   that critical resources cannot be accidently removed. You can choose the
   "All" mode to get both CodeBuild Projects.
1. The state bucket and object key are where the terraform state will be
   stored, and the dynamodb table name for locking. See the docs on how to
   setup AWS for using terraform. You can use the same bucket and table for
   all your terraform projects, but each deployment needs a unique state object
   key value.
1. Specify the rest of the stack parameters, which correspond to the deploy
   variables.
1. Review the stack summary and create it. After it finishes you will have one
   of two CodeBuild Projects, depending on the `TerraformMode` you chose:
   `$StackName-APPLY` or `$StackName-DESTROY`.

The `$StackName-APPLY` will run the terraform and create or update the
deployment. You can run it multiple times and if it has changes then it will
update.

The `$StackName-DESTROY` will delete all the resources and data. Be careful
running this project as the actions are not reversible. Deleting the
CloudFormation stack does not delete the terraform managed resources.

## Outputs

The terraform outputs a number of values to help you use the resources it
creates in other terraform configurations or CloudFormation stacks. The two most
important ones are documented here:

- `bastion_public_ip` and `/$project/outputs/public-ip`: This is the public IP
  for instances of the bastion host. You should create an `A Record` for it
  with the `hostname` in IPAM. During normal operations this value should not
  change with updates to the terraform.
- `bastion_security_group` and `/$project/outputs/security-group/`: This is the
  VPC Security Group for the bastion host. Although the public IP will not
  change, the private IP inside the VPC will change each time the ASG launches
  a new host. **Do not reference the private IP(s) in your security groups!**
  To allow the host to connect to VPC resources you must reference the output
  security group ID in your other security groups.

### Terraform Outputs

These are available from `terraform output`, a `terraform_remote_state` data
source, and as the attributes of a module.

- `bastion_autoscaling_group`: map with `arn` and `name` keys.
- `bastion_instance_profile`: map with `arn`, `name`, and `unique_id` keys.
- `bastion_public_ip`: string with the public IPv4.
- `bastion_role`: map with `arn`, `name`, and `unique_id` keys.
- `bastion_security_group`: map with `arn`, `id`, and `name` keys.
- `bastion_sharedfs`: map with `arn` and `id` keys.

### SSM Parameter Store Outputs

These are available in SSM Parameter Store, and you can use them in
CloudFormation stacks with [dynamic references](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/dynamic-references.html).

- `/$project/outputs/autoscaling-group/arn`: String
- `/$project/outputs/autoscaling-group/name`: String
- `/$project/outputs/instance-profile/arn`: String
- `/$project/outputs/instance-profile/name`: String
- `/$project/outputs/instance-profile/unique-id`: String
- `/$project/outputs/public-ip`: String
- `/$project/outputs/role/arn`: String
- `/$project/outputs/role/name`: String
- `/$project/outputs/role/unique-id`: String
- `/$project/outputs/security-group/arn`: String
- `/$project/outputs/security-group/id`: String
- `/$project/outputs/security-group/name`: String
- `/$project/outputs/sharedfs/arn`: String
- `/$project/outputs/sharedfs/id`: String
