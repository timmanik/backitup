import SwiftUI

struct ExportSheet: View {
    @Binding var options: ExportOptions
    let selection: [PhotoAsset]
    let onCancel: () -> Void
    let onExport: () -> Void

    private let blue = Color(red: 0.84, green: 0.30, blue: 0.31)
    private var selectedCount: Int { selection.filter { options.kinds.contains($0.kind) }.count }
    private var estimatedBytes: Int64 { selection.filter { options.kinds.contains($0.kind) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Export photos & videos").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("\(selection.count.formatted()) selected · \(selectedCount.formatted()) included · about \(formattedBytes(estimatedBytes))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 25)).foregroundStyle(blue)
            }.padding(26)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sectionHeader("MEDIA TO EXPORT", detail: "Choose which selected items go into this backup.")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 11) {
                        ForEach(MediaKind.allCases) { kind in
                            kindToggle(kind)
                        }
                    }
                    HStack(spacing: 28) {
                        optionToggle("Live Photo video files", value: $options.includeLiveVideos)
                        optionToggle("All burst frames", value: $options.includeBurstFrames)
                    }
                    HStack(spacing: 28) {
                        optionToggle("Pre-portrait originals", value: $options.includePortraitOriginals)
                        optionToggle("Originals of edited items", value: $options.includeEditedOriginals)
                    }
                    Text("Related originals are downloaded as sidecar files when the iPhone exposes them. Availability varies by asset and iOS version.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)

                    Divider()
                    sectionHeader("FOLDER ORGANIZATION", detail: "Keep exports easy to find later.")
                    optionToggle("Create folders for moments, grouped by year", value: $options.moments)
                    if options.moments {
                        HStack(spacing: 20) {
                            Picker("Folder name", selection: $options.momentFolderName) {
                                Text("Date only").tag(MomentFolderName.dateOnly)
                                Text("Date – Location").tag(MomentFolderName.dateLocation)
                                Text("Location – Date").tag(MomentFolderName.locationDate)
                            }.pickerStyle(.segmented).frame(width: 460)
                        }.padding(.leading, 24)
                    }
                    optionToggle("Create folders for media types", value: $options.mediaFolders)
                    optionToggle("Use original filenames", value: $options.originalFilenames)

                    Divider()
                    sectionHeader("FORMAT", detail: "Keep originals or make compatible copies.")
                    optionToggle("Convert HEIC to JPEG", value: $options.convertHEIC)
                    if options.convertHEIC {
                        HStack {
                            Text("JPEG quality").frame(width: 100, alignment: .leading)
                            Slider(value: $options.jpegQuality, in: 0.5...1.0).frame(width: 180)
                            Text("\(Int(options.jpegQuality * 100))%")
                        }.font(.system(size: 11)).padding(.leading, 24)
                    }
                    optionToggle("Convert videos to MP4", value: $options.convertHEVC)
                    Text("MP4 export uses the system's highest quality preset. Keep conversion off to preserve the exact original video file.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(26)
            }
            Divider()
            HStack {
                Text("A checksum manifest is saved with the exported files for later verification.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Export \(selectedCount.formatted()) items", action: onExport)
                    .buttonStyle(.borderedProminent).tint(blue).disabled(selectedCount == 0)
            }.padding(22)
        }
        .frame(width: 740, height: 710)
        .background(Color.white)
        .foregroundStyle(Color(red: 0.22, green: 0.22, blue: 0.25))
        .tint(blue)
        .preferredColorScheme(.light)
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(blue)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func kindToggle(_ kind: MediaKind) -> some View {
        let count = selection.filter { $0.kind == kind }.count
        return Toggle(isOn: Binding(get: { options.kinds.contains(kind) }, set: { enabled in
            if enabled { options.kinds.insert(kind) } else { options.kinds.remove(kind) }
        })) {
            Label("\(kind.rawValue) (\(count))", systemImage: kind.symbol)
                .font(.system(size: 12))
        }
        .toggleStyle(.checkbox)
        .disabled(count == 0)
    }

    private func optionToggle(_ title: String, value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value).toggleStyle(.checkbox).font(.system(size: 12))
    }
}
