import AppKit
import SwiftUI

/// An open-source component used by the app, the driver or the build.
struct OpenSourceComponent: Identifiable {
    let name: String
    let author: String
    let usage: String
    let license: String
    let url: URL
    /// License texts bundled in Resources/Licenses (file names without .txt).
    let licenseFiles: [String]

    var id: String { name }

    static let all: [OpenSourceComponent] = [
        OpenSourceComponent(
            name: "libASPL",
            author: "Victor Gaydov and contributors",
            usage: "The audio driver is built on it. Includes portions of Apple sample code.",
            license: "MIT",
            url: URL(string: "https://github.com/gavv/libASPL")!,
            licenseFiles: ["libASPL", "libASPL-Apple-2012", "libASPL-Apple-2020"]
        ),
        OpenSourceComponent(
            name: "proxy-audio-device",
            author: "Brian Kendall",
            usage: "The driver's clock servo is adapted from its design.",
            license: "Unlicense",
            url: URL(string: "https://github.com/briankendall/proxy-audio-device")!,
            licenseFiles: ["proxy-audio-device"]
        ),
        OpenSourceComponent(
            name: "XcodeGen",
            author: "Yonas Kolb",
            usage: "Generates the Xcode project. Build tool only, not shipped.",
            license: "MIT",
            url: URL(string: "https://github.com/yonaskolb/XcodeGen")!,
            licenseFiles: ["XcodeGen"]
        ),
    ]
}

struct AboutView: View {
    private let author = URL(string: "https://codejo.com")!
    private let repository = URL(string: "https://github.com/codejo-dev/SimpleAudioManager")!

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Simple Audio Manager")
                            .font(.title2.weight(.semibold))
                        Text(version)
                            .foregroundStyle(.secondary)
                        Text("Native volume control and tidy device lists for macOS.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Author") {
                LabeledContent("Made by") {
                    Link("codejo", destination: author)
                }
                LabeledContent("Website") {
                    Link("github.com/codejo-dev/SimpleAudioManager", destination: repository)
                }
            }

            Section("License") {
                LabeledContent("License", value: "MIT")
                LicenseDisclosure(files: ["SimpleAudioManager"])
            }

            Section {
                ForEach(OpenSourceComponent.all) { component in
                    ComponentRow(component: component)
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text("Icons use Apple's SF Symbols, licensed by Apple for use on Apple platforms.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
        .navigationSubtitle("Simple Audio Manager")
    }
}

private struct ComponentRow: View {
    let component: OpenSourceComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Link(component.name, destination: component.url)
                    .font(.headline)
                Spacer()
                Text(component.license)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(component.author). \(component.usage)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LicenseDisclosure(files: component.licenseFiles)
        }
        .padding(.vertical, 4)
    }
}

/// "License Text" disclosure showing the bundled license file(s).
private struct LicenseDisclosure: View {
    let files: [String]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("License Text", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(files, id: \.self) { file in
                    Text(Self.text(of: file))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    static func text(of file: String) -> String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "License text unavailable." }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
