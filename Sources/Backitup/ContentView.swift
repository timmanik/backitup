import AppKit
import SwiftUI

private enum AppSection: String, CaseIterable {
    case library = "All Photos"
    case backups = "Backup Status"
    case storage = "Storage"
}

struct ContentView: View {
    @EnvironmentObject private var library: DeviceLibrary
    @AppStorage("backupFolderPath") private var backupFolderPath = ""
    @AppStorage("groupPhotosByDate") private var groupPhotosByDate = true
    @AppStorage("newestPhotosFirst") private var newestPhotosFirst = true
    @State private var section: AppSection = .library
    @State private var kindFilter: MediaKind?
    @State private var query = ""
    @State private var showingDateFilter = false
    @State private var useFromDate = false
    @State private var useThroughDate = false
    @State private var fromDate = Date()
    @State private var throughDate = Date()
    @State private var selected = Set<String>()
    @State private var selectionAnchorID: String?
    @State private var exportOptions = ExportOptions()
    @State private var showExport = false
    @State private var showDelete = false
    @State private var returnToDeleteAfterExport = false
    @State private var openExportAfterDeleteSheet = false
    @State private var errorMessage: String?
    @State private var backupError: String?
    @State private var tileSize: CGFloat = 150

    private let accent = Color(red: 0.36, green: 0.62, blue: 1)

    private var dateRange: PhotoDateRange {
        PhotoDateRange(from: useFromDate ? fromDate : nil,
                       through: useThroughDate ? throughDate : nil)
    }

