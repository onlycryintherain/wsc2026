import base64
import json
import os
from datetime import datetime, timezone

import boto3


s3 = boto3.client("s3", region_name="ap-northeast-1")

# Bucket name contains the contestant-specific number and remains configurable.
S3_BUCKET = os.environ["S3_BUCKET"]


def decode_record(record):
    value = record.get("value", "")
    return json.loads(base64.b64decode(value).decode("utf-8"))


def consumer_handler(event, context):
    for records in event.get("records", {}).values():
        for record in records:
            data = decode_record(record)
            sensor_id = data["sensorId"]
            timestamp = data["timestamp"]

            safe_timestamp = timestamp.replace(":", "-").replace("+", "_")
            key = (
                f"alert/{sensor_id}/"
                f"{datetime.now(timezone.utc).strftime('%Y-%m-%d')}/"
                f"{safe_timestamp}.json"
            )
            s3.put_object(
                Bucket=S3_BUCKET,
                Key=key,
                Body=json.dumps(data, ensure_ascii=False).encode("utf-8"),
                ContentType="application/json",
            )

    return {"statusCode": 200, "body": "processed"}
