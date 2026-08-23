import json
import os
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError


ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]


def utc_timestamp() -> str:
    """현재 UTC 시간을 ISO 8601 형식으로 반환합니다."""
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def publish_alert(detail_message: str, action: str = "RESTORED") -> None:
    """정책 위반 처리 결과를 SNS Topic으로 발행합니다."""
    message = {
        "event": "SG_INBOUND_ADDED",
        "timestamp": utc_timestamp(),
        "detail": detail_message,
        "action": action,
    }

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="SG inbound rule policy violation",
        Message=json.dumps(message, ensure_ascii=False),
    )
    print(json.dumps({"sns_publish": True, "function": "wsc2026-sg-remediation", "topic": SNS_TOPIC_ARN}, ensure_ascii=False))


def convert_ip_permission(item: dict[str, Any]) -> dict[str, Any]:
    """
    CloudTrail의 ipPermissions.items 형식을
    revoke_security_group_ingress API 형식으로 변환합니다.
    """
    permission: dict[str, Any] = {
        "IpProtocol": item.get("ipProtocol", "-1")
    }

    if item.get("fromPort") is not None:
        permission["FromPort"] = int(item["fromPort"])

    if item.get("toPort") is not None:
        permission["ToPort"] = int(item["toPort"])

    ip_ranges = item.get("ipRanges", {}).get("items", [])
    if ip_ranges:
        permission["IpRanges"] = []

        for ip_range in ip_ranges:
            cidr_ip = ip_range.get("cidrIp")

            if not cidr_ip:
                continue

            converted_range = {
                "CidrIp": cidr_ip
            }

            if ip_range.get("description"):
                converted_range["Description"] = ip_range["description"]

            permission["IpRanges"].append(converted_range)

    ipv6_ranges = item.get("ipv6Ranges", {}).get("items", [])
    if ipv6_ranges:
        permission["Ipv6Ranges"] = []

        for ipv6_range in ipv6_ranges:
            cidr_ipv6 = ipv6_range.get("cidrIpv6")

            if not cidr_ipv6:
                continue

            converted_range = {
                "CidrIpv6": cidr_ipv6
            }

            if ipv6_range.get("description"):
                converted_range["Description"] = ipv6_range["description"]

            permission["Ipv6Ranges"].append(converted_range)

    prefix_lists = item.get("prefixListIds", {}).get("items", [])
    if prefix_lists:
        permission["PrefixListIds"] = []

        for prefix_list in prefix_lists:
            prefix_list_id = prefix_list.get("prefixListId")

            if not prefix_list_id:
                continue

            converted_prefix = {
                "PrefixListId": prefix_list_id
            }

            if prefix_list.get("description"):
                converted_prefix["Description"] = prefix_list["description"]

            permission["PrefixListIds"].append(converted_prefix)

    source_groups = item.get("groups", {}).get("items", [])
    if source_groups:
        permission["UserIdGroupPairs"] = []

        for source_group in source_groups:
            pair: dict[str, Any] = {}

            if source_group.get("userId"):
                pair["UserId"] = source_group["userId"]

            if source_group.get("groupId"):
                pair["GroupId"] = source_group["groupId"]

            if source_group.get("groupName"):
                pair["GroupName"] = source_group["groupName"]

            if source_group.get("vpcId"):
                pair["VpcId"] = source_group["vpcId"]

            if source_group.get("description"):
                pair["Description"] = source_group["description"]

            if pair:
                permission["UserIdGroupPairs"].append(pair)

    return permission


def is_default_http_rule(item: dict[str, Any]) -> bool:
    """
    기본 허용 정책인 TCP 80, 0.0.0.0/0 규칙인지 검사합니다.

    기본 규칙은 보안 그룹에 계속 유지해야 하므로,
    해당 규칙과 동일한 이벤트는 삭제 대상에서 제외합니다.
    """
    if item.get("ipProtocol") != "tcp":
        return False

    if item.get("fromPort") != 80 or item.get("toPort") != 80:
        return False

    ip_ranges = item.get("ipRanges", {}).get("items", [])
    cidr_values = {
        ip_range.get("cidrIp")
        for ip_range in ip_ranges
        if ip_range.get("cidrIp")
    }

    return cidr_values == {"0.0.0.0/0"}


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    AuthorizeSecurityGroupIngress 이벤트를 처리합니다.

    기본 HTTP 80 규칙은 유지하고,
    그 외 새로 추가된 인바운드 규칙만 삭제합니다.
    """
    print(json.dumps(event, ensure_ascii=False, default=str))

    detail = event.get("detail", {})
    request_parameters = detail.get("requestParameters", {})
    event_group_id = request_parameters.get("groupId")

    if event_group_id != SECURITY_GROUP_ID:
        print(
            f"Ignored security group. "
            f"Expected={SECURITY_GROUP_ID}, Received={event_group_id}"
        )

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Ignored because the event is not for the protected SG"
            }),
        }

    permission_items = (
        request_parameters
        .get("ipPermissions", {})
        .get("items", [])
    )

    if not permission_items:
        raise ValueError(
            "No inbound permissions were found in "
            "detail.requestParameters.ipPermissions.items"
        )

    unauthorized_items = [
        item
        for item in permission_items
        if not is_default_http_rule(item)
    ]

    if not unauthorized_items:
        print("Only the approved HTTP 80 rule was found.")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Approved HTTP 80 rule was preserved"
            }),
        }

    ip_permissions = [
        convert_ip_permission(item)
        for item in unauthorized_items
    ]

    try:
        ec2.revoke_security_group_ingress(
            GroupId=SECURITY_GROUP_ID,
            IpPermissions=ip_permissions,
        )

        removed_rules = json.dumps(
            unauthorized_items,
            ensure_ascii=False,
            default=str,
        )

        publish_alert(
            detail_message=(
                f"Unauthorized inbound rule removed from "
                f"{SECURITY_GROUP_ID}. Rules: {removed_rules}"
            )
        )

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Unauthorized inbound rule removed",
                "securityGroupId": SECURITY_GROUP_ID,
            }),
        }

    except ClientError as error:
        error_code = error.response.get("Error", {}).get("Code", "Unknown")
        error_message = error.response.get("Error", {}).get(
            "Message",
            str(error),
        )

        # EventBridge의 중복 전달 등으로 이미 규칙이 삭제된 경우
        if error_code == "InvalidPermission.NotFound":
            publish_alert(
                detail_message=(
                    f"Unauthorized inbound rule was already absent from "
                    f"{SECURITY_GROUP_ID}"
                )
            )

            return {
                "statusCode": 200,
                "body": json.dumps({
                    "message": "Rule was already removed"
                }),
            }

        print(
            f"Failed to revoke ingress rule. "
            f"Code={error_code}, Message={error_message}"
        )
        raise