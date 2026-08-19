import json
import os
from datetime import datetime, timezone, timedelta
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key


table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
index_name = os.environ.get("INDEX_NAME", "concert_name-created_at-index")

KST = timezone(timedelta(hours=9))


class DecimalEncoder(json.JSONEncoder):
    def default(self, value):
        if isinstance(value, Decimal):
            return int(value) if value % 1 == 0 else float(value)
        return super().default(value)


def to_kst(timestamp_str):
    """Convert timestamp string to KST (+09:00) format."""
    try:
        # Try ISO format with Z suffix (UTC)
        if timestamp_str.endswith("Z"):
            dt = datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
        else:
            dt = datetime.fromisoformat(timestamp_str)
        dt_kst = dt.astimezone(KST)
        return dt_kst.isoformat()
    except (ValueError, AttributeError):
        return timestamp_str


STATUS_DESCRIPTIONS = {
    200: "200 OK",
    400: "400 Bad Request",
    500: "500 Internal Server Error",
}


def response(status_code, body):
    return {
        "statusCode": status_code,
        "statusDescription": STATUS_DESCRIPTIONS.get(status_code, f"{status_code}"),
        "isBase64Encoded": False,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False, cls=DecimalEncoder),
    }


def handler(event, context):
    params = event.get("queryStringParameters") or {}
    concert_name = params.get("concert_name")

    if not concert_name:
        return response(400, {"message": "concert_name is required"})

    result = table.query(
        IndexName=index_name,
        KeyConditionExpression=Key("concert_name").eq(concert_name),
        ScanIndexForward=False,
    )

    KEY_ORDER = ["username", "created_at", "email", "booking_id", "client_id", "concert_name"]
    items = []
    for item in result.get("Items", []):
        ordered = {}
        for k in KEY_ORDER:
            if k in item:
                ordered[k] = to_kst(item[k]) if k == "created_at" else item[k]
        items.append(ordered)
    return response(200, items)
