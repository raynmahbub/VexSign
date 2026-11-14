import SwiftUI
import NimbleExtensions

struct DiscoveryView: View {
    @StateObject private var model = DiscoveryViewModel()
    @State private var query = ""
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(.localized("DISCOVER")).font(.caption.bold())
                    Text(.localized("Your sources.\nA world of apps.")).font(.largeTitle.bold())
                    Text(.localized("Explore your repositories with local, private recommendations.")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                if model.loading && model.apps.isEmpty {
                    ProgressView(.localized("Indexing repositories…")).frame(maxWidth: .infinity)
                    RoundedRectangle(cornerRadius: 22).fill(.quaternary).frame(height: 140).redacted(reason: .placeholder)
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                if !query.isEmpty {
                    ForEach(model.results) { card($0) }
                } else {
                    carousel(.localized("Featured"), apps: Array(model.results.prefix(8)))
                    carousel(.localized("Trending on This Device"), apps: model.results.sorted { model.signals.downloads[$0.id, default: 0] > model.signals.downloads[$1.id, default: 0] }.prefix(10).map { $0 })
                    carousel(.localized("Recommended"), apps: Array(model.results.prefix(12)))
                    ForEach(model.collections) { collection in
                        NavigationLink(collection.title) {
                            ScrollView { LazyVStack { ForEach(collection.apps) { card($0) } }.padding() }.navigationTitle(collection.title)
                        }.font(.title2.bold())
                    }
                    Text(.localized("Categories")).font(.title2.bold())
                    ForEach(model.categories) { category in
                        NavigationLink(String.localized("%@ · %lld", arguments: category.name, category.apps.count)) {
                            ScrollView { LazyVStack { ForEach(category.apps) { card($0) } }.padding() }.navigationTitle(category.name)
                        }
                    }
                }
                if model.apps.isEmpty && !model.loading {
                    Text(.localized("Add repositories in Sources, then pull to refresh.")).foregroundStyle(.secondary)
                }
            }.padding()
        }
        .navigationTitle(.localized("Discovery"))
        .searchable(text: $query)
        .searchSuggestions { ForEach(Array(model.results.prefix(5))) { Text($0.name).searchCompletion($0.name) } }
        .task { await model.load() }
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 180_000_000); await model.search(query) } catch { }
        }
        .refreshable { await model.load(force: true); await model.search(query) }
    }
    private func carousel(_ title: String, apps: [DiscoveryApp]) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack { ForEach(apps) { card($0).frame(width: 300) } }
            }
        }
    }
    private func card(_ app: DiscoveryApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AsyncImage(url: app.icon) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading) { Text(app.name).font(.headline).lineLimit(2); Text(app.developer).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { Task { await model.favorite(app) } } label: {
                    Image(systemName: model.signals.favorites.contains(app.id) ? "heart.fill" : "heart")
                }.accessibilityLabel(String.localized("Favorite %@", arguments: app.name))
            }
            Text(app.summary).font(.subheadline).lineLimit(3).frame(minHeight: 40, alignment: .top)
            HStack {
                let allVersions = model.versions(for: app.bundleIdentifier)
                if allVersions.count > 1 {
                    Menu {
                        ForEach(allVersions) { v in
                            Button {
                                Task { await model.download(v) }
                            } label: {
                                let sourceLabel = URL(string: v.source)?.host ?? v.source
                                Text(String.localized("v%@ • %@", arguments: v.version, sourceLabel))
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(String.localized("v%@", arguments: app.version))
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(app.version).font(.caption)
                }
                Spacer()
                Button(.localized("Get")) { Task { await model.download(app) } }.buttonStyle(.borderedProminent).disabled(app.download == nil)
            }
        }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}
