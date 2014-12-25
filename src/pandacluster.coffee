#===============================================================================
# PandaCluster - Awesome Command-Line Tool and Library to Manage CoreOS Clusters
#===============================================================================

#====================
# Modules
#====================
{resolve} = require "path"
resolve_path = (x...) -> resolve(x...)    # Avoids confusion with "resolve" of promise

{read, write} = require "fairmont"        # Easy file read/write
{parse} = require "c50n"                  # .cson file parsing

https = require "https"
{promise} = require "when"                # Awesome promise library
async = (require "when/generator").lift   # Makes resuable generators.
node_lift = (require "when/node").lift

{exec} = require "shelljs"                # Access to commandline

{liftAll} = require "when/node"                 # ES6 styled way for file IO
{readFile, writeFile} = (liftAll require "fs")
StringDecoder = require('string_decoder').StringDecoder   # Convert SSH file stream to string

AWS = require "aws-sdk"                   # Access AWS API


#================================
# Helper Functions
#================================
# Promise wrapper around Node's https module. Makes GET calls into promises.
https_get = (url) ->
  promise (resolve, reject) ->
    https.get url
    .on "response", (response) ->
      resolve response
    .on "error", (error) ->
      resolve error

# Promise wrapper around response events that read "data" from the response's body.
get_body = (response) ->
  promise (resolve, reject) ->
    data = ""

    response.setEncoding "utf8"
    .on "data", (chunk) ->
      data = data + chunk
    .on "end", ->
      resolve data
    .on "error", (error) ->
      resolve error


# Pulls the most recent AWS CloudFormation template from CoreOS.
pull_cloud_template = async ({channel, virtualization}) ->
  # Set reasonable defaults for these preferences.
  channel = channel or "stable"
  virtualization = virtualization or "pv"

  # This directory has a handy CSON file of URLs for CoreOS's latest CloudFormation templates.
  template_store = parse( read( resolve_path( __dirname, "templates.cson")))
  template_url = template_store[channel][virtualization]

  response = yield https_get template_url
  template_object = JSON.parse (yield get_body response)

  return template_object

# Add unit to the cloud-config section of the AWS template.
add_unit = (cloud_config, unit) ->
  # The cloud-config file is stored as an array of strings inside the "UserData"
  # object of the AWS template.  We wish to add additional strings to this array.
  # We need to be careful because "cloud-config" files are formatted in YAML,
  # which is sensitive to indentation....

  # Add to the cloud_config array.
  cloud_config.push "    - name: #{unit.name}\n"
  cloud_config.push "      runtime: #{unit.runtime}\n"   if unit.runtime?
  cloud_config.push "      command: #{unit.command}\n"   if unit.command?
  cloud_config.push "      enable: #{unit.enable}\n"       if unit.enable?
  cloud_config.push "      content: |\n"

  # For "content", we draw from a unit-file maintained in a separate file. Add
  # eight spaces to the begining of each line (4 indentations) and follow each
  # line with an explicit new-line character.
  content = read( resolve_path( unit.content))
  content = content.split "\n"

  while content.length > 0
    cloud_config.push "        " + content[0] + "\n"
    content.shift()

  return cloud_config

# Confirm that the named SSH key exists in your AWS account.  This is a promise
# wrapper for the EC2 module's "describeKeyPairs" function, and it assumes that
# the AWS object has already been configured with your credentials.
validate_key_pair = (key_pair) ->
  promise (resolve, reject) ->
    ec2 = new AWS.EC2()

    ec2.describeKeyPairs {}, (err, data) ->
      unless err
        names = []
        for key in data.KeyPairs
          names.push key.KeyName

        if names.indexOf(key_pair) == -1
          process.stderr.write "\nError: This AWS account does not have a key pair named \"#{key_pair}\".\n\n"
          process.exit -1

        resolve true

      else
        process.stderr.write "\nError:  Unable to validate SSH key.\n"
        process.stderr.write "#{err}\n\n"
        process.exit -1


