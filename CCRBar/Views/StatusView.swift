import SwiftUI

struct StatusView: View {
    let status: CCRStatus
    let gatewayUp: Bool
    let managementUp: Bool
    let nodeRuntimeDescription: String?
    let managementPort: UInt16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.color)
                Text(status.title)
                    .font(.headline)
            }

            if let nodeRuntimeDescription {
                Text(nodeRuntimeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(gatewayUp ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text("Gateway")
                        .fontWeight(.medium)
                    Spacer()
                    Text("127.0.0.1:3456")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(managementUp ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text("Management")
                        .fontWeight(.medium)
                    Spacer()
                    Text("127.0.0.1:\(managementPort)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}
