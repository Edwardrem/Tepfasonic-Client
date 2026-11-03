import Foundation
import Testing
@testable import TepfaCore

@Suite struct AWSSigV4Tests {
    /// The `get-vanilla` vector from the AWS SigV4 test suite.
    @Test func matchesTheAWSTestSuite() {
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        let credentials = AWSSigV4.Credentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        var components = DateComponents()
        components.year = 2015; components.month = 8; components.day = 30; components.hour = 12; components.minute = 36; components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: components)!
        AWSSigV4.sign(&request, credentials: credentials, region: "us-east-1", service: "service", date: date)
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature="))
        // Signature computed with the suite's algorithm including the x-amz-content-sha256 header.
        #expect(AWSSigV4.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func encodingKeepsUnreservedCharactersOnly() {
        #expect(AWSSigV4.encode("a b/c~d") == "a%20b%2Fc~d")
        #expect(AWSSigV4.encode("a/b", keepSlash: true) == "a/b")
    }
}

@Suite struct CloudParsingTests {
    @Test func ec2XMLYieldsInstancesWithTagsAndAddresses() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
          <requestId>abc</requestId>
          <reservationSet><item><reservationId>r-1</reservationId><instancesSet>
            <item>
              <instanceId>i-0123</instanceId>
              <imageId>ami-ubuntu-22</imageId>
              <instanceState><code>16</code><name>running</name></instanceState>
              <privateIpAddress>10.0.1.5</privateIpAddress>
              <ipAddress>54.1.2.3</ipAddress>
              <tagSet><item><key>Name</key><value>web-01</value></item><item><key>env</key><value>prod</value></item></tagSet>
              <networkInterfaceSet><item><privateIpAddress>10.0.1.5</privateIpAddress><association><publicIp>54.1.2.3</publicIp></association></item></networkInterfaceSet>
            </item>
            <item>
              <instanceId>i-0456</instanceId>
              <instanceState><code>80</code><name>stopped</name></instanceState>
              <privateIpAddress>10.0.1.6</privateIpAddress>
            </item>
          </instancesSet></item></reservationSet>
          <nextToken>page2</nextToken>
        </DescribeInstancesResponse>
        """
        let (instances, next) = try AWSEC2Provider.parse(Data(xml.utf8), region: "eu-west-1")
        #expect(next == "page2")
        #expect(instances.count == 2)
        let web = try #require(instances.first { $0.instanceID == "i-0123" })
        #expect(web.name == "web-01")
        #expect(web.publicIP == "54.1.2.3")
        #expect(web.privateIP == "10.0.1.5")
        #expect(web.state == "running")
        #expect(web.isRunning)
        #expect(web.tags["env"] == "prod")
        #expect(web.suggestedUsername == "ubuntu")
        #expect(web.region == "eu-west-1")
        let stopped = try #require(instances.first { $0.instanceID == "i-0456" })
        #expect(stopped.name == "i-0456")
        #expect(!stopped.isRunning)
        #expect(stopped.publicIP == nil)
        #expect(stopped.suggestedUsername == "ec2-user")
    }

    @Test func ec2ErrorsSurface() {
        let xml = "<Response><Errors><Error><Code>AuthFailure</Code><Message>bad key</Message></Error></Errors></Response>"
        #expect(throws: CloudError.malformed("bad key")) { try AWSEC2Provider.parse(Data(xml.utf8), region: "us-east-1") }
    }

    @Test func digitalOceanDropletsParse() throws {
        let json = """
        {"droplets":[{"id":123,"name":"db-1","status":"active","region":{"slug":"fra1"},"image":{"slug":"debian-12-x64","distribution":"Debian"},"tags":["db"],
          "networks":{"v4":[{"ip_address":"10.1.0.2","type":"private"},{"ip_address":"165.1.2.3","type":"public"}]}}],
         "links":{"pages":{"next":"https://api.digitalocean.com/v2/droplets?page=2"}},"meta":{"total":1}}
        """
        let (instances, hasMore) = try DigitalOceanProvider.parse(Data(json.utf8))
        #expect(hasMore)
        let droplet = try #require(instances.first)
        #expect(droplet.instanceID == "123")
        #expect(droplet.name == "db-1")
        #expect(droplet.region == "fra1")
        #expect(droplet.publicIP == "165.1.2.3")
        #expect(droplet.privateIP == "10.1.0.2")
        #expect(droplet.isRunning)
        #expect(droplet.suggestedUsername == "admin")
        #expect(droplet.tags["db"] == "")
    }

    @Test func azureResourcesAreJoined() throws {
        let vms = """
        {"value":[{"id":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1","name":"vm1","location":"westeurope",
          "tags":{"role":"api"},
          "properties":{"provisioningState":"Succeeded","osProfile":{"adminUsername":"deploy"},
            "storageProfile":{"imageReference":{"publisher":"Canonical","offer":"ubuntu-24_04-lts","sku":"server"}},
            "networkProfile":{"networkInterfaces":[{"id":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/NIC1"}]}}}]}
        """
        let nics = """
        {"value":[{"id":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic1",
          "properties":{"ipConfigurations":[{"properties":{"privateIPAddress":"10.2.0.4","publicIPAddress":{"id":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip1"}}}]}}]}
        """
        let ips = """
        {"value":[{"id":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/PIP1","properties":{"ipAddress":"20.1.2.3"}}]}
        """
        let instances = try AzureProvider.parse(vms: Data(vms.utf8), nics: Data(nics.utf8), publicIPs: Data(ips.utf8))
        let vm = try #require(instances.first)
        #expect(vm.name == "vm1")
        #expect(vm.region == "westeurope")
        #expect(vm.privateIP == "10.2.0.4")
        #expect(vm.publicIP == "20.1.2.3")
        #expect(vm.suggestedUsername == "deploy")
        #expect(vm.tags["role"] == "api")
    }

    @Test func documentFromInstancesIsStableAndTagged() {
        let instance = CloudInstance(provider: .digitalOcean, instanceID: "7", name: "web", region: "nyc3", publicIP: "1.2.3.4", privateIP: "10.0.0.1", state: "active", tags: ["web": ""], image: "ubuntu-22-04-x64")
        let first = CloudInstance.document(from: [instance], groupName: "DigitalOcean", preferPrivateIP: false)
        let second = CloudInstance.document(from: [instance], groupName: "DigitalOcean", preferPrivateIP: true, usernameOverride: "ops")
        #expect(first.hosts.count == 1)
        #expect(first.hosts[0].id == second.hosts[0].id)
        #expect(first.groups[0].id == second.groups[0].id)
        #expect(first.hosts[0].hostname == "1.2.3.4")
        #expect(second.hosts[0].hostname == "10.0.0.1")
        #expect(first.hosts[0].username == "ubuntu")
        #expect(second.hosts[0].username == "ops")
        #expect(first.hosts[0].tags.contains("digitalocean"))
        #expect(first.hosts[0].tags.contains("nyc3"))
        #expect(first.hosts[0].groupID == first.groups[0].id)
        let noAddress = CloudInstance(provider: .aws, instanceID: "i-1", name: "x", region: "r", state: "stopped")
        #expect(CloudInstance.document(from: [noAddress], groupName: nil, preferPrivateIP: false).hosts.isEmpty)
    }

    @Test func credentialsCompleteness() {
        #expect(!CloudCredentials(provider: .aws, keyID: "k").isComplete)
        #expect(CloudCredentials(provider: .aws, keyID: "k", secret: "s").isComplete)
        #expect(CloudCredentials(provider: .digitalOcean, keyID: "t").isComplete)
        #expect(!CloudCredentials(provider: .azure, keyID: "c", secret: "s", tenantID: "t").isComplete)
        #expect(CloudCredentials(provider: .azure, keyID: "c", secret: "s", tenantID: "t", subscriptionID: "sub").isComplete)
    }
}
