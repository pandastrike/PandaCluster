#===============================================================================
# panda-cluster - CloudFormation Template Construction - Security Groups
#===============================================================================
# This file adds configuration details to the CloudFormation template related
# to a Security Group.  This specifies port access to the cluster.

module.exports =
  add: (template) ->
    # Isolate the "Resources" object within the template.
    resources = template.Resources

    # We need start over to accomodate the VPC we've created.  So, delete the
    # current Security Group configuration.
    delete resources.CoreOSSecurityGroup
    delete resources.Ingress4001
    delete resources.Ingress7001

    # Expose the following ports...
    resources["ClusterSecurityGroup"] =
      Type: "AWS::EC2::SecurityGroup"
      Properties:
        GroupDescription: "Huxley SecurityGroup"
        VpcId: {Ref: "VPC"}
        SecurityGroupIngress: [
          { # SSH Exposed to the public Internet
            IpProtocol: "tcp"
            FromPort: "22"
            ToPort: "22"
            CidrIp: "0.0.0.0/0"
          }
          { # HTTP Exposed to the public Internet
            IpProtocol: "tcp"
            FromPort: "80"
            ToPort: "80"
            CidrIp: "0.0.0.0/0"
          }
          { # HTTPS Exposed to the public Internet
            IpProtocol: "tcp"
            FromPort: "443"
            ToPort: "443"
            CidrIp: "0.0.0.0/0"
          }
          { # Privileged ports exposed only to machines within the cluster.
            IpProtocol: "tcp"
            FromPort: "2000"
            ToPort: "2999"
            CidrIp: "10.0.0.0/8"
          }
          { # Free ports exposed to public Internet.
            IpProtocol: "tcp"
            FromPort: "3000"
            ToPort: "3999"
            CidrIp: "0.0.0.0/0"
          }
          { # Exposed to Internet for etcd. TODO: Lock down so only CoreOS can access.
            IpProtocol: "tcp"
            FromPort: "4001"
            ToPort: "4001"
            CidrIp: "0.0.0.0/0"
          }
          { # Exposed to Internet for clustering. TODO: Lock down so only CoreOS can access.
            IpProtocol: "tcp"
            FromPort: "7001"
            ToPort: "7001"
            CidrIp: "0.0.0.0/0"
          }
        ]

    # Pass back the augmented template.
    template.Resources = resources
    return template
