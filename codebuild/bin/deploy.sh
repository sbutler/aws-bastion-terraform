#!/bin/bash
set -e

# Meant to be used to deploy the terraform from a CodeBuild environment. The
# variables and backend-config should be present as environment variables.
#
#   STATE_BUCKET_NAME: S3 bucket for the terraform state
#   STATE_OBJECT_KEY: S3 object key for the terraform state
#   STATE_LOCK_TABLE_NAME: DyanmoDB table to use for terraform state locking
#
#   TF_VAR_*: various variables for the terraform
#   TF_VAR_public_subnets: comma separated list of public subnets
#   TF_VAR_internal_subnets: comma separated list of internal subnets

# Turns a comma separated list into an HCL formatted list
_make_hcl_list () {
    if [[ -z $1 ]]; then
        echo "[]"
        return 0
    fi

    local -a _arr1
    IFS=, read -r -a _arr1 <<< "$1"

    local -a _arr2
    local _v
    for _v in "${_arr1[@]}"; do
        _arr2+=("\"$_v\"")
    done

    echo "[$(IFS=,; echo "${_arr2[*]}")]"
}

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && cd .. && pwd)"
export PATH="$BASE_DIR/bin:$PATH"

[[ -z $TF_VAR_falcon_sensor_package ]] && unset TF_VAR_falcon_sensor_package
[[ -z $TF_VAR_extra_enis ]] && unset TF_VAR_extra_enis

if [[ -z $TF_VAR_public_subnets ]]; then
    unset TF_VAR_public_subnets
else
    export TF_VAR_public_subnets="$(_make_hcl_list "$TF_VAR_public_subnets")"
fi

if [[ -z $TF_VAR_internal_subnets ]]; then
    unset $TF_VAR_internal_subnets
else
    export TF_VAR_internal_subnets="$(_make_hcl_list "$TF_VAR_internal_subnets")"
fi

DEPLOY_DIR="$1"; shift
if [[ -z $DEPLOY_DIR ]]; then
    echo "ERROR: no terraform directory specified"
    exit 1
elif [[ ! -d $DEPLOY_DIR ]]; then
    echo "ERROR: '$DEPLOY_DIR' is not a directory"
    exit 1
fi

cd "$DEPLOY_DIR1"
[[ -e "_providers-codebuild.tf" ]] || ln -s "$BASE_DIR/_providers.tf" _providers-codebuild.tf

echo "INFO: running terraform init"
terraform init \
    -backend-config="bucket=$STATE_BUCKET_NAME" \
    -backend-config="key=$STATE_OBJECT_KEY" \
    -backend-config="dynamodb_table=$STATE_LOCK_TABLE_NAME"

echo "INFO: running terraform plan"
terraform plan "$@" -out changes.tfplan

echo "INFO: running terraform apply"
terraform apply "$@" -auto-approve changes.tfplan
