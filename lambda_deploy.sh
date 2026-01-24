#!/usr/bin/env bash

set -euo pipefail

find_vpce_id() {
  local service_name=$1
  local endpoint_type=$2
  aws ec2 describe-vpc-endpoints \
    --region "${REGION:-ap-northeast-1}" \
    --profile "${PROFILE:-default}" \
    --filters \
      "Name=vpc-id,Values=${VPCID}" \
      "Name=service-name,Values=${service_name}" \
      "Name=vpc-endpoint-type,Values=${endpoint_type}" \
    --query 'VpcEndpoints[0].VpcEndpointId' \
    --output text \
    --no-cli-pager 2>/dev/null | awk 'NF && $1 != "None" {print $1}'
}

# Cloudformationスタックの状態を取得
get_stack_status() {
  local stack_name=$1
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "${REGION:-ap-northeast-1}" \
    --profile "${PROFILE:-default}" \
    --query 'Stacks[0].StackStatus' \
    --output text \
    --no-cli-pager 2>/dev/null || true
}

# スタックがROLLBACK_COMPLETE状態ならスタックを削除する
delete_stack_if_rollback_complete() {
  local stack_name=$1
  local status
  status="$(get_stack_status "$stack_name")"
  if [[ "$status" == "ROLLBACK_COMPLETE" ]]; then
    echo "Stack '$stack_name' is ROLLBACK_COMPLETE. Deleting it before deploy..." >&2
    sam delete \
      --no-prompts \
      --stack-name "$stack_name" \
      --region "${REGION:-ap-northeast-1}" \
      --profile "${PROFILE:-default}"
  fi
}

usage() {
  echo "Usage: $0 {deploy|delete} [additional sam args...]" >&2
  echo "samconfig.toml の設定を使用します。必要なら追加引数で上書きしてください。" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

source .env

CMD=$1
shift || true

case "$CMD" in
  deploy)
    STACK_NAME_VAL="${LAMBDA_STACK_NAME:-${STACK_NAME:-sam-pyappfunc-logonlogoff-test}}"
    delete_stack_if_rollback_complete "$STACK_NAME_VAL"

    # S3 Gatewayは既存のものを活用（あればそれを使い、なければエラー）
    # SSM Interfaceは存在すれば作成しない、なければ作成する
    REGION_VAL="${REGION:-ap-northeast-1}"
    S3_SERVICE_NAME="com.amazonaws.${REGION_VAL}.s3"
    SSM_SERVICE_NAME="com.amazonaws.${REGION_VAL}.ssm"

    S3_VPCE_ID_VAL="${S3_VPCE_ID:-}"
    if [[ -z "$S3_VPCE_ID_VAL" ]]; then
      S3_VPCE_ID_VAL="$(find_vpce_id "$S3_SERVICE_NAME" "Gateway" || true)"
    fi
    if [[ -z "$S3_VPCE_ID_VAL" ]]; then
      echo "Error: 既存の S3 Gateway VPCE が見つかりません。S3_VPCE_ID を指定するか、事前にVPCEを作成してください" >&2
      exit 2
    fi
    CREATE_S3_ENDPOINT_VAL="false"

    SSM_VPCE_ID_VAL="${SSM_VPCE_ID:-}"
    if [[ -z "$SSM_VPCE_ID_VAL" ]]; then
      SSM_VPCE_ID_VAL="$(find_vpce_id "$SSM_SERVICE_NAME" "Interface" || true)"
    fi

    # CREATE_SSM_ENDPOINTが明示されていない場合は自動判定
    if [[ -z "${CREATE_SSM_ENDPOINT:-}" ]]; then
      if [[ -n "$SSM_VPCE_ID_VAL" ]]; then
        CREATE_SSM_ENDPOINT_VAL="false"
      else
        CREATE_SSM_ENDPOINT_VAL="true"
      fi
    else
      CREATE_SSM_ENDPOINT_VAL="${CREATE_SSM_ENDPOINT}"
    fi

    if [[ "$CREATE_SSM_ENDPOINT_VAL" == "false" && -z "$SSM_VPCE_ID_VAL" ]]; then
      echo "Error: CREATE_SSM_ENDPOINT=false の場合、SSM_VPCE_ID(vpce-xxxx) が必要です" >&2
      exit 2
    fi

    PARAMS=(
      VpcId="${VPCID}"
      VpcSubnetIds="${SUBNETIDS}"
      RouteTableIds="${ROUTETABLEIDS}"
      CreateS3GatewayEndpoint="$CREATE_S3_ENDPOINT_VAL"
      S3GatewayEndpointId="${S3_VPCE_ID_VAL}"
      CreateSsmInterfaceEndpoint="$CREATE_SSM_ENDPOINT_VAL"
      BucketName="${BUCKET_NAME}" # .envから追加
    )

    [[ "$CREATE_SSM_ENDPOINT_VAL" == "false" ]] && PARAMS+=(SsmVpcEndpointId="${SSM_VPCE_ID_VAL}")
    [[ "$CREATE_SSM_ENDPOINT_VAL" == "false2" ]] && PARAMS[2]="CreateSsmInterfaceEndpoint=false"

    sam deploy \
      --stack-name "$STACK_NAME_VAL" \
      --template-file "./logonlogoff_lambda_template.yaml" \
      --region "${REGION:-ap-northeast-1}" \
      --profile "${PROFILE:-default}" \
      --parameter-overrides "${PARAMS[@]}"
    ;;
  delete)
    sam delete \
      --stack-name "$LAMBDA_STACK_NAME" \
      --no-prompts \
      --region "${REGION:-ap-northeast-1}" \
      --profile "${PROFILE:-default}"
    ;;
  *)
    usage
    exit 1
    ;;
esac