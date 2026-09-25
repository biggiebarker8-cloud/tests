import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardPageView(
                title: "Overview",
                subtitle: "A single iPhone home base for Microsoft services with clear iOS-friendly pages.",
                accentColor: .blue,
                metrics: overviewMetrics,
                sections: overviewSections
            )
            .tabItem {
                Label("Overview", systemImage: "square.grid.2x2")
            }

            DashboardPageView(
                title: "Microsoft 365",
                subtitle: "Productivity tools grouped for everyday communication, files, and team execution.",
                accentColor: .indigo,
                metrics: microsoft365Metrics,
                sections: microsoft365Sections
            )
            .tabItem {
                Label("M365", systemImage: "person.2.crop.square.stack")
            }

            DashboardPageView(
                title: "Azure + Edge",
                subtitle: "Cloud, identity, security, browser workflows, and operational controls in one flow.",
                accentColor: .cyan,
                metrics: azureMetrics,
                sections: azureSections
            )
            .tabItem {
                Label("Azure", systemImage: "cloud")
            }

            DashboardPageView(
                title: "Apple Bridge",
                subtitle: "Keep Microsoft services smooth on iPhone with dedicated Safari, iOS, and handoff guidance.",
                accentColor: .green,
                metrics: appleBridgeMetrics,
                sections: appleBridgeSections
            )
            .tabItem {
                Label("iOS", systemImage: "iphone")
            }
        }
    }
}

private struct DashboardPageView: View {
    let title: String
    let subtitle: String
    let accentColor: Color
    let metrics: [QuickMetric]
    let sections: [DashboardSection]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HeroCard(title: title, subtitle: subtitle, accentColor: accentColor)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(metrics) { metric in
                            MetricCard(metric: metric, accentColor: accentColor)
                        }
                    }

                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title)
                                .font(.title3.weight(.semibold))

                            Text(section.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            ForEach(section.cards) { card in
                                FeatureCard(card: card, accentColor: accentColor)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
        }
    }
}

