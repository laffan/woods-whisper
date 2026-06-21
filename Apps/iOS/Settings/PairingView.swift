import SwiftUI
import CoreImage.CIFilterBuiltins
import WoodsWhisperKit

/// Shown on the iPad. Displays the address/port/secret the Watch needs to send recordings
/// directly. The Watch can't browse Bonjour, so the user configures it once from this screen
/// (type the values, or scan the QR if the Watch build adds a camera-import flow).
struct PairingView: View {
    @State private var addresses: [String] = []
    private let port = AppSettings.shared.localServerPort
    private let secret = AppSettings.shared.pairingSecret
    private let name = AppSettings.shared.deviceDisplayName

    var body: some View {
        Form {
            Section("This iPad") {
                LabeledContent("Name", value: name)
                LabeledContent("Port", value: port == 0 ? "auto (see app log)" : "\(port)")
                ForEach(addresses, id: \.self) { ip in
                    LabeledContent("WiFi address", value: ip)
                }
            }

            Section("Pairing Secret") {
                Text(secret).font(.footnote.monospaced()).textSelection(.enabled)
            }

            if let payload = pairingPayload, let qr = qrImage(from: payload) {
                Section("Scan from Watch setup") {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Watch Pairing")
        .onAppear { addresses = Self.wifiAddresses() }
    }

    private var pairingPayload: String? {
        guard let ip = addresses.first else { return nil }
        let link = DeviceLink(transport: .localNetwork, displayName: name, deviceID: name,
                              host: ip, port: port == 0 ? nil : port, pairingSecret: secret)
        guard let data = try? JSONEncoder.iso.encode(link) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func qrImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Best-effort enumeration of this device's IPv4 WiFi (en0) addresses.
    static func wifiAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" else { continue }   // WiFi on iOS devices
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            result.append(String(cString: host))
        }
        return result
    }
}
