import json
import os
import boto3

stepfunctions = boto3.client('stepfunctions')

STATE_MACHINE_ARN = os.environ.get('STATE_MACHINE_ARN')

def handler(event, context):
    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        
        if not key.endswith('.csv'):
            continue
        
        stepfunctions.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            input=json.dumps({'key': key})
        )
    
    return {'statusCode': 200}