# Create a CoreOS cluster using the AWS account information that has been gathered.
# This is a promise wrapper for the CloudFormation module's "createStack" function,
# and it assumes the AWS object has already been configured with your crednetials.
create_cluster = (params) ->
  promise (resolve, reject) ->
    cloudformation = new AWS.CloudFormation()

    cloudformation.createStack params, (err, data) ->
      unless err
        process.stdout.write "\nSuccess!!  Cluster formation is in progress.\n"
        resolve true
      else
        process.stderr.write "\nApologies. Cluster formation has failed.\n\n#{err}\n"
        process.exit -1


# Destroy a CoreOS cluster using the AWS account information that has been gathered.
# This is a promise wrapper for the CloudFormation module's "deleteStack" function,
# and it assumes the AWS object has already been configured with your crednetials.
destroy_cluster = (params) ->
  promise (resolve, reject) ->
    cloudformation = new AWS.CloudFormation()
    cloudformation.deleteStack params, (err, data) ->
      unless err
        process.stdout.write "\nSuccess!!  Cluster destruction is in progress.\n"
        resolve true
      else
        process.stderr.write "\nApologies. Cluster destruction has failed.\n\n#{err}\n"
        process.exit -1


lift_object = (object, method) ->
  node_lift method.bind object

# Retrieves all instances with "stack-name" matching the passed in argument.
# Since the ec2 object is stateful, we need to 
get_instances_addresses = async (stack_name) ->
  ec2 = liftAll (new AWS.EC2())
  describeInstances = lift_object ec2, ec2.describeInstances

  params =
    Filters: [
      Name: "tag:aws:cloudformation:stack-name"
      Values: [stack_name]
    ]
  try
    data = yield describeInstances params
    # corral each instance's public DNS into an array
    public_addresses = []
    for reservation in data.Reservations
      for instance in reservation.Instances
        public_addresses.push instance.PublicDnsName
    if public_addresses.length == 0
      process.stderr.write "\nError: No instances with 'stack-name'\"#{stack_name}\".\n\n"
      process.exit -1
    data
  catch error
    #throw "\nError:  Unable to request describeInstances from EC2 .\n #{error}\n\n"
    process.stderr.write "\nError:  Unable to request describeInstances from EC2 .\n #{error}\n\n"
    process.exit -1


# Read SSH public key files on local machine
read_keys_from_local = async (ssh_file_path) ->
  decoder = new StringDecoder('utf8')
  ssh_keys = []
  # TODO: handle multiple files
  try
    ssh_file_buffer = yield readFile ssh_file_path
    ssh_file_string = decoder.write ssh_file_buffer
    ssh_keys.push ssh_file_string
  catch error
    console.log "Error occured reading SSH public key file: #{error}"
    process.exit -1
  return ssh_keys

# Write SSH public key file to cluster instances
write_authorized_hosts = async (contents, path) ->
  ssh_keys = []
  for file in options.files
    try
      ssh_file = yield writeFile( resolve_path( process.cwd(), file))
      ssh_keys.push ssh_file
    catch error
      console.log "Error occured reading SSH public key file: #{error}"
      process.exit -1
  return true

# Download SSH public keys to given IP addresses
# Default location downloaded to localhost: /tmp/pandacluster_authorized_hosts
download_keys_via_ssh = (addresses) ->
  exec "bash #{__dirname}/scripts/download #{addresses}"

# Uploads SSH public keys to given IP addresses
# Default location uploaded from localhost: /tmp/pandacluster_authorized_hosts
upload_keys_via_ssh = (addresses, keys) ->
  exec "bash #{__dirname}/scripts/upload #{keys} #{addresses}"


