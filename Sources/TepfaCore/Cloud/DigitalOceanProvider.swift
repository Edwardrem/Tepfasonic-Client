import Foundation

/// Lists droplets through the DigitalOcean v2 API.
public struct DigitalOceanProvider: CloudProvider {
    public let kind = CloudProviderKind.digitalOcean
    private let http: any CloudHTTPClient

    public init(http: any CloudHTTPClient = URLSessionCloudHTTPClient()) {
        self.http = http
    }

    public func listInstances(credentials: CloudCredentials) async throws -> [CloudInstance] {
        guard credentials.isComplete else { throw CloudError.missingCredentials(.digitalOcean) }
        var instances: [CloudInstance] = []
        var page = 1
        while true {
            var request = URLRequest(url: URL(string: "https://api.digitalocean.com/v2/droplets?per_page=200&page=\(page)")!)
            request.setValue("Bearer \(credentials.keyID)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await http.perform(request)
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 401 { throw CloudError.authentication(CloudProviders.errorText(data)) }
                throw CloudError.http(response.statusCode, CloudProviders.errorText(data))
            }
            let (parsed, hasMore) = try Self.parse(data)
            instances += parsed
            guard hasMore, !parsed.isEmpty else { break }
            page += 1
        }
        return instances.sorted { ($0.region, $0.name) < ($1.region, $1.name) }
    }

    /// Parses a `/v2/droplets` page; `hasMore` follows `links.pages.next`.
    public static func parse(_ data: Data) throws -> (instances: [CloudInstance], hasMore: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let droplets = object["droplets"] as? [[String: Any]] else {
            throw CloudError.malformed("no droplets array")
        }
        var instances: [CloudInstance] = []
        for droplet in droplets {
            let id = (droplet["id"] as? NSNumber)?.stringValue ?? ""
            let name = droplet["name"] as? String ?? id
            let region = ((droplet["region"] as? [String: Any])?["slug"] as? String) ?? ""
            let status = droplet["status"] as? String ?? ""
            let image = ((droplet["image"] as? [String: Any])?["slug"] as? String) ?? ((droplet["image"] as? [String: Any])?["distribution"] as? String)
            var publicIP: String?
            var privateIP: String?
            if let networks = droplet["networks"] as? [String: Any], let v4 = networks["v4"] as? [[String: Any]] {
                for network in v4 {
                    guard let address = network["ip_address"] as? String else { continue }
                    if network["type"] as? String == "public", publicIP == nil { publicIP = address }
                    if network["type"] as? String == "private", privateIP == nil { privateIP = address }
                }
            }
            var tags: [String: String] = [:]
            for tag in (droplet["tags"] as? [String]) ?? [] { tags[tag] = "" }
            instances.append(CloudInstance(provider: .digitalOcean, instanceID: id, name: name, region: region, publicIP: publicIP, privateIP: privateIP, state: status, tags: tags, image: image))
        }
        let hasMore = (((object["links"] as? [String: Any])?["pages"] as? [String: Any])?["next"] as? String) != nil
        return (instances, hasMore)
    }
}
