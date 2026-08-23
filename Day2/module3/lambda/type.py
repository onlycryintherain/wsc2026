import json
import os
from datetime import datetime, timezone

import boto3


ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
EXPECTED_INSTANCE_TYPE = os.environ.get("EXPECTED_INSTANCE_TYPE", "t3.micro")


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def handler(event, context):
    print(json.dumps(event))

    instance = ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"][0]["Instances"][0]
    current_type = instance["InstanceType"]
    state = instance["State"]["Name"]

    if current_type == EXPECTED_INSTANCE_TYPE:
        # Idempotent recovery: keep the approved instance running as well.
        if state != "running":
            ec2.start_instances(InstanceIds=[INSTANCE_ID])
        message = {
            "event": "EC2_INSTANCE_TYPE_CHANGED",
            "timestamp": now(),
            "detail": f"Instance type is compliant on {INSTANCE_ID}",
            "action": "VERIFIED"
        }
        response = sns.publish(TopicArn=SNS_TOPIC_ARN, Subject="EC2 type remediation", Message=json.dumps(message))
        print(json.dumps({"sns_publish": True, "function": "wsc2026-ec2-type-remediation", "snsMessageId": response["MessageId"]}))
        return {"statusCode": 200, "body": "already compliant"}

    if state != "stopped":
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        ec2.get_waiter("instance_stopped").wait(InstanceIds=[INSTANCE_ID])

    ec2.modify_instance_attribute(
        InstanceId=INSTANCE_ID,
        InstanceType={"Value": EXPECTED_INSTANCE_TYPE}
    )

    # 복구 후 인스턴스는 항상 running 상태로 유지합니다.
    ec2.start_instances(InstanceIds=[INSTANCE_ID])

    message = {
        "event": "EC2_INSTANCE_TYPE_CHANGED",
        "timestamp": now(),
        "detail": f"Instance type restored from {current_type} to {EXPECTED_INSTANCE_TYPE} on {INSTANCE_ID}",
        "action": "RESTORED"
    }
    response = sns.publish(TopicArn=SNS_TOPIC_ARN, Subject="EC2 type remediation", Message=json.dumps(message))
    print(json.dumps({"sns_publish": True, "snsMessageId": response["MessageId"], "message": message}))
    return {"statusCode": 200, "body": "completed"}