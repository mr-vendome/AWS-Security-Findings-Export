import os
import json
import gzip
import logging
from datetime import datetime
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client('s3')
sh_client = boto3.client('securityhub')

def lambda_handler(event: dict, context: object) -> dict:
    """
    AWS Lambda handler to fetch active CSPM findings from Security Hub 
    and export them to an S3 bucket in compressed JSON Lines format.
    Runtime: Python 3.13
    """
    bucket_name: str | None = os.environ.get('S3_BUCKET_NAME')
    if not bucket_name:
        logger.error("Missing mandatory environment variable: S3_BUCKET_NAME")
        return {"statusCode": 500, "body": "Configuration error: S3_BUCKET_NAME missing."}

    logger.info("Initiating AWS Security Hub CSPM findings export pipeline.")
    
    filters: dict = {
        'RecordState': [{'Value': 'ACTIVE', 'Comparison': 'EQUALS'}],
        'WorkflowStatus': [{'Value': 'SUPPRESSED', 'Comparison': 'NOT_EQUALS'}],
        'GeneratorId': [{'Value': 'security-hub', 'Comparison': 'PREFIX'}]
    }

    findings_buffer: list[str] = []
    
    try:
        paginator = sh_client.get_paginator('get_findings')
        page_iterator = paginator.paginate(Filters=filters)
        
        for page in page_iterator:
            findings = page.get('Findings', [])
            for finding in findings:
                findings_buffer.append(json.dumps(finding))
                
        total_findings: int = len(findings_buffer)
        logger.info(f"Successfully retrieved {total_findings} active CSPM findings.")
        
        if total_findings == 0:
            logger.info("No active findings found matching the criteria. Skipping S3 upload.")
            return {"statusCode": 200, "body": "No findings to export."}

        payload_data: bytes = "\n".join(findings_buffer).encode('utf-8')
        compressed_payload: bytes = gzip.compress(payload_data)
        
        now: datetime = datetime.utcnow()
        timestamp: str = now.strftime("%Y%m%d_%H%M%SZ")
        s3_key: str = f"securityhub/{now.strftime('%Y/%m/%d')}/cspm_findings_{timestamp}.jsonl.gz"
        
        logger.info(f"Uploading compressed artifact to s3://{bucket_name}/{s3_key}")
        s3_client.put_object(
            Bucket=bucket_name,
            Key=s3_key,
            Body=compressed_payload,
            ContentType='application/x-gzip'
        )
        
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Export completed successfully.",
                "s3_path": f"s3://{bucket_name}/{s3_key}",
                "records_exported": total_findings
            })
        }

    except ClientError as e:
        logger.error(f"AWS API Transaction Error: {e.response['Error']['Message']}", exc_info=True)
        raise e
    except Exception as e:
        logger.critical(f"Unhandled operational failure: {str(e)}", exc_info=True)
        raise e
