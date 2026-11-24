import SwiftUI
import Charts
import UIKit

struct FeedarrStatsView: View {
    let manager: FeedarrSourcesManager
    let isVisible: Bool
    @State private var model: FeedarrStatsModel?
    @State private var days = 30
    @State private var chartReferenceDate = Date()
    private let activity = FeedarrActivityStore.shared

    private var currentModel: FeedarrStatsModel? {
        guard let model, model.revision == manager.configurationRevision else { return nil }
        return model
    }
    private var overview: FeedarrStatsOverview? { currentModel?.overviews[days] }

    var body: some View {
        List {
            if let error = manager.loadError {
                Section("Serveur") { Text(error.localizedDescription).foregroundStyle(.secondary) }
            } else if manager.source == nil {
                Section("Serveur") { Text("Ajoutez un serveur dans Réglages pour consulter ses statistiques.") }
            } else {
                serverSections
            }
            activitySections
        }
        .navigationTitle("Stats")
        .toolbarTitleDisplayMode(.inlineLarge)
        .task(id: LoadID(visible: isVisible, revision: manager.configurationRevision, days: days)) {
            guard isVisible else { model?.cancel(); return }
            if model == nil { model = FeedarrStatsModel(manager: manager) }
            chartReferenceDate = Date()
            await model?.load(days: days)
        }
        .onDisappear { model?.cancel() }
        .refreshable {
            guard isVisible else { return }
            chartReferenceDate = Date()
            await model?.load(days: days, force: true)
        }
    }

