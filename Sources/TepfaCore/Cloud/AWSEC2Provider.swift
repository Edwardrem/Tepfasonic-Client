import CryptoKit
import Foundation

/// Signs requests with AWS Signature Version 4.
public enum AWSSigV4 {
    public struct Credentials: Sendable {
        public var accessKeyID: String
        public var secretAccessKey: String
        public var sessionToken: String?

        public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// Percent-encodes as AWS wants: unreserved characters only.
    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepSlash { allowed.insert("/") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    /// Adds `Authorization`, `X-Amz-Date` and `Host` to the request.
    public static func sign(_ request: inout URLRequest, credentials: Credentials, region: String, service: String, date: Date = .now) {
        guard let url = request.url, let host = url.host else { return }
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? Data()
        let amzDate = timestampFormatter().string(from: date)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = sha256(body)

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        if let token = credentials.sessionToken { request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token") }

        var headers: [(String, String)] = []
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            guard ["host", "content-type", "x-amz-date", "x-amz-content-sha256", "x-amz-security-token", "x-amz-target"].contains(lower) else { continue }
            headers.append((lower, value.trimmingCharacters(in: .whitespaces)))
        }
        headers.sort { $0.0 < $1.0 }
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        let query = (components?.queryItems ?? [])
            .map { (encode($0.name), encode($0.value ?? "")) }
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [method, path, query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(Data(canonicalRequest.utf8))].joined(separator: "\n")

        let kDate = hmac(Data(("AWS4" + credentials.secretAccessKey).utf8), dateStamp)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        let kSigning = hmac(kService, "aws4_request")
        let signature = hex(hmac(kSigning, stringToSign))

        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
    }
}

/// Lists EC2 instances with `DescribeInstances` (Query API, XML).
public struct AWSEC2Provider: CloudProvider {
    public let kind = CloudProviderKind.aws
    private let http: any CloudHTTPClient

    public static let defaultRegions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-north-1", "ap-south-1", "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ap-northeast-2", "sa-east-1", "ca-central-1", "af-south-1", "me-south-1"]

    public init(http: any CloudHTTPClient = URLSessionCloudHTTPClient()) {
        self.http = http
    }

    public func listInstances(credentials: CloudCredentials) async throws -> [CloudInstance] {
        guard credentials.isComplete else { throw CloudError.missingCredentials(.aws) }
        let regions = credentials.regions.isEmpty ? Self.defaultRegions : credentials.regions
        let signing = AWSSigV4.Credentials(accessKeyID: credentials.keyID, secretAccessKey: credentials.secret, sessionToken: credentials.tenantID.isEmpty ? nil : credentials.tenantID)
        return try await withThrowingTaskGroup(of: [CloudInstance].self) { group in
            for region in regions {
                group.addTask { try await self.describeInstances(region: region, credentials: signing) }
            }
            var all: [CloudInstance] = []
            for try await instances in group { all += instances }
            return all.sorted { ($0.region, $0.name) < ($1.region, $1.name) }
        }
    }

    func describeInstances(region: String, credentials: AWSSigV4.Credentials) async throws -> [CloudInstance] {
        var instances: [CloudInstance] = []
        var nextToken: String?
        repeat {
            var body = "Action=DescribeInstances&Version=2016-11-15&MaxResults=1000"
            if let nextToken { body += "&NextToken=" + AWSSigV4.encode(nextToken) }
            var request = URLRequest(url: URL(string: "https://ec2.\(region).amazonaws.com/")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            AWSSigV4.sign(&request, credentials: credentials, region: region, service: "ec2")
            let (data, response) = try await http.perform(request)
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 { throw CloudError.authentication(CloudProviders.errorText(data)) }
                // A region that is not enabled for the account answers with an error; skip it quietly.
                if String(decoding: data, as: UTF8.self).contains("OptInRequired") || String(decoding: data, as: UTF8.self).contains("UnauthorizedOperation") { return [] }
                throw CloudError.http(response.statusCode, CloudProviders.errorText(data))
            }
            let page = try Self.parse(data, region: region)
            instances += page.instances
            nextToken = page.nextToken
        } while nextToken != nil
        return instances
    }

    /// Parses a DescribeInstances response.
    public static func parse(_ data: Data, region: String) throws -> (instances: [CloudInstance], nextToken: String?) {
        let parser = EC2XMLParser(region: region)
        guard parser.parse(data) else { throw CloudError.malformed(parser.failure ?? "invalid XML") }
        return (parser.instances, parser.nextToken)
    }
}

/// A small SAX parser for the parts of DescribeInstances we need.
final class EC2XMLParser: NSObject, XMLParserDelegate {
    private let region: String
    private var path: [String] = []
    private var text = ""
    private var current: CloudInstance?
    private var tagKey = ""
    private var tagValue = ""
    private(set) var instances: [CloudInstance] = []
    private(set) var nextToken: String?
    private(set) var failure: String?

    init(region: String) {
        self.region = region
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse() && failure == nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(elementName)
        text = ""
        if elementName == "item", path.dropLast().last == "instancesSet" {
            current = CloudInstance(provider: .aws, instanceID: "", name: "", region: region, state: "")
        }
        if elementName == "item", path.dropLast().last == "tagSet" {
            tagKey = ""
            tagValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.dropLast().last ?? ""
        // Only fields directly under the instance item (not nested network interfaces) count:
        // instancesSet / item / <field> is depth 3 from the instancesSet element.
        let depthInInstance = path.drop(while: { $0 != "instancesSet" }).count
        switch elementName {
        case "instanceId" where depthInInstance == 3: current?.instanceID = value
        case "ipAddress" where depthInInstance == 3: current?.publicIP = value
        case "privateIpAddress" where depthInInstance == 3: current?.privateIP = value
        case "imageId" where depthInInstance == 3: current?.image = value
        case "name" where parent == "instanceState" && depthInInstance == 4: current?.state = value
        case "key" where parent == "item" && path.contains("tagSet"): tagKey = value
        case "value" where parent == "item" && path.contains("tagSet"): tagValue = value
        case "item" where parent == "tagSet":
            if !tagKey.isEmpty { current?.tags[tagKey] = tagValue }
            if tagKey == "Name" { current?.name = tagValue }
        case "item" where parent == "instancesSet":
            if var instance = current {
                if instance.name.isEmpty { instance.name = instance.instanceID }
                instances.append(instance)
            }
            current = nil
        case "nextToken" where path.count == 2: nextToken = value.isEmpty ? nil : value
        case "Message" where path.contains("Error"): failure = value
        default: break
        }
    }
}
