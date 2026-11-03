import Foundation

/// Lists virtual machines through Azure Resource Manager with a service
/// principal (client credentials flow), resolving each VM's network
/// interfaces to its private and public addresses.
public struct AzureProvider: CloudProvider {
    public let kind = CloudProviderKind.azure
    private let http: any CloudHTTPClient

    public init(http: any CloudHTTPClient = URLSessionCloudHTTPClient()) {
        self.http = http
    }

    public func listInstances(credentials: CloudCredentials) async throws -> [CloudInstance] {
        guard credentials.isComplete else { throw CloudError.missingCredentials(.azure) }
        let token = try await accessToken(credentials)
        let subscription = credentials.subscriptionID
        let vms = try await getJSON("https://management.azure.com/subscriptions/\(subscription)/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01", token: token)
        let nics = try await getJSON("https://management.azure.com/subscriptions/\(subscription)/providers/Microsoft.Network/networkInterfaces?api-version=2024-05-01", token: token)
        let publicIPs = try await getJSON("https://management.azure.com/subscriptions/\(subscription)/providers/Microsoft.Network/publicIPAddresses?api-version=2024-05-01", token: token)
        var instances = try Self.parse(vms: vms, nics: nics, publicIPs: publicIPs)
        // Power state lives in the instance view; fetch it for each VM (best effort).
        for index in instances.indices {
            let id = instances[index].instanceID
            if let view = try? await getJSON("https://management.azure.com\(id)/instanceView?api-version=2024-07-01", token: token),
               let statuses = (try? JSONSerialization.jsonObject(with: view) as? [String: Any])?["statuses"] as? [[String: Any]],
               let power = statuses.compactMap({ $0["code"] as? String }).first(where: { $0.hasPrefix("PowerState/") }) {
                instances[index].state = String(power.dropFirst("PowerState/".count))
            }
        }
        return instances.sorted { ($0.region, $0.name) < ($1.region, $1.name) }
    }

    func accessToken(_ credentials: CloudCredentials) async throws -> String {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(credentials.tenantID)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": credentials.keyID,
            "client_secret": credentials.secret,
            "grant_type": "client_credentials",
            "scope": "https://management.azure.com/.default",
        ]
        request.httpBody = Data(form.map { "\($0.key)=\(AWSSigV4.encode($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await http.perform(request)
        guard (200..<300).contains(response.statusCode) else { throw CloudError.authentication(CloudProviders.errorText(data)) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = object["access_token"] as? String else {
            throw CloudError.malformed("no access token")
        }
        return token
    }

    private func getJSON(_ url: String, token: String) async throws -> Data {
        var all: [[String: Any]] = []
        var next: String? = url
        while let current = next {
            var request = URLRequest(url: URL(string: current)!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await http.perform(request)
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 { throw CloudError.authentication(CloudProviders.errorText(data)) }
                throw CloudError.http(response.statusCode, CloudProviders.errorText(data))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.malformed("not a JSON object") }
            if let value = object["value"] as? [[String: Any]] {
                all += value
                next = object["nextLink"] as? String
            } else {
                return data
            }
        }
        return try JSONSerialization.data(withJSONObject: ["value": all])
    }

    /// Joins VMs, NICs and public IPs into instances.
    public static func parse(vms: Data, nics: Data, publicIPs: Data) throws -> [CloudInstance] {
        func values(_ data: Data) throws -> [[String: Any]] {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["value"] as? [[String: Any]] else {
                throw CloudError.malformed("no value array")
            }
            return value
        }
        var publicByID: [String: String] = [:]
        for ip in try values(publicIPs) {
            if let id = ip["id"] as? String, let address = (ip["properties"] as? [String: Any])?["ipAddress"] as? String {
                publicByID[id.lowercased()] = address
            }
        }
        var nicByID: [String: (private: String?, public: String?)] = [:]
        for nic in try values(nics) {
            guard let id = nic["id"] as? String, let configurations = (nic["properties"] as? [String: Any])?["ipConfigurations"] as? [[String: Any]] else { continue }
            var privateIP: String?
            var publicIP: String?
            for configuration in configurations {
                let properties = configuration["properties"] as? [String: Any] ?? [:]
                if privateIP == nil { privateIP = properties["privateIPAddress"] as? String }
                if publicIP == nil, let reference = (properties["publicIPAddress"] as? [String: Any])?["id"] as? String {
                    publicIP = publicByID[reference.lowercased()]
                }
            }
            nicByID[id.lowercased()] = (privateIP, publicIP)
        }
        var instances: [CloudInstance] = []
        for vm in try values(vms) {
            let id = vm["id"] as? String ?? ""
            let name = vm["name"] as? String ?? id
            let location = vm["location"] as? String ?? ""
            let properties = vm["properties"] as? [String: Any] ?? [:]
            var privateIP: String?
            var publicIP: String?
            for interface in ((properties["networkProfile"] as? [String: Any])?["networkInterfaces"] as? [[String: Any]]) ?? [] {
                guard let reference = interface["id"] as? String, let addresses = nicByID[reference.lowercased()] else { continue }
                if privateIP == nil { privateIP = addresses.private }
                if publicIP == nil { publicIP = addresses.public }
            }
            let image = ((properties["storageProfile"] as? [String: Any])?["imageReference"] as? [String: Any]).flatMap { reference in
                [reference["publisher"] as? String, reference["offer"] as? String, reference["sku"] as? String].compactMap { $0 }.joined(separator: " ")
            }
            let username = ((properties["osProfile"] as? [String: Any])?["adminUsername"] as? String)
            var tags = (vm["tags"] as? [String: String]) ?? [:]
            if let username { tags["adminUsername"] = username }
            let state = (properties["provisioningState"] as? String) ?? ""
            instances.append(CloudInstance(provider: .azure, instanceID: id, name: name, region: location, publicIP: publicIP, privateIP: privateIP, state: state, tags: tags, image: image))
        }
        return instances
    }
}