#===============================
# PandaCluster Definition
#===============================
module.exports =

  # This method builds an AWS CloudFormation template by augmenting the official
  # ones released by CoreOS.
  build_template: async (options) ->

    options = options or {}

    # Pull official CoreOS template as a JSON object.
    template_object = yield pull_cloud_template options

    # Isolate the cloud-config array within the JSON object.
    user_data = template_object.Resources.CoreOSServerLaunchConfig.Properties.UserData
    cloud_config = user_data["Fn::Base64"]["Fn::Join"][1]

    # Add the specified units to the cloud-config section.
    if options.units?
      for x in options.units
        cloud_config = add_unit cloud_config, x

    # Place this array back into the JSON object.  Construction complete.
    user_data["Fn::Base64"]["Fn::Join"][1] = cloud_config
    template_object.Resources.CoreOSServerLaunchConfig.Properties.UserData = user_data

    # Return or write the JSON string to a file.
    if options.write_path?
      write "#{process.cwd()}/#{options.write_path}", JSON.stringify( template_object, null, '\t' )
      return
    else
      return JSON.stringify template_object



  # This method creates and starts a CoreOS cluster.
  create: async (credentials, options) ->
    # Configure the AWS object for account access.
    AWS.config =
      accessKeyId: credentials.id
      secretAccessKey: credentials.key
      region: options.region or credentials.region
      sslEnabled: true

    # Build the "params" object that is used directly by the "createStack" method.
    params = {}
    params.StackName = options.stack_name
    params.OnFailure = "DELETE"

    #------------------------
    # TemplateBody Paramter
    #------------------------
    # This object is drawn from either a specified JSON file or a basic default pulled from online.
    if options.template_path?
      params.TemplateBody = read( resolve_path( process.cwd(), options.template_path))
    else
      params.TemplateBody = yield @build_template()

    #---------------------------------------------------------------------------
    # Parameters is a map of key/values custom defined for this stack by the
    # template file.  We will now fill out the map as specified or with defaults.
    #---------------------------------------------------------------------------
    params.Parameters = []

    # InstanceType
    foo =
      "ParameterKey": "InstanceType"
      "ParameterValue": options.instance_type or "m3.medium"
    params.Parameters.push foo

    # ClusterSize
    foo =
      "ParameterKey": "ClusterSize"
      "ParameterValue": options.cluster_size or "3"
    params.Parameters.push foo

    # DiscoveryURL - Grab a randomized URL from etcd's free discovery service.
    bar = yield https_get "https://discovery.etcd.io/new"
    bar = yield get_body bar
    foo =
      "ParameterKey": "DiscoveryURL"
      "ParameterValue": bar
    params.Parameters.push foo

    # KeyPair
    yield validate_key_pair options.key_pair
    foo =
      "ParameterKey": "KeyPair"
      "ParameterValue": options.key_pair
    params.Parameters.push foo

    # AdvertisedIPAddress - uses default "private", TODO: Add this option
    # AllowSSHFrom        - uses default "everywhere", TODO: Add this option

    #---------------------
    # Access AWS
    #---------------------
    # With everything in place, we may finally make a call to Amazon's API.
    yield create_cluster params






  # This method stops and destroys a CoreOS cluster.
  destroy: async (credentials, options) ->
    # Configure the AWS object for account access.
    AWS.config =
      accessKeyId: credentials.id
      secretAccessKey: credentials.key
      region: options.region or credentials.region
      sslEnabled: true

    # Build the "params" object that is used directly by the "createStack" method.
    params = {}
    params.StackName = options.stack_name

    #---------------------
    # Access AWS
    #---------------------
    # With everything in place, we may finally make a call to Amazon's API.
    yield destroy_cluster params

  # This method uploads public SSH keys
  # FIXME: where to pass in credentials
  upload: async (credentials, options) ->
    AWS.config =
      accessKeyId: credentials.id
      secretAccessKey: credentials.key
      region: options.region or credentials.region
      sslEnabled: true

    #---------------------
    # Read in keys the user wants to upload from local machine
    #---------------------
    ssh_key_string = yield read_keys_from_local options.ssh_file_path

    #---------------------
    # Access AWS
    #---------------------
    public_addresses = (yield get_instances_addresses options.stack_name)

    #---------------------
    # SSH into Cluster Instances
    #---------------------
    upload_keys_via_ssh public_addresses, ssh_key_string


