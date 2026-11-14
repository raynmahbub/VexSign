//
//  AppearanceTintColorView.swift
//  VexSign — organized, high-contrast tint picker
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct AppearanceTintColorView: View {
    @AppStorage("VexSign.userTintColor") private var _selectedColorHex: String = "#848ef9"

    // Curated, organized palette — grouped conceptually, not random.
    private let _groups: [(title: String, items: [(name: String, hex: String)])] = [
        ("VexSign", [
            ("Default", "#848ef9"),
            ("V2", "#B496DC")
        ]),
        ("Vibrant", [
            ("Berry", "#ff7a83"),
            ("Fuchsia", "#FF2D55"),
            ("Peculiar", "#4860e8"),
            ("Cool Blue", "#4161F1")
        ]),
        ("System", [
            ("Protokolle", "#4CD964"),
            ("Clock", "#FF9500"),
            ("Sky", "#5394F7"),
            ("Blossom", "#e18aab")
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(_groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                        .padding(.horizontal, 2)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(group.items, id: \.hex) { option in
                                tintCard(option)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "paintbrush.fill")
                    .font(.caption)
                    .foregroundStyle(Color.userTint)
                Text(.localized("Tap a color to apply it across the app instantly."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
        .onChange(of: _selectedColorHex) { _, value in
            UIApplication.topViewController()?.view.window?.tintColor = UIColor(Color(hex: value))
        }
    }

    @ViewBuilder
    private func tintCard(_ option: (name: String, hex: String)) -> some View {
        let color = Color(hex: option.hex)
        let isSelected = _selectedColorHex.lowercased() == option.hex.lowercased()
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 30, height: 30)
                    .shadow(color: color.opacity(0.28), radius: 6, y: 3)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                }
            }
            .overlay(
                Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            Text(option.name)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: 84, height: 82)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? color : Color.primary.opacity(0.06), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                _selectedColorHex = option.hex
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .accessibilityLabel(Text(option.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
