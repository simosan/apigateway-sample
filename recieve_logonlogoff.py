import boto3
import json
import datetime
import re


def compute_base_date_str(timestamp_str: str) -> str:
    """
    与えられたタイムスタンプ(YYYY-MM-DD HH:MM:SS)から基準日を算出し、yyyyMMddを返す。
    ルール:
      - 当日AM5:00を基準に、AM5:00〜翌AM4:59:59を同一基準日とする。
      - AM5:00未満なら前日を基準日とする。
    例:
      2025-01-01 05:00:00 -> 20250101
      2025-01-02 04:59:00 -> 20250101
      2025-01-01 04:59:00 -> 20241231
    """
    dt = datetime.datetime.strptime(timestamp_str, "%Y-%m-%d %H:%M:%S")
    boundary = datetime.time(5, 0, 0)
    if dt.time() < boundary:
        base_date = dt.date() - datetime.timedelta(days=1)
    else:
        base_date = dt.date()
    return base_date.strftime("%Y%m%d")


def get_bucket_name(ssm_client) -> str:
    """SSMまたは環境変数からS3バケット名を取得する。"""
    # SSM Parameter Storeから取得
    resp = ssm_client.get_parameter(Name='/logonlogoff/s3bucket', WithDecryption=False)
    return resp['Parameter']['Value']


def get_prefix(ssm_client) -> str:
    """S3キーの先頭プレフィックスを取得する"""
    resp = ssm_client.get_parameter(Name='/logonlogoff/prefixkey', WithDecryption=False)
    return resp['Parameter']['Value']


def parse_event_payload(event: dict) -> dict:
    """API Gateway/Lambdaイベントからペイロードを辞書で返す。"""
    if event is None:
        return {}
    # API Gateway経由でのJSON抽出
    body = event.get('body')
    if isinstance(body, str):
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            # bodyがJSONでない場合はそのまま無視してeventトップレベルを使う
            pass
    # Debug用: 直接eventから取得
    return {
        'type': event.get('type'),
        'userid': event.get('userid'),
        'timestamp': event.get('timestamp'),
    }


def recieve_logonlogoff(event, context):

    # boto3クライアント（ローカルDRY_RUN時は未インストールでも動作可能）
    s3 = boto3.client('s3')
    ssm = boto3.client('ssm')

    payload = parse_event_payload(event)
    log_type = payload.get('type')
    userid = payload.get('userid')
    timestamp = payload.get('timestamp')

    # 入力検証
    missing = [k for k in ("type", "userid", "timestamp") if payload.get(k) in (None, "")]
    if missing:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "missing required fields",
                "missing": missing,
            }),
        }

    # type: 'logon' or 'logoff' のみ
    if str(log_type) not in ("logon", "logoff"):
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "invalid type",
                "allowed": ["logon", "logoff"],
                "value": log_type,
            }),
        }

    # userid: 英数字のみ、15バイト以下
    if not isinstance(userid, str):
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "invalid userid type",
                "expected": "string",
                "value": userid,
            }),
        }

    if not re.fullmatch(r"[A-Za-z0-9]{1,15}", userid or ""):
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "invalid userid",
                "rule": "alphanumeric only, length <= 15",
                "value": userid,
            }),
        }

    if len(userid.encode("utf-8")) > 15:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "invalid userid length",
                "rule": "<= 15 bytes",
                "value": userid,
            }),
        }

    # timestamp: YYYY-MM-DD HH:MM:SS の形式
    if not isinstance(timestamp, str):
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "invalid timestamp type",
                "expected": "string",
                "value": timestamp,
            }),
        }

    # 形式チェック(正規表現) + 実際のパース
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", timestamp):
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "invalid timestamp format",
                "expected": "YYYY-MM-DD HH:MM:SS",
                "value": timestamp,
            }),
        }

    try:
        date_str = compute_base_date_str(timestamp)
    except Exception as e:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "message": "invalid timestamp value",
                "expected": "YYYY-MM-DD HH:MM:SS",
                "error": str(e),
            }),
        }

    # S3キー生成: <prefix>/date=yyyyMMdd/<userid>_<type>_<timestamp>.json
    prefix = get_prefix(ssm)
    # ファイル名用にタイムスタンプを変換
    safe_ts = timestamp.replace(' ', 'T').replace(':', '-')
    object_key = f"{prefix}/date={date_str}/{userid}_{log_type}_{safe_ts}.json"

    # 保存データ
    data = {
        "userid": str(userid),
        "type": str(log_type),
        "timestamp": str(timestamp),
    }

    # バケット名取得
    bucket_name = get_bucket_name(ssm)

    try:
        # S3へ保存
        s3.put_object(
            Bucket=bucket_name,
            Key=object_key,
            Body=json.dumps(data, ensure_ascii=False).encode('cp932'),
            ContentType='application/json; charset=cp932'
        )
    except Exception as e:
        return {
            "statusCode": 500,
            "body": json.dumps({
                "message": "failed to put object to S3",

                "error": str(e),
            }),
        }

    return {
        "statusCode": 200,
        "body": json.dumps({
            "bucket": bucket_name,
            "key": object_key,
            "date": date_str,
        }, ensure_ascii=False),
    }
