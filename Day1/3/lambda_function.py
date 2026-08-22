import json
import boto3
import os
import base64
from datetime import datetime, timezone, timedelta
from collections import OrderedDict

kms_client = boto3.client('kms')
dynamodb = boto3.resource('dynamodb')

KST = timezone(timedelta(hours=9))

ENCRYPTED_TABLE_NAME = os.environ['TABLE_NAME']
TABLE_NAME = kms_client.decrypt(
    CiphertextBlob=base64.b64decode(ENCRYPTED_TABLE_NAME),
    EncryptionContext={'LambdaFunctionName': os.environ['AWS_LAMBDA_FUNCTION_NAME']}
)['Plaintext'].decode('utf-8')

GSI_NAME = os.environ.get('GSI_NAME', 'wsc2026-booking-gsi')

table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    qs = event.get('queryStringParameters') or {}
    booking_id = qs.get('booking_id')

    if not booking_id:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'booking_id is required'})
        }

    resp = table.query(
        IndexName=GSI_NAME,
        KeyConditionExpression='booking_id = :bid',
        ExpressionAttributeValues={':bid': booking_id}
    )

    items = resp.get('Items', [])
    if not items:
        return {
            'statusCode': 404,
            'body': json.dumps({'error': 'not found'})
        }

    item = items[0]

    created_at_raw = item.get('created_at', '')
    try:
        dt = datetime.fromisoformat(created_at_raw.replace('Z', '+00:00'))
        created_at = dt.astimezone(KST).strftime('%Y-%m-%d %H:%M:%S KST')
    except:
        created_at = created_at_raw

    result = OrderedDict([
        ('client_id', item.get('client_id', '')),
        ('username', item.get('username', '')),
        ('email', item.get('email', '')),
        ('concert_name', item.get('concert_name', '')),
        ('created_at', created_at)
    ])

    return {
        'statusCode': 200,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps(result)
    }
