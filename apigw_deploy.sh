#!/usr/bin/env bash
set -euo pipefail

# 既存Lambdaポリシー有無確認と追加用ステートメントID
ensure_lambda_permission() {
  # 既存の許可ポリシーがある場合はスキップ（ResourceConflict避）
  if aws lambda get-policy \
       --function-name "$FUNCTIONNAME" \
       --profile "$PROFILE" \
       --region "$REGION" \
       --no-cli-pager 2>/dev/null | grep -q "\"Sid\":\"$STATEMENT_ID\""; then
    echo "Lambda permission '$STATEMENT_ID' already exists. Skipping add-permission."
    return 0
  fi

  aws lambda add-permission \
    --function-name "$FUNCTIONNAME" \
    --statement-id "$STATEMENT_ID" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --profile "$PROFILE" \
    --region "$REGION" \
    --no-cli-pager || echo "add-permission skipped (likely already exists)"
}

# API Gatewayデプロイ
deploy_apigateway() {
  ensure_lambda_permission
  # IPセグメント取得(xxx.xxx.xxx.xxx/xx,xxx.xxx.xxx.xxx/xx,xxx.xxx.xxx.xxx/xx)
  # IPセグメントはスペース/カンマ区切り両対応でカンマに正規化
  # IPの数は最大3つまで対応
  NORMALIZED_SEGMENTS=$(echo "$IPSEGMENT" | tr ' ' ',' | tr -s ',')
  IFS=',' read -r CIDR1 CIDR2 CIDR3 _ <<< "$NORMALIZED_SEGMENTS"

  EXECUTE_API_VPCE_CREATE_VAL="${EXECUTE_API_VPCE_CREATE:-true}"
  if [ "$EXECUTE_API_VPCE_CREATE_VAL" = "false" ] && [ -z "${EXECUTE_API_VPCE_ID:-}" ]; then
    echo "Error: EXECUTE_API_VPCE_CREATE=false の場合、EXECUTE_API_VPCE_ID(vpce-xxxx) が必要です" >&2
    exit 2
  fi

  PARAMS=(
    TargetLambdaArn="$TARGET_LAMBDA_ARN"
    VpcId="$VPCID"
    SubnetIds="$SUBNETIDS"
    ExecuteApiVpcEndpoint="$EXECUTE_API_VPCE_CREATE_VAL"
  )
  [ -n "${EXECUTE_API_VPCE_ID:-}" ] && PARAMS+=(VpcEndpointId="$EXECUTE_API_VPCE_ID")
  [ -n "${CLIENT_VPN_SG_ID:-}" ] && PARAMS+=(ClientSecurityGroupId="$CLIENT_VPN_SG_ID")
  [ -n "${CIDR1:-}" ] && PARAMS+=(ClientCidr1="$CIDR1")
  [ -n "${CIDR2:-}" ] && PARAMS+=(ClientCidr2="$CIDR2")
  [ -n "${CIDR3:-}" ] && PARAMS+=(ClientCidr3="$CIDR3")

  sam deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$API_TEMPLATE_PATH" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --parameter-overrides "${PARAMS[@]}"
}

# API Gateway削除
delete_apigateway() {
  sam delete --no-prompts --stack-name "$STACK_NAME" --region "$REGION"
}

if [ $# -lt 1 ]; then
  echo "Usage: $0 {deploy|delete} [additional sam args...]" >&2
  exit 1
fi

CMD=$1
shift || true

case "$CMD" in
  deploy)
    deploy_apigateway "$@"
    ;;
  delete)
    delete_apigateway "$@"
    ;;
  *)
    usage
    exit 1
    ;;
esac