    private var visible: [PhotoAsset] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = library.galleryAssets.filter { asset in
            (kindFilter == nil || asset.kind == kindFilter) &&
            (search.isEmpty || asset.name.localizedCaseInsensitiveContains(search)) &&
            dateRange.contains(asset.date)
        }
        if newestPhotosFirst { return filtered }
        let dated = filtered.filter { $0.date != .distantPast }.reversed()
        return Array(dated) + filtered.filter { $0.date == .distantPast }
    }
    private var chosen: [PhotoAsset] { library.galleryAssets.filter { selected.contains($0.id) } }
    private var verifiedSelection: [PhotoAsset] {
        let ids = DeviceLibrary.verifiedGalleryIDs(selected, assets: library.assets, galleryAssets: library.galleryAssets,
                                                    states: library.backupStates)
        return chosen.filter { ids.contains($0.id) }
    }
    private var verifiedSelectionCount: Int { verifiedSelection.count }
    private var deleteGuidance: String {
        var requirements: [String] = []
        if rootURL == nil {
            requirements.append("To delete from the iPhone, choose a backup folder and export or check the selected items first.")
        } else if library.busy {
            requirements.append("Checking backup files; this count updates as checks finish.")
        } else if verifiedSelectionCount < selected.count {
            requirements.append("Back up the remaining \(selected.count - verifiedSelectionCount) items or check an existing Backitup backup.")
        }
        if !library.canTransfer {
            requirements.append("Reconnect and unlock the iPhone before deleting.")
        }
        let guidance = requirements.isEmpty
            ? "Backitup will check every backup file again before deleting from the iPhone."
            : requirements.joined(separator: " ")
        return library.isICloudPhotosEnabled
            ? guidance + " iCloud Photos is enabled, so deletion can also remove these items from other synced devices."
            : guidance
    }
    private var dateGroups: [PhotoDayGroup] {
        PhotoDayGroup.make(from: visible, newestFirst: newestPhotosFirst)
    }
    private var rootURL: URL? { backupFolderPath.isEmpty ? nil : URL(fileURLWithPath: backupFolderPath, isDirectory: true) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                Group {
                    switch section {
                    case .library: libraryView
                    case .backups: backupView
                    case .storage: storageView
                    }
                }
                bottomBar
            }
        }
        .background(Color(red: 0.075, green: 0.09, blue: 0.11))
        .foregroundStyle(.white)
        .onReceive(library.$galleryAssets) { current in
            let available = Set(current.map(\.id))
            selected.formIntersection(available)
            if let selectionAnchorID, !available.contains(selectionAnchorID) {
                self.selectionAnchorID = nil
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(options: $exportOptions, selection: chosen, onCancel: {
                showExport = false
                returnToDeleteAfterExport = false
            }, onExport: {
                showExport = false
                beginExport()
            })
        }
        .sheet(isPresented: $showDelete, onDismiss: {
            if openExportAfterDeleteSheet {
                openExportAfterDeleteSheet = false
                showExport = true
            }
        }) {
            deleteSheet
        }
        .alert("Backitup", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var deleteSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "trash").foregroundStyle(.red)
                Text("Delete from iPhone?").font(.system(size: 20, weight: .semibold))
            }
            Text("\(verifiedSelectionCount) of \(selected.count) selected photos have verified backups, including related originals.")
                .font(.system(size: 13, weight: .medium))
            Text(deleteGuidance)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let backupError {
                Text("Backup needs attention: \(backupError)")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if verifiedSelectionCount < selected.count {
                Button("Back up \(selected.count - verifiedSelectionCount) remaining") {
                    backupRemainingForDeletion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!library.canTransfer || library.busy)
            }
            HStack(spacing: 10) {
                Button("Check backup") { checkBackups() }
                    .disabled(selected.isEmpty || library.busy)
                Button("Export selected…") {
                    returnToDeleteAfterExport = true
                    openExportAfterDeleteSheet = true
                    showDelete = false
                }
                .disabled(!library.canTransfer || selected.isEmpty || library.busy)
            }

            Divider()
            HStack {
                Button("Cancel") { showDelete = false }
                Spacer()
                if verifiedSelectionCount > 0 && verifiedSelectionCount < selected.count {
                    Button("Delete \(verifiedSelectionCount) backed-up items", role: .destructive) {
                        let assets = verifiedSelection
                        showDelete = false
                        deleteChosen(assets)
                    }
                    .disabled(rootURL == nil || !library.canDelete(Set(verifiedSelection.map(\.id))) || library.busy)
                } else {
                    Button("Delete \(selected.count) from iPhone", role: .destructive) {
                        let assets = chosen
                        showDelete = false
                        deleteChosen(assets)
                    }
                    .disabled(rootURL == nil || !library.canDelete(selected) || library.busy)
                }
            }
            if verifiedSelectionCount > 0 && verifiedSelectionCount < selected.count {
                Text("The other \(selected.count - verifiedSelectionCount) selected item(s) will stay on the iPhone.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.title2).foregroundStyle(accent)
                Text("Backitup").font(.system(size: 19, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 30)

            Text("DEVICE").font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.6).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 10)
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3").font(.system(size: 23)).foregroundStyle(accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.deviceName ?? library.cachedDeviceName ?? "No iPhone connected").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(library.deviceName == nil ? (library.galleryAssets.isEmpty ? "Connect via USB" : "Saved photo catalog") : "Connected via Image Capture")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.bottom, 28)

            Text("WORKSPACE").font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.6).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 8)
            sideRow(.library, symbol: "photo.on.rectangle.angled")
            sideRow(.backups, symbol: "checkmark.shield")
            sideRow(.storage, symbol: "chart.pie")

            Text("MEDIA TYPES").font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.6).foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(MediaKind.allCases) { kind in
                        Button {
                            section = .library
                            kindFilter = kindFilter == kind ? nil : kind
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: kind.symbol).frame(width: 18)
                                Text(kind.rawValue)
                                Spacer()
                                Text("\(library.galleryAssets.filter { $0.kind == kind }.count)").foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12, weight: kindFilter == kind ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(kindFilter == kind && section == .library ? accent.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(.horizontal, 12)
            }

            Spacer(minLength: 14)
            VStack(alignment: .leading, spacing: 7) {
                Text("BACKUP LOCATION").font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                Text(rootURL?.lastPathComponent ?? "Choose a folder")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Button("Change folder…") { chooseFolder() }
                    .font(.system(size: 11)).buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            .padding(12)
        }
        .frame(width: 236)
        .background(Color(red: 0.055, green: 0.07, blue: 0.085))
    }

    private func sideRow(_ target: AppSection, symbol: String) -> some View {
        Button {
            section = target
            if target == .library { kindFilter = nil }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).frame(width: 18)
                Text(target.rawValue)
                Spacer()
                if target == .library { Text("\(library.galleryAssets.count)").foregroundStyle(.secondary) }
            }
            .font(.system(size: 13, weight: section == target ? .semibold : .medium))
            .padding(.horizontal, 14).padding(.vertical, 11)
            .foregroundStyle(section == target ? .white : Color.white.opacity(0.72))
            .background(section == target ? accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).padding(.horizontal, 12)
    }

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                topBarTitle
                Spacer()
                topBarControls
            }
            VStack(alignment: .leading, spacing: 10) {
                topBarTitle
                HStack(spacing: 14) { topBarControls }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topBarTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section == .library ? (kindFilter?.rawValue ?? "All Photos") : section.rawValue)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(section == .library ? "Browse and protect your iPhone memories" :
                 section == .storage ? "Measured photo and video usage" : "Check local copies before cleanup")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var topBarControls: some View {
        Group {
            if section == .library {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search filenames", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 120)
                    .padding(10).background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh iPhone photos").disabled(library.deviceName == nil)
            if section == .library {
                Button { groupPhotosByDate.toggle() } label: {
                    Image(systemName: groupPhotosByDate ? "rectangle.3.group.fill" : "rectangle.grid.3x2")
                        .foregroundStyle(groupPhotosByDate ? accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(groupPhotosByDate ? "Showing photos by date. Click for one grid." : "Showing one grid. Click to group by date.")
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.3x3")
                    Slider(value: $tileSize, in: 115...220).frame(width: 70)
                }.foregroundStyle(.secondary)
            }
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
            HStack(spacing: 12) {
                Text("\(visible.count.formatted()) items").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                if library.isLoading { ProgressView().controlSize(.small); Text("Reading iPhone…").font(.system(size: 11)).foregroundStyle(.secondary) }
                Menu {
                    Button { newestPhotosFirst = true } label: {
                        Label("Newest first", systemImage: newestPhotosFirst ? "checkmark" : "arrow.down")
                    }
                    Button { newestPhotosFirst = false } label: {
                        Label("Oldest first", systemImage: newestPhotosFirst ? "arrow.up" : "checkmark")
                    }
                } label: {
                    Label(newestPhotosFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort photos by capture date")
                Button { showingDateFilter.toggle() } label: {
                    Label("Dates", systemImage: "calendar")
                        .foregroundStyle(dateRange.isActive ? accent : .white)
                }
                .help("Filter photos by capture date")
                .popover(isPresented: $showingDateFilter, arrowEdge: .bottom) { dateFilterPopover }
                Spacer()
                Button("Select visible") {
                    selectionAnchorID = selectionAnchorID ?? visible.first?.id
                    selected.formUnion(visible.map(\.id))
                }.disabled(visible.isEmpty)
                Button("Clear selection") {
                    selected.removeAll()
                    selectionAnchorID = nil
                }.disabled(selected.isEmpty)
            }
            .font(.system(size: 11)).buttonStyle(.plain)
            .padding(.horizontal, 26).frame(height: 43)
            }.scrollIndicators(.hidden)
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            if visible.isEmpty { emptyLibrary }
            else {
                ScrollView {
                    if groupPhotosByDate {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(dateGroups) { group in
                                Section {
                                    assetGrid(group.assets)
                                        .padding(.horizontal, 22)
                                        .padding(.bottom, 18)
                                } header: {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(group.title).font(.system(size: 19, weight: .bold, design: .rounded))
                                        Text("\(group.assets.count.formatted())")
                                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 24).padding(.vertical, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(red: 0.075, green: 0.09, blue: 0.11).opacity(0.97))
                                }
                            }
                        }
                    } else {
                        assetGrid(visible).padding(22)
                    }
                }
            }
        }
    }

    private var dateFilterPopover: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Capture date").font(.system(size: 16, weight: .semibold))
            HStack {
                Toggle("From", isOn: $useFromDate).frame(width: 85, alignment: .leading)
                DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    .labelsHidden().disabled(!useFromDate)
            }
            HStack {
                Toggle("Through", isOn: $useThroughDate).frame(width: 85, alignment: .leading)
                DatePicker("Through", selection: $throughDate, displayedComponents: .date)
                    .labelsHidden().disabled(!useThroughDate)
            }
            if useFromDate && useThroughDate &&
                Calendar.current.startOfDay(for: fromDate) > Calendar.current.startOfDay(for: throughDate) {
                Text("From must be on or before Through.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                Button("Clear dates") {
                    useFromDate = false
                    useThroughDate = false
                }
                .disabled(!dateRange.isActive)
                Spacer()
                Button("Done") { showingDateFilter = false }
            }
            .font(.system(size: 12))
        }
        .padding(18).frame(width: 310)
    }

    private func assetGrid(_ assets: [PhotoAsset]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 12)], spacing: 12) {
            ForEach(assets) { asset in
                AssetTile(asset: asset, image: library.thumbnails[asset.id], selected: selected.contains(asset.id),
                          backup: library.backupStates[asset.id], size: tileSize) {
                    selectAsset(asset)
                }
                .onAppear { library.requestThumbnail(for: asset.id) }
                .onDisappear { library.releaseThumbnail(for: asset.id) }
            }
        }
    }

    private func selectAsset(_ asset: PhotoAsset) {
        if (NSApp.currentEvent?.modifierFlags.contains(.shift) == true || NSEvent.modifierFlags.contains(.shift)),
           let anchorID = selectionAnchorID ?? visible.first(where: { selected.contains($0.id) })?.id {
            let orderedIDs = visible.map(\.id)
            if let start = orderedIDs.firstIndex(of: anchorID),
               let end = orderedIDs.firstIndex(of: asset.id) {
                selected.formUnion(orderedIDs[min(start, end)...max(start, end)])
                selectionAnchorID = anchorID
                return
            }
        }
        if selected.contains(asset.id) { selected.remove(asset.id) }
        else { selected.insert(asset.id) }
        selectionAnchorID = selected.contains(asset.id) ? asset.id : nil
    }

    private var emptyLibrary: some View {
        let noCatalog = library.galleryAssets.isEmpty
        let needsUnlock = noCatalog && library.status.localizedCaseInsensitiveContains("unlock")
        let loading = noCatalog && library.isLoading && library.deviceName != nil
        return VStack(spacing: 14) {
            Spacer()
            Image(systemName: library.deviceName == nil ? "iphone.slash" : needsUnlock ? "lock.iphone" : loading ? "arrow.triangle.2.circlepath" : "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(accent)
            Text(noCatalog && library.deviceName == nil ? "Connect your iPhone" : needsUnlock ? "Unlock your iPhone" : loading ? "Reading your photos" : "No photos in this view")
                .font(.system(size: 20, weight: .semibold))
            Text(noCatalog && library.deviceName == nil ? "Unlock it, tap Trust if asked, and keep it connected by USB." : needsUnlock ? "Tap Trust if asked. Backitup will retry automatically." : loading ? "Keep your iPhone unlocked while the catalog loads." : "Change the date, media type, or search filters.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if library.deviceName != nil {
                Button("Retry connection") { library.refresh() }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .padding(.top, 8)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private var backupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCard(title: "Backup confidence", symbol: "checkmark.shield.fill",
                            detail: "Backitup records each exported file and checks its SHA-256 digest before an iPhone deletion.")
                HStack(spacing: 12) {
                    statCard("Verified", count: library.backupStates.values.filter { $0 == .verified }.count, tint: .green)
                    statCard("Copies only", count: library.backupStates.values.filter { $0 == .partial }.count, tint: .yellow)
                    statCard("Not backed up", count: library.backupStates.values.filter { $0 == .missing }.count, tint: .orange)
                    statCard("Changed", count: library.backupStates.values.filter { $0 == .changed }.count, tint: .red)
                }
                Text("Choose photos in All Photos, then Check backup or Export selected. Verification covers files exported by Backitup into the selected backup folder.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let rootURL {
                    Label(rootURL.path, systemImage: "folder").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(28).frame(maxWidth: 850, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storageView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summaryCard(title: "iPhone photo storage", symbol: "chart.pie.fill",
                            detail: "File sizes are measured from the photos and videos this iPhone exposes to macOS Image Capture.")
                let photos = library.assets.filter { !$0.isVideo }.reduce(Int64(0)) { $0 + $1.bytes }
                let videos = library.assets.filter(\.isVideo).reduce(Int64(0)) { $0 + $1.bytes }
                HStack(spacing: 12) {
                    storageCard("Photos", value: photos, symbol: "photo.fill", tint: accent)
                    storageCard("Videos", value: videos, symbol: "video.fill", tint: .purple)
                    storageCard("Visible media", value: photos + videos, symbol: "externaldrive.fill", tint: .teal)
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        if photos > 0 { accent.frame(width: geo.size.width * CGFloat(Double(photos) / Double(max(photos + videos, 1)))) }
                        if videos > 0 { Color.purple }
                    }.clipShape(RoundedRectangle(cornerRadius: 5))
                }.frame(height: 12)
                HStack(spacing: 20) {
                    Label("Photos", systemImage: "circle.fill").foregroundStyle(accent)
                    Label("Videos", systemImage: "circle.fill").foregroundStyle(.purple)
                }.font(.system(size: 11))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(MediaKind.allCases) { kind in
                        let items = library.assets.filter { $0.kind == kind }
                        HStack {
                            Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(accent)
                            Text(kind.rawValue)
                            Spacer()
                            Text("\(items.count.formatted()) items").foregroundStyle(.secondary)
                            Text(formattedBytes(items.reduce(Int64(0)) { $0 + $1.bytes }))
                                .frame(width: 90, alignment: .trailing)
                        }
                        .font(.system(size: 12)).padding(.vertical, 12)
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
                Text("Apps, System Data, free space, and iCloud-only assets are not available through Apple's public photo-device API. These figures are an inventory of accessible media, not a total-device capacity chart.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 850, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryCard(title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(accent).frame(width: 36)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 18, weight: .bold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(22)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
    private func statCard(_ title: String, count: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(count.formatted())").font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(tint)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(17)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    private func storageCard(_ title: String, value: Int64, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(formattedBytes(value)).font(.system(size: 21, weight: .bold, design: .rounded))
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    statusContent
                    Spacer(minLength: 10)
                    if section == .library { selectionActions }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) { statusContent }
                    if section == .library {
                        HStack(spacing: 10) { selectionActions }
                    }
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(red: 0.06, green: 0.075, blue: 0.09))
    }

    private var statusContent: some View {
        Group {
            Image(systemName: "info.circle").foregroundStyle(accent)
            Text(library.status).lineLimit(1).truncationMode(.tail).help(library.status)
            if library.deleting {
                if let fraction = library.deletionFraction {
                    ProgressView(value: fraction).frame(width: 80)
                    Text("\(Int(fraction * 100))%")
                } else {
                    ProgressView().frame(width: 80)
                    Text("Waiting for iPhone")
                }
            } else if library.busy && library.total > 0 {
                ProgressView(value: Double(library.completed), total: Double(library.total)).frame(width: 80)
                Text("\(library.completed)/\(library.total)")
            }
        }
    }

    private var selectionActions: some View {
        Group {
            Text("\(selected.count) selected").foregroundStyle(.secondary)
            Button("Check backup") { checkBackups() }.disabled(selected.isEmpty || library.busy)
            Button {
                showExport = true
            } label: { Label("Export selected", systemImage: "square.and.arrow.down") }
            .buttonStyle(.borderedProminent).tint(accent).disabled(selected.isEmpty || library.busy || !library.canTransfer)
            .help(library.canTransfer ? "Export selected files to your Mac" : "Unlock and reconnect the iPhone to export")
            Button { showDelete = true } label: { Label("Delete…", systemImage: "trash") }
                .buttonStyle(.bordered).tint(.red)
                .disabled(selected.isEmpty || library.busy)
                .help(selected.isEmpty ? "Select photos to prepare deletion" : deleteGuidance)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Backup Folder"
        if panel.runModal() == .OK, let url = panel.url { backupFolderPath = url.path; libraryStatusForNewFolder() }
    }

    private func libraryStatusForNewFolder() {
        library.setBackupStates(Dictionary(uniqueKeysWithValues: library.assets.map { ($0.id, .unknown) }))
    }

    private func beginExport() {
        let returnToDelete = returnToDeleteAfterExport
        returnToDeleteAfterExport = false
        runExport(assets: chosen, options: exportOptions, returnToDelete: returnToDelete)
    }

    private func backupRemainingForDeletion() {
        if rootURL == nil { chooseFolder() }
        guard rootURL != nil else { return }
        let verifiedIDs = Set(verifiedSelection.map(\.id))
        let remaining = chosen.filter { !verifiedIDs.contains($0.id) }
        guard !remaining.isEmpty else { return }
        var options = exportOptions
        options.kinds = Set(MediaKind.allCases)
        options.includeLiveVideos = true
        options.includePortraitOriginals = true
        options.includeBurstFrames = true
        options.includeEditedOriginals = true
        options.convertHEIC = false
        options.convertHEVC = false
        showDelete = false
        runExport(assets: remaining, options: options, returnToDelete: true)
    }

    private func runExport(assets: [PhotoAsset], options: ExportOptions, returnToDelete: Bool) {
        guard library.canTransfer else {
            errorMessage = "Unlock and reconnect the iPhone before exporting. Your saved photo catalog remains available for browsing."
            return
        }
        if rootURL == nil { chooseFolder() }
        guard let rootURL else { return }
        let selectionAtStart = selected
        backupError = nil
        library.startProgress(total: assets.count, message: "Preparing backup…")
        Task {
            do {
                let result = try await BackupService().export(assets: assets, library: library, root: rootURL, options: options) { done, total, message in
                    DispatchQueue.main.async {
                        library.updateProgress(done, total: total, message: message)
                    }
                }
                library.stopProgress("Backup finished: \(result.exported) new, \(result.skipped) already verified, \(result.failures.count) failed.")
                if !result.failures.isEmpty {
                    let details = result.failures.prefix(3).joined(separator: "\n")
                    let remaining = result.failures.count - min(result.failures.count, 3)
                    backupError = "\(result.failures.count) item(s) could not be backed up.\n" + details
                        + (remaining > 0 ? "\n…and \(remaining) more failed items." : "")
                    if !returnToDelete { errorMessage = backupError }
                }
                library.setBackupStates(result.states)
                if returnToDelete && selectionAtStart == selected { showDelete = true }
            } catch {
                library.stopProgress("Backup stopped")
                if returnToDelete {
                    backupError = error.localizedDescription
                    checkBackups(returnToDelete: true)
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func checkBackups(returnToDelete: Bool = false) {
        if rootURL == nil { chooseFolder() }
        guard let rootURL else { return }
        let selectedIDs = Set(chosen.map(\.id))
        let targetIDs = DeviceLibrary.deletionTargetIDs(for: selectedIDs, assets: library.assets, galleryAssets: library.galleryAssets)
        let assets = library.assets.filter { targetIDs.contains($0.id) }
        library.setBackupStates(Dictionary(uniqueKeysWithValues: assets.map { ($0.id, .checking) }))
        library.startProgress(total: assets.count, message: "Checking local backup files…")
        Task.detached {
            let service = BackupService()
            let manifest = service.loadManifest(at: rootURL)
            var pending: [String: BackupState] = [:]
            var lastUpdate = Date()
            for (index, asset) in assets.enumerated() {
                pending[asset.id] = service.verify(asset, at: rootURL, manifest: manifest)
                if pending.count >= 20 || Date().timeIntervalSince(lastUpdate) >= 0.25 || index == assets.count - 1 {
                    let batch = pending
                    pending.removeAll(keepingCapacity: true)
                    lastUpdate = Date()
                    await MainActor.run {
                        library.setBackupStates(batch)
                        library.updateProgress(index + 1, total: assets.count,
                                               message: "Checked \(index + 1) of \(assets.count) source files")
                    }
                }
            }
            await MainActor.run {
                library.stopProgress("Backup check complete: \(assets.filter { library.backupStates[$0.id] == .verified }.count) of \(assets.count) source files verified.")
                if returnToDelete && selectedIDs == selected {
                    showDelete = true
                }
            }
        }
    }

    private func deleteChosen(_ assets: [PhotoAsset]) {
        // Verification is repeated immediately before the destructive device request.
        guard let rootURL, !assets.isEmpty else { return }
        let targetIDs = DeviceLibrary.deletionTargetIDs(for: Set(assets.map(\.id)), assets: library.assets, galleryAssets: library.galleryAssets)
        let targets = library.assets.filter { targetIDs.contains($0.id) }
        library.startProgress(total: targets.count, message: "Rechecking backups before deletion…")
        Task.detached {
            let service = BackupService()
            let manifest = service.loadManifest(at: rootURL)
            var states: [(String, BackupState)] = []
            for asset in targets { states.append((asset.id, service.verify(asset, at: rootURL, manifest: manifest))) }
            let checkedStates = states
            await MainActor.run {
                library.setBackupStates(Dictionary(uniqueKeysWithValues: checkedStates))
                library.stopProgress("Pre-delete backup check complete")
                let safeIDs = DeviceLibrary.verifiedGalleryIDs(Set(assets.map(\.id)), assets: library.assets,
                                                               galleryAssets: library.galleryAssets, states: library.backupStates)
                guard !safeIDs.isEmpty else {
                    errorMessage = "The selected backups are missing or changed. No items were deleted."
                    return
                }
                library.deleteVerified(safeIDs) { result in
                    switch result {
                    case .success:
                        selected.subtract(safeIDs)
                        selectionAnchorID = nil
                        if safeIDs.count < assets.count {
                            errorMessage = "Some backup files changed during the check. Those items remain on the iPhone."
                        }
                    case .failure(let error): errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

private struct AssetTile: View {
    @State private var isHovering = false
    let asset: PhotoAsset
    let image: NSImage?
    let selected: Bool
    let backup: BackupState?
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06))
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size * 0.82).clipped()
                } else {
                    Image(systemName: asset.isVideo ? "video" : "photo")
                        .font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color(red: 0.36, green: 0.62, blue: 1) : .white)
                        .background(.black.opacity(0.25), in: Circle())
                    Spacer()
                    if backup == .verified { Image(systemName: "checkmark.shield.fill").foregroundStyle(.green) }
                }.font(.system(size: 20)).padding(8)
                if isHovering || selected {
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            if asset.isVideo { Image(systemName: "play.fill") }
                            Text(asset.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(7).background(.black.opacity(0.65))
                    }
                } else if asset.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(6)
                        .background(.black.opacity(0.6), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(7)
                }
            }
            .frame(width: size, height: size * 0.82)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color(red: 0.36, green: 0.62, blue: 1) : .clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(asset.name), \(asset.date.formatted(date: .abbreviated, time: .shortened))\(asset.isVideo ? ", video" : "")")
        .help("\(asset.name) • \(asset.date.formatted()) • \(formattedBytes(asset.bytes)) • \(backup?.label ?? "Not checked")")
    }
}
