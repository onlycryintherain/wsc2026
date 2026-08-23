import csv
import io
import json
import os
import re
from datetime import datetime, timezone
from decimal import Decimal

import boto3

# test.csv has 'history' field instead of 'social'
REQUIRED_FIELDS = ["examDate", "studentId", "name", "className", "korean", "english", "math", "science", "history"]
SCORE_FIELDS = ["korean", "english", "math", "science", "history"]

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


def validate_row(row):
    for field in REQUIRED_FIELDS:
        if not (row.get(field) or "").strip():
            return "MISSING_FIELD"

    exam_date = row.get("examDate", "").strip()
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", exam_date):
        return "INVALID_DATE"
    try:
        datetime.strptime(exam_date, "%Y-%m-%d")
    except ValueError:
        return "INVALID_DATE"

    for field in SCORE_FIELDS:
        value = row.get(field, "").strip()
        if not value.lstrip("+-").isdigit():
            return "INVALID_FORMAT"
        score = int(value)
        if score < 0 or score > 100:
            return "INVALID_SCORE"

    return None


def save_error(bucket, row, error_reason, timestamp):
    student_id = (row.get("studentId") or "unknown").strip()
    error_key = f"error/error_{timestamp}_{student_id}.json"

    body = {
        "studentId": student_id,
        "examDate": (row.get("examDate") or "").strip(),
        "error_reason": error_reason,
        "raw_data": {k: (v or "").strip() for k, v in row.items()},
    }

    s3_client.put_object(
        Bucket=bucket,
        Key=error_key,
        Body=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json; charset=utf-8",
    )


def calculate_grade(average):
    if average >= 90:
        return "A"
    elif average >= 80:
        return "B"
    elif average >= 70:
        return "C"
    elif average >= 60:
        return "D"
    else:
        return "F"


def save_student(table, row):
    scores = [int(row.get(f, "0").strip()) for f in SCORE_FIELDS]
    average = sum(scores) / len(scores)
    grade = calculate_grade(average)
    
    table.put_item(
        Item={
            "studentId": row.get("studentId", "").strip(),
            "examDate": row.get("examDate", "").strip(),
            "name": row.get("name", "").strip(),
            "className": row.get("className", "").strip(),
            "korean": int(row.get("korean", "0").strip()),
            "english": int(row.get("english", "0").strip()),
            "math": int(row.get("math", "0").strip()),
            "science": int(row.get("science", "0").strip()),
            "history": int(row.get("history", "0").strip()),
            "average": Decimal(str(round(average, 2))),
            "grade": grade,
            "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
    )


def handler(event, context):
    bucket = os.environ.get("S3_BUCKET")
    table_name = os.environ.get("DDB_TABLE")

    if not bucket or not table_name:
        return {"statusCode": 400, "processed": 0, "errors": 0}

    key = event.get("key")
    if not key or not key.startswith("input/"):
        return {"statusCode": 400, "processed": 0, "errors": 0}

    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        csv_text = response["Body"].read().decode("utf-8")
    except Exception:
        return {"statusCode": 400, "processed": 0, "errors": 0}

    reader = csv.DictReader(io.StringIO(csv_text))
    rows = list(reader)

    table = dynamodb.Table(table_name)
    processed = 0
    errors = 0
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    processed_records = []

    for row in rows:
        error_reason = validate_row(row)
        if error_reason:
            save_error(bucket, row, error_reason, timestamp)
            errors += 1
        else:
            save_student(table, row)
            scores = [int(row.get(f, "0").strip()) for f in SCORE_FIELDS]
            average = sum(scores) / len(scores)
            grade = calculate_grade(average)
            processed_records.append({
                "studentId": row.get("studentId", "").strip(),
                "examDate": row.get("examDate", "").strip(),
                "name": row.get("name", "").strip(),
                "className": row.get("className", "").strip(),
                "korean": int(row.get("korean", "0").strip()),
                "english": int(row.get("english", "0").strip()),
                "math": int(row.get("math", "0").strip()),
                "science": int(row.get("science", "0").strip()),
                "history": int(row.get("history", "0").strip()),
                "average": round(average, 2),
                "grade": grade,
            })
            processed += 1

    # Save processed results to processed/ folder
    if processed_records:
        filename = os.path.basename(key).replace(".csv", "")
        processed_key = f"processed/{filename}_{timestamp}.json"
        s3_client.put_object(
            Bucket=bucket,
            Key=processed_key,
            Body=json.dumps(processed_records, ensure_ascii=False).encode("utf-8"),
            ContentType="application/json; charset=utf-8",
        )

    return {"statusCode": 200, "processed": processed, "errors": errors}
