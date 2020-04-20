import boto3
import requests
import argparse

class AWSDynDns(object):
    def __init__(self, domain, record, hosted_zone_id, profile_name, ttl):
        self.ip_service = "http://httpbin.org/ip"
        session = boto3.Session(profile_name=profile_name)
        self.client = session.client('route53')
        self.domain = domain
        self.record = record
        self.ttl = int(ttl)
        self.hosted_zone_id = hosted_zone_id
        if self.record:
            self.fqdn = "{0}.{1}".format(self.record, self.domain)
        else:
            self.fqdn = self.domain
        print(f"Using full record name: {self.fqdn}")

    def get_external_ip(self):
        try:
            self.external_ip_request = requests.get(self.ip_service)
            if "," in self.external_ip_request.json()['origin']:
                self.external_ip = self.external_ip_request.json()['origin'].split(',')[0]
            else:
                self.external_ip = self.external_ip_request.json()['origin']
            print("Found external IP: {0}".format(self.external_ip))
        except Exception:
            raise Exception("error getting external IP")

    def get_hosted_zone_id(self):
        try:
            self.hosted_zone_list = self.client.list_hosted_zones_by_name()['HostedZones']
            for zone in self.hosted_zone_list:
                if self.domain in zone['Name']:
                    self.hosted_zone_id = zone['Id'].split('/')[2]
        except Exception:
            raise Exception("error getting hosted zone ID")

    def check_existing_record(self):
        """ Get current external IP address """
        self.get_external_ip()

        """ Check for existing record and if it needs to be modified """
        response = self.client.list_resource_record_sets(
            HostedZoneId=self.hosted_zone_id,
            StartRecordName=self.fqdn,
            StartRecordType='A',
        )

        found_flag = False

        if len(response['ResourceRecordSets']) == 0:
            return False
            #raise Exception("Could not find any records matching domain: {0}".format(self.domain))

        records = list([r for r in response['ResourceRecordSets'] if r['Name'] ==  self.fqdn])

        if len(records) == 1:
           return any(self.external_ip == ip['Value'] for ip in records[0]['ResourceRecords'])

        if len(records) == 0:
           return False

        print(f"unexpectedly got more than 1 record back for exact fqdn match: {records}")
        print(f"continuing presuming we need to update...")
        return False
        # only expecting 1 or 0 results back
        #if self.fqdn in response['ResourceRecordSets'][0]['Name']:
        #    for ip in response['ResourceRecordSets'][0]['ResourceRecords']:
        #        if self.external_ip == ip['Value']:
        #            found_flag = True
        #else:
        #    print(response)
        #    raise Exception("Cannot find record set for domain: {0}".format(self.fqdn))

        #return found_flag

    def update_record(self):
        if not self.hosted_zone_id:
            self.get_hosted_zone_id()

        if self.check_existing_record():
             print("IP is already up to date")
        else:
            print("Updating resource record IP address")
            response = self.client.change_resource_record_sets(
                HostedZoneId=self.hosted_zone_id,
                ChangeBatch={
                    'Comment': 'string',
                    'Changes': [
                        {
                            'Action': 'UPSERT',
                            'ResourceRecordSet': {
                                'Name': self.fqdn,
                                'Type': 'A',
                                'TTL': self.ttl,
                                'ResourceRecords': [
                                    {
                                        'Value': self.external_ip
                                    },
                                ],
                            }
                        },
                    ]
                }
            )
            print("Status: {}".format(response['ChangeInfo']['Status']))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Manage a dynamic home IP address with an AWS hosted route53 domain")

    parser.add_argument(
        "--profile","-p",
        default='ddns',
        help="AWS credential profile",
        required=False
    )

    parser.add_argument(
        "--domain", "-d",
        help="Domain to modify",
        required=True
    )

    parser.add_argument(
        "--record", "-r",
        help="Record to modify",
        required=False
    )

    parser.add_argument(
        "--zone", "-z",
        help="AWS hosted zone id",
        required=False
    )

    parser.add_argument(
        "--ttl",
        default=300,
        help="Record TTL",
        required=False
    )

    args = parser.parse_args()

    run = AWSDynDns(args.domain, args.record, args.zone, args.profile, args.ttl)
    run.update_record()
