import json
import boto3
import os
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['TABLE_NAME'])

def handler(event, context):
    params = event.get('queryStringParameters') or {}
    booking_id = params.get('booking_id')
    
    if not booking_id:
        return {'statusCode': 400, 'body': json.dumps({'error': 'booking_id is required'})}
    
    # Get item by booking_id
    response = table.get_item(Key={'booking_id': booking_id})
    item = response.get('Item')
    
    if not item:
        return {'statusCode': 404, 'body': json.dumps({'error': 'Not found'})}
    
    # Check optional filters
    email = params.get('email')
    concert_name = params.get('concert_name')
    
    if email and item.get('email') != email:
        return {'statusCode': 404, 'body': json.dumps({'error': 'Not found'})}
    if concert_name and item.get('concert_name') != concert_name:
        return {'statusCode': 404, 'body': json.dumps({'error': 'Not found'})}
    
    return {
        'statusCode': 200,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps(item)
    }
