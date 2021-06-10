"""
Associate an EIP with a bastion host. Meant to be triggered when the host
sends an event on EventBridge where enough components have successfully
initialized.
"""
import logging
import os

import boto3 #pylint: disable=import-error

EIP_ALLOCATION_ID = os.environ['EIP_ALLOCATION_ID']
LOGGING_LEVEL = getattr(
    logging,
    os.environ['LOGGING_LEVEL'] if os.environ.get('LOGGING_LEVEL') else 'INFO',
    logging.INFO
)

logger = logging.getLogger(__name__)
logger.setLevel(LOGGING_LEVEL)

ec2_clnt = boto3.client('ec2')

def lambda_handler(event, context):
    """
    Get the instance ID from the event (if it is a Bastion Initialization
    Status) and associate the EIP with the instance. This does not do any
    checks that the event signals the instance is ready; it is expected the
    EventBridge Rule will only trigger the lambda when the instance reaches
    the correct status.

    Args:
        event (dict): event data.
        context (obj): Lambda context.
    """
    logger.debug('Triggered by event: %(event)r', {'event': event})

    event_source = event.get('source')
    if event_source != 'bastion.aws.illinois.edu':
        logger.error('Unknown event source: %(source)r', {'source': event_source})
        return

    event_detailType = event.get('detail-type')
    if event_detailType != 'Bastion Initialization Status':
        logger.error('Unknown event detailType: %(type)r', {'type': event_detailType})
        return

    event_detail = event.get('detail', {})
    instance_id = event_detail.get('instanceID')
    if not instance_id:
        logger.error('No instanceID in the event detail')
        return

    logger.info('Associating %(allocation_id)s to %(instance_id)s', {
        'allocation_id': EIP_ALLOCATION_ID,
        'instance_id': instance_id,
    })
    resp = ec2_clnt.associate_address(
        AllocationId=EIP_ALLOCATION_ID,
        InstanceId=instance_id,
        AllowReassociation=True
    )
    logger.debug('Association ID: %(association_id)s', {'association_id': resp['AssociationId']})

    return resp['AssociationId']
