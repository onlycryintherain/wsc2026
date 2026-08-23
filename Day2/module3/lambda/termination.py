import json
import os
from datetime import datetime, timezone

import boto3


ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
INSTANCE_ID = os.environ["INSTANCE_ID"]


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def handler(event, context):
    print(json.dumps(event))

    request = event.get("detail", {}).get("requestParameters", {})
    event_instance_id = request.get("instanceId")

    if event_instance_id and event_instance_id != INSTANCE_ID:
        return {"statusCode": 200, "body": "ignored"}

    response = ec2.describe_instance_attribute(
        InstanceId=INSTANCE_ID,
        Attribute="disableApiTermination"
    )
    enabled = response.get("DisableApiTermination", {}).get("Value", False)

    if enabled:
        return {"statusCode": 200, "body": "already compliant"}

    ec2.modify_instance_attribute(
        InstanceId=INSTANCE_ID,
        DisableApiTermination={"Value": True}
    )

    message = {
        "event": "TERMINATION_PROTECTION_DISABLED",
        "timestamp": now(),
        "detail": f"Termination protection restored on {INSTANCE_ID}",
        "action": "RESTORED"
    }
    sns_response = sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="EC2 termination protection restored",
        Message=json.dumps(message)
    )
    print(json.dumps({"sns_publish": True, "function": "wsc2026-termination-protection-remediation", "topic": SNS_TOPIC_ARN}, ensure_ascii=False))
    print(json.dumps({"snsMessageId": sns_response["MessageId"], "message": message}))
    return {"statusCode": 200, "body": "completed"}