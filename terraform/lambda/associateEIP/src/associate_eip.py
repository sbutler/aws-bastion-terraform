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

def get_instance_primary_interface(instance_id):
    """
    Get the primary ENI of the instance (the one with device index 0).

    Args:
        instance_id (str): instance ID.

    Returns:
        str: ENI ID.
    """
    logger.debug('Getting primary network interface for %(instance)s', {
        'instance': instance_id,
    })
    resp = ec2_clnt.describe_network_interfaces(
        Filters=[
            {
                'Name': 'attachment.instance-id',
                'Values': [ instance_id ]
            },
            {
                'Name': 'attachment.device-index',
                'Values': [ '0' ]
            }
        ]
    )
    interfaces = resp.get('NetworkInterfaces', [])
    if not interfaces:
        raise ValueError('Unable to get instance primary network interface')
    if len(interfaces) > 1:
        logger.warning('Found multiple matching interfaces: %(data)r', {'data': interfaces})

    return interfaces[0]['NetworkInterfaceId']

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
    # pylint: disable=unused-argument
    logger.debug('Triggered by event: %(event)r', {'event': event})

    event_source = event.get('source')
    if event_source != 'bastion.aws.illinois.edu':
        logger.error('Unknown event source: %(source)r', {'source': event_source})
        return None

    event_detail_type = event.get('detail-type')
    if event_detail_type != 'Bastion Initialization Status':
        logger.error('Unknown event detailType: %(type)r', {'type': event_detail_type})
        return None

    event_detail = event.get('detail', {})
    instance_id = event_detail.get('instanceID')
    if not instance_id:
        logger.error('No instanceID in the event detail')
        return None

    eni_id = get_instance_primary_interface(instance_id)
    logger.info('Associating %(allocation_id)s to ENI %(eni_id)s', {
        'allocation_id': EIP_ALLOCATION_ID,
        'eni_id': eni_id,
    })
    resp = ec2_clnt.associate_address(
        AllocationId=EIP_ALLOCATION_ID,
        NetworkInterfaceId=eni_id,
        AllowReassociation=True
    )
    logger.debug('Association ID: %(association_id)s', {'association_id': resp['AssociationId']})

    return resp['AssociationId']