private struct HeroCard: View {
    let title: String
    let subtitle: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Unified Microsoft Experience")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(
                colors: [accentColor, accentColor.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct MetricCard: View {
    let metric: QuickMetric
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(metric.title, systemImage: metric.icon)
                .font(.headline)
                .foregroundStyle(accentColor)

            Text(metric.value)
                .font(.title2.bold())

            Text(metric.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct FeatureCard: View {
    let card: DashboardCard
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: card.icon)
                    .font(.headline)
                    .foregroundStyle(accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.headline)

                    Text(card.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(card.highlights, id: \.self) { highlight in
                    Label(highlight, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct QuickMetric: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let detail: String
    let icon: String
}

private struct DashboardSection: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let cards: [DashboardCard]
}

private struct DashboardCard: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let icon: String
    let highlights: [String]
}

private let overviewMetrics: [QuickMetric] = [
    QuickMetric(title: "Dashboards", value: "4", detail: "Dedicated pages for major product groups", icon: "rectangle.3.group"),
    QuickMetric(title: "Core Suites", value: "365 + Azure", detail: "Workflows grouped by productivity and cloud", icon: "apps.iphone"),
    QuickMetric(title: "Browser Paths", value: "Edge + Safari", detail: "Optimized browsing and handoff options", icon: "safari"),
    QuickMetric(title: "Focus", value: "iPhone First", detail: "Designed around mobile-friendly navigation", icon: "hand.tap")
]

private let overviewSections: [DashboardSection] = [
    DashboardSection(
        title: "Main Experience",
        description: "The home page keeps the whole ecosystem in one place while still separating each area into easy-to-scan pages.",
        cards: [
            DashboardCard(
                title: "Unified launchpad",
                summary: "Start from a single front door, then move into focused product dashboards.",
                icon: "square.grid.2x2.fill",
                highlights: [
                    "Central overview for Microsoft 365, Azure, Edge, and Apple bridge areas",
                    "Consistent card-based layout to reduce page-to-page friction",
                    "Simple mobile navigation built around tabs and stacked content"
                ]
            ),
            DashboardCard(
                title: "Operational visibility",
                summary: "Surface the products people need without burying them in one giant screen.",
                icon: "chart.bar.xaxis",
                highlights: [
                    "Summary metrics at the top of every page",
                    "Separate sections for collaboration, cloud, browsing, and device continuity",
                    "Expandable concept ready for deeper analytics later"
                ]
            )
        ]
    )
]

private let microsoft365Metrics: [QuickMetric] = [
    QuickMetric(title: "Work Apps", value: "Teams", detail: "Chat, meetings, and collaboration", icon: "message.badge"),
    QuickMetric(title: "Files", value: "OneDrive", detail: "Fast mobile access to shared content", icon: "folder"),
    QuickMetric(title: "Docs", value: "Office", detail: "Word, Excel, and PowerPoint entry points", icon: "doc.text"),
    QuickMetric(title: "Planning", value: "Planner", detail: "Tasks and work coordination", icon: "checklist")
]

private let microsoft365Sections: [DashboardSection] = [
    DashboardSection(
        title: "Productivity dashboards",
        description: "Group daily Microsoft apps so iPhone users can jump directly into the right workflow.",
        cards: [
            DashboardCard(
                title: "Communication center",
                summary: "Teams, Outlook, and calendar tools aligned for fast updates and meeting readiness.",
                icon: "person.2.wave.2",
                highlights: [
                    "Meeting, mail, and chat views organized together",
                    "Designed for quick mobile actions instead of deep desktop navigation",
                    "Supports a clean handoff between messages, calls, and follow-up work"
                ]
            ),
            DashboardCard(
                title: "Document workspace",
                summary: "Access files, notes, and shared documents without switching between disconnected screens.",
                icon: "doc.on.doc",
                highlights: [
                    "OneDrive and SharePoint concepts grouped under one content area",
                    "Fast paths into Word, Excel, and PowerPoint workflows",
                    "Clear structure for recent items, shared libraries, and favorites"
                ]
            )
        ]
    )
]

private let azureMetrics: [QuickMetric] = [
    QuickMetric(title: "Cloud", value: "Azure", detail: "Compute, data, AI, and operations", icon: "server.rack"),
    QuickMetric(title: "Identity", value: "Entra", detail: "Access and sign-in management", icon: "person.text.rectangle"),
    QuickMetric(title: "Security", value: "Defender", detail: "Protection and posture insights", icon: "shield"),
    QuickMetric(title: "Browser", value: "Edge", detail: "Managed browsing and work profiles", icon: "globe")
]

private let azureSections: [DashboardSection] = [
    DashboardSection(
        title: "Cloud and browser operations",
        description: "Keep enterprise cloud controls and browsing experiences connected instead of split across unrelated tools.",
        cards: [
            DashboardCard(
                title: "Azure operations page",
                summary: "Show important cloud domains as separate cards for services, alerts, and environment visibility.",
                icon: "cloud.bolt",
                highlights: [
                    "Ready to branch into compute, storage, data, AI, and monitoring modules",
                    "Useful for service status, environment summaries, and deployment health",
                    "Fits mobile review workflows where speed matters more than full admin depth"
                ]
            ),
            DashboardCard(
                title: "Edge workspace",
                summary: "Treat the Microsoft browser as a first-class experience beside Azure instead of a disconnected add-on.",
                icon: "safari.fill",
                highlights: [
                    "Dedicated space for work profiles, collections, and secure browsing habits",
                    "Good fit for sign-in continuity between mobile apps and web properties",
                    "Creates a smoother path into Microsoft web apps on iPhone"
                ]
            )
        ]
    )
]

private let appleBridgeMetrics: [QuickMetric] = [
    QuickMetric(title: "Platform", value: "iOS", detail: "Touch-first app organization", icon: "iphone.gen3"),
    QuickMetric(title: "Browser", value: "Safari", detail: "Apple-native browsing path", icon: "safari"),
    QuickMetric(title: "Continuity", value: "Handoff", detail: "Move between apps and browser sessions", icon: "arrow.left.arrow.right"),
    QuickMetric(title: "Access", value: "Widgets", detail: "Fast glanceable entry points", icon: "rectangle.3.offgrid")
]

private let appleBridgeSections: [DashboardSection] = [
    DashboardSection(
        title: "iPhone optimization",
        description: "Balance Microsoft services with Apple-native behaviors so the app feels smoother on iPhone.",
        cards: [
            DashboardCard(
                title: "Safari compatibility page",
                summary: "Give Safari its own dashboard so Apple-first users still have a clean Microsoft experience.",
                icon: "safari",
                highlights: [
                    "Highlights browser-specific sign-in and navigation considerations",
                    "Provides room for saved shortcuts to key Microsoft web experiences",
                    "Keeps Safari support visible instead of hidden behind Edge-only flows"
                ]
            ),
            DashboardCard(
                title: "iOS convenience layer",
                summary: "Plan for notifications, widgets, quick actions, and deep links that reduce repeated taps.",
                icon: "sparkles",
                highlights: [
                    "Supports faster entry into the right dashboard from the home screen",
                    "Creates cleaner transitions between native app pages and browser pages",
                    "Improves the feeling of one connected system on iPhone"
                ]
            )
        ]
    )
]
