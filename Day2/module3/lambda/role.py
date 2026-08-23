import json
import os
from datetime import datetime, timezone

import boto3


ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
INSTANCE_PROFILE_NAME = os.environ["INSTANCE_PROFILE_NAME"]


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def handler(event, context):
    print(json.dumps(event))

    associations = ec2.describe_iam_instance_profile_associations(
        Filters=[{"Name": "instance-id", "Values": [INSTANCE_ID]}, {"Name": "state", "Values": ["associated"]}]
    ).get("IamInstanceProfileAssociations", [])

    if associations:
        association = associations[0]
        current_arn = association.get("IamInstanceProfile", {}).get("Arn", "")
        if current_arn.endswith("/" + INSTANCE_PROFILE_NAME):
            message = {
                "event": "IAM_INSTANCE_PROFILE_CHANGED",
                "timestamp": now(),
                "detail": f"IAM instance profile is compliant on {INSTANCE_ID}",
                "action": "VERIFIED"
            }
            response = sns.publish(TopicArn=SNS_TOPIC_ARN, Subject="IAM role remediation", Message=json.dumps(message))
            print(json.dumps({"sns_publish": True, "function": "wsc2026-role-remediation", "snsMessageId": response["MessageId"]}))
            return {"statusCode": 200, "body": "already compliant"}

        ec2.replace_iam_instance_profile_association(
            IamInstanceProfile={"Name": INSTANCE_PROFILE_NAME},
            AssociationId=association["AssociationId"]
        )
    else:
        ec2.associate_iam_instance_profile(
            IamInstanceProfile={"Name": INSTANCE_PROFILE_NAME},
            InstanceId=INSTANCE_ID
        )

    message = {
        "event": "IAM_INSTANCE_PROFILE_CHANGED",
        "timestamp": now(),
        "detail": f"IAM instance profile restored on {INSTANCE_ID}",
        "action": "RESTORED"
    }
    response = sns.publish(TopicArn=SNS_TOPIC_ARN, Subject="IAM role remediation", Message=json.dumps(message))
    print(json.dumps({"sns_publish": True, "function": "wsc2026-role-remediation", "topic": SNS_TOPIC_ARN}, ensure_ascii=False))
    print(json.dumps({"snsMessageId": response["MessageId"], "message": message}))
    return {"statusCode": 200, "body": "completed"}