    @ViewBuilder
    private var serverSections: some View {
        if currentModel == nil || (currentModel?.isLoading == true && currentModel?.summary == nil) {
            Section { ProgressView("Chargement des statistiques…") }
        }
        if let model = currentModel {
            let keys = ["summary", "status", "feedarr-\(days)", "releases"]
            let failures = keys.compactMap { key in model.errors[key].map { (key, $0) } }
            if !failures.isEmpty {
                Section("Statistiques indisponibles ou non actualisées") {
                    ForEach(failures, id: \.0) { key, message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key == "summary" ? "Résumé" : key == "status" ? "Dernière synchronisation" : key == "releases" ? "Catégories" : "Évolution et applications")
                                .font(.headline)
                            Text(message).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Text("Les données déjà reçues restent affichées. Tirez pour actualiser ; les limites du serveur sont respectées.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        Section {
            if let source = manager.source { LabeledContent("Serveur", value: source.name) }
            number("Releases totales", overview?.releasesCount ?? currentModel?.summary?.releasesCount)
            number("Releases avec poster associé", overview?.releasesWithPoster ?? currentModel?.releases?.withPoster)
            if let percent = overview?.matchingPercent ?? currentModel?.summary?.matchingPercent {
                LabeledContent("Couverture des posters") {
                    Text("\(percent) %")
                        .foregroundStyle(percent <= 75 ? Color.red : percent <= 91 ? Color.orange : Color.green)
                }
            } else {
                unavailable("Couverture des posters")
            }
            number("Indexeurs actifs", currentModel?.summary?.activeIndexers)
            LabeledContent("Version", value: currentModel?.summary?.version ?? "Indisponible")
            LabeledContent("Dernière synchronisation", value: lastSyncLabel)
            if let uptime = currentModel?.summary?.uptimeSeconds, uptime >= 0 {
                LabeledContent("Temps de fonctionnement", value: Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
            } else {
                unavailable("Temps de fonctionnement")
            }
        } header: {
            Text("Serveur Feedarr")
        } footer: {
            Text("La couverture mesure les releases avec poster associé, pas le matching TMDB. Cache mémoire : 5 minutes.")
        }
        Section {
            if let categories = currentModel?.releases?.releasesByCategory, !categories.isEmpty {
                FeedarrCategoryRows(categories: categories)
            } else {
                Text(currentModel?.releases?.releasesByCategory == nil ? "Données indisponibles." : "Aucune catégorie enregistrée.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Releases par catégorie")
        } footer: {
            Text("Jusqu’aux 15 catégories renvoyées par le serveur.")
        }
        Section {
            VStack(spacing: 16) {
                Picker("Période", selection: $days) {
                    Text("7 jours").tag(7)
                    Text("30 jours").tag(30)
                    Text("90 jours").tag(90)
                }
                .pickerStyle(.segmented)
                dailyChart
            }
        } header: {
            Text("Évolution quotidienne")
        } footer: {
            Text("Releases ajoutées au catalogue par jour UTC ; ce graphique ne représente pas les téléchargements.")
        }
        Section("Sonarr et Radarr") {
            number("Releases présentes dans Sonarr", overview?.sonarrMatchedCount)
            number("Releases présentes dans Radarr", overview?.radarrMatchedCount)
            if let apps = overview?.arrApps {
                let supported = apps.filter { ["sonarr", "radarr"].contains($0.type.lowercased()) }
                if supported.isEmpty {
                    Text("Aucune application Sonarr/Radarr configurée.").foregroundStyle(.secondary)
                }
                ForEach(supported) { app in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.name).font(.headline)
                        Text("\(app.type.capitalized) · \(app.enabled ? "Activé" : "Désactivé")")
                            .font(.subheadline).foregroundStyle(.secondary)
                        number("Éléments en bibliothèque", app.libraryCount)
                        number("Éléments à la dernière synchronisation", app.lastSyncCount)
                        if let raw = app.lastSyncAt, let date = syncDate(raw) {
                            LabeledContent("Dernière synchronisation") {
                                Text(date, format: .dateTime.day().month().year().hour().minute())
                            }
                        }
                    }
                }
            } else {
                Text("Applications indisponibles.").foregroundStyle(.secondary)
            }
        }
    }

    // The picker and chart stay in one List row, even while a new period is loading.
    // Keep the Chart mounted and reserve the same space for its loading/empty state.
    private var dailyChart: some View {
        let series = overview?.releasesPerDay ?? []
        let validSeries = series.filter { $0.timestamp != nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: chartReferenceDate)
        let start = calendar.date(byAdding: .day, value: -days, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let maximum = max(validSeries.map(\.count).max() ?? 0, 1)
        return Chart(validSeries) { point in
            if let date = point.timestamp {
                BarMark(x: .value("Date", date, unit: .day), y: .value("Releases ajoutées", point.count))
                    .accessibilityLabel(point.date)
                    .accessibilityValue(point.count.formatted())
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...(Double(maximum) * 1.1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.day().month())
                            .padding(.top, 10)
                    }
                }
            }
        }
        .chartPlotStyle { plot in plot.padding(.horizontal, 6).padding(.top, 8) }
        // Reserve the extra label spacing without reducing the plot's height.
        .frame(height: 250)
        .overlay {
            if validSeries.isEmpty {
                if overview == nil && currentModel?.isLoading == true {
                    ProgressView("Chargement…")
                } else {
                    Text(overview?.releasesPerDay == nil ? "Données indisponibles." : "Aucune release ajoutée sur cette période.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .environment(\.timeZone, calendar.timeZone)
        .environment(\.calendar, calendar)
        // Axis/domain updates must not interpolate through a different period inside List.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private var activitySections: some View {
        let history = activity.history
        let distinct = Set(history.filter { $0.kind == .releaseOpened }.map { "\($0.serverID):\($0.releaseID)" }).count
        Section {
            LabeledContent("Consultations totales", value: activity.openingCount.formatted())
            LabeledContent("Releases distinctes consultées", value: distinct.formatted())
            LabeledContent("Tentatives de téléchargement", value: activity.downloadCount.formatted())
            LabeledContent("Exports confirmés", value: activity.count(.exportSucceeded).formatted())
            LabeledContent("Échecs", value: activity.count(.failed).formatted())
            LabeledContent("Annulations", value: activity.count(.cancelled).formatted())
            LabeledContent("Magnets copiés", value: activity.count(.magnetCopied).formatted())
            LabeledContent("Résultats inconnus / en cours", value: activity.count(.unknown).formatted())
        } header: {
            Text("Mon activité")
        } footer: {
            Text("Uniquement l’activité de cet appareil, sur l’historique conservé : 500 événements maximum et 90 jours, tous serveurs confondus.")
        }
        // Same native Section / NavigationLink / Label structure as FeedarrSettingsView.
        Section("Historique local") {
            ForEach(FeedarrHistoryCategory.allCases) { category in
                NavigationLink {
                    FeedarrActivityHistoryView(manager: manager, category: category)
                } label: {
                    Label(category.title, systemImage: category.symbol)
                }
                .tint(.blue)
            }
        }
    }

    private var lastSyncLabel: String {
        guard let status = currentModel?.status else {
            return currentModel?.errors["status"] == nil ? "Chargement…" : "Indisponible"
        }
        guard let timestamp = status.lastSyncAtTs, timestamp > 0 else { return "Jamais synchronisé" }
        guard Double(timestamp) <= Date.distantFuture.timeIntervalSince1970 else { return "Indisponible" }
        let date = Date(timeIntervalSince1970: Double(timestamp))
        let calendar = Calendar.autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) { return "Aujourd’hui à " + formatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Hier à " + formatter.string(from: date) }
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func number(_ title: String, _ value: Int?) -> some View {
        LabeledContent(title, value: value.map { $0.formatted() } ?? "Indisponible")
    }
    private func unavailable(_ title: String) -> some View {
        LabeledContent(title, value: "Indisponible")
    }
    private func syncDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }
    private struct LoadID: Equatable {
        let visible: Bool
        let revision: UUID
        let days: Int
    }
}

/// Shared column widths keep labels, proportional bars and values aligned inside the card.
private struct FeedarrCategoryRows: View {
    let categories: [FeedarrStatsReleases.Category]
    @State private var availableWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var barHeight: CGFloat = 8

    private var labelWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize)
        let longest = categories.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(max(80, ceil(longest)), max(60, availableWidth * 0.45))
    }
    private var valueWidth: CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let longest = categories.map { ($0.count.formatted() as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(ceil(longest) + 2, availableWidth * 0.25)
    }

    var body: some View {
        let maximum = max(categories.map(\.count).max() ?? 0, 1)
        VStack(spacing: 16) {
            ForEach(categories) { category in
                HStack(alignment: .center, spacing: 12) {
                    Text(category.label)
                        .frame(width: labelWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(.blue)
                            .frame(width: geometry.size.width * CGFloat(max(category.count, 0)) / CGFloat(maximum))
                    }
                    .frame(height: barHeight)
                    .accessibilityHidden(true)
                    Text(category.count.formatted())
                        .monospacedDigit()
                        .frame(width: valueWidth, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: fontSize))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(category.label)
                .accessibilityValue(category.count.formatted())
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }
}

private enum FeedarrHistoryCategory: String, CaseIterable, Identifiable {
    case consultations, downloads
    var id: String { rawValue }
    var title: String { self == .consultations ? "Consultations" : "Téléchargements" }
    var symbol: String { self == .consultations ? "eye" : "arrow.down.circle" }
    var kind: FeedarrActivityEvent.Kind { self == .consultations ? .releaseOpened : .download }
    var emptyMessage: String {
        self == .consultations ? "Aucune consultation enregistrée." : "Aucun téléchargement enregistré."
    }
}

private struct FeedarrActivityHistoryView: View {
    let manager: FeedarrSourcesManager
    let category: FeedarrHistoryCategory
    private let activity = FeedarrActivityStore.shared

    private var events: [FeedarrActivityEvent] {
        activity.history.filter { $0.kind == category.kind }.sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView(category.title, systemImage: category.symbol,
                                       description: Text(category.emptyMessage))
            } else {
                List(events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.title ?? "Release #\(event.releaseID) — titre non enregistré")
                            .font(.headline)
                        Text(eventLabel(event)).font(.subheadline)
                        Text(serverLabel(event.serverID)).font(.caption).foregroundStyle(.secondary)
                        Text(event.date, format: .dateTime.day().month().year().hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.timeZone, TimeZone.autoupdatingCurrent)
    }

    private func serverLabel(_ id: UUID) -> String {
        manager.sources.first { $0.id == id }?.name ?? "Serveur non configuré"
    }
    private func eventLabel(_ event: FeedarrActivityEvent) -> String {
        if event.kind == .releaseOpened { return "Consultation d’une fiche" }
        switch event.outcome {
        case .exportSucceeded: return "Export / partage confirmé"
        case .failed: return "Téléchargement · échec"
        case .cancelled: return "Téléchargement · annulation"
        case .magnetCopied: return "Téléchargement · magnet copié"
        case .unknown, nil: return "Téléchargement · résultat inconnu / en cours"
        }
    }
}
