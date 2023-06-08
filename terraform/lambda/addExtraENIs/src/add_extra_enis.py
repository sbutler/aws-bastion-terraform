"""
Add extra ENIs to a bastion host. Meant to be triggered when the host
sends an event on EventBridge where enough components have successfully
initialized.
"""
import json
import logging
import os

import boto3 #pylint: disable=import-error

EXTRA_ENI_CONFIGS = json.loads(os.environ['EXTRA_ENI_CONFIGS'])
EXTRA_ENI_SECURITY_GROUP_IDS = json.loads(os.environ['EXTRA_ENI_SECURITY_GROUP_IDS'])
EXTRA_ENI_TAGS = [
    {'Key': k, 'Value': v}
    for k, v in json.loads(
        os.environ['EXTRA_ENI_TAGS'] if os.environ.get('EXTRA_ENI_TAGS') else '{}'
    ).items()
]

LOGGING_LEVEL = getattr(
    logging,
    os.environ['LOGGING_LEVEL'] if os.environ.get('LOGGING_LEVEL') else 'INFO',
    logging.INFO
)

logger = logging.getLogger(__name__)
logger.setLevel(LOGGING_LEVEL)

ec2_clnt = boto3.client('ec2')

def get_instance_region(instance_id):
    """
    Gets the region that an instance launched in.

    Args:
        instance_id (str): ID of the instance.
    Returns:
        str: Name of the region.
    """
    resp = ec2_clnt.describe_instances(InstanceIds=[instance_id])
    reservations = resp.get('Reservations', [])
    if not reservations:
        raise ValueError('No reservations')
    instances = reservations[0].get('Instances', [])
    if not instances:
        raise ValueError('No instances')

    return instances[0]['Placement']['AvailabilityZone']

def add_extra_eni(instance_id, region_name, config_idx, config):
    """
    Adds an extra ENI to an instance in the specified subnet. This interface
    will be configured (if possible) to delete when the instance is terminated.

    Args:
        instance_id (str): ID of the instance.
        region_name (str): Name of the region the instance is in.
        config_idx (int): Index of the ENI config in our settings.
        config (dict): Configuration of the ENI.

    Returns:
        str: the ENI ID.
    """
    subnet_id = config['subnet_ids'][region_name]

    description = config.get('description')
    if not description:
        description = 'Extra ENI for the bastion host connectivity.'

    logger.debug('Creating ENI in %(subnet)s', {'subnet': subnet_id})
    resp = ec2_clnt.create_network_interface(
        Description=description,
        SubnetId=subnet_id,
        Groups=EXTRA_ENI_SECURITY_GROUP_IDS,
        TagSpecifications=[{
            'ResourceType': 'network-interface',
            'Tags': EXTRA_ENI_TAGS,
        }]
    )
    eni_id = resp['NetworkInterface']['NetworkInterfaceId']
    logger.debug('[ENI:%(eni)s] Created successfully', {'eni': eni_id})

    try:
        logger.debug('[ENI:%(eni)s] Attaching to instance %(instance)s', {
            'eni': eni_id,
            'instance': instance_id,
        })
        resp = ec2_clnt.attach_network_interface(
            DeviceIndex=(config_idx + 1),
            InstanceId=instance_id,
            NetworkInterfaceId=eni_id,
            NetworkCardIndex=config_idx,
        )
    except Exception: #pylint: disable=broad-except
        # Cleanup the ENI and re-raise
        ec2_clnt.delete_network_interface(NetworkInterfaceId=eni_id)
        raise

    attachment_id = resp['AttachmentId']
    logger.debug('ENI %(eni)s attached: %(attachment)s', {
        'eni': eni_id,
        'attachment': attachment_id,
    })

    try:
        logger.debug('[ENI:%(eni)s] Setting delete on instance terminate', {'eni': eni_id})
        resp = ec2_clnt.modify_network_interface_attribute(
            Attachment={
                'AttachmentId': attachment_id,
                'DeleteOnTermination': True,
            },
            NetworkInterfaceId=eni_id,
        )
    except Exception: #pylint: disable=broad-except
        logger.exception(
            '[ENI:%(eni)s] Failed to set delete on instance terminate; ignoring',
            {'eni': eni_id}
        )

    return eni_id

def lambda_handler(event, context):
    """
    Get the instance ID from the event (if it is a Bastion Initialization
    Status) and adds the extra ENIs to the instance. This does not do any
    checks that the event signals the instance is ready; it is expected the
    EventBridge Rule will only trigger the lambda when the instance reaches
    the correct status.

    Args:
        event (dict): event data.
        context (obj): Lambda context.

    Returns:
        List[str]: List of ENI IDs.
    """
    # pylint: disable=unused-argument
    logger.debug('Triggered by event: %(event)r', {'event': event})

    event_source = event.get('source')
    if event_source != 'bastion.aws.illinois.edu':
        logger.error('Unknown event source: %(source)r', {'source': event_source})
        return []

    event_detail_type = event.get('detail-type')
    if event_detail_type != 'Bastion Initialization Status':
        logger.error('Unknown event detailType: %(type)r', {'type': event_detail_type})
        return []

    event_detail = event.get('detail', {})
    instance_id = event_detail.get('instanceID')
    if not instance_id:
        logger.error('No instanceID in the event detail')
        return []

    region_name = get_instance_region(instance_id)
    extra_eni_ids = []
    for config_idx, config in enumerate(EXTRA_ENI_CONFIGS):
        logger.debug('ENI Config #%(idx)d: %(config)r', {
            'idx': config_idx,
            'config': config,
        })
        try:
            eni_id = add_extra_eni(instance_id, region_name, config_idx, config)
        except Exception: #pylint: disable=broad-except
            logger.exception('Unable to create ENI #%(idx)d', {'idx': config_idx})
        else:
            extra_eni_ids.append(eni_id)

    return extra_eni_ids
