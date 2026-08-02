//
//  VisibilityPickerView.swift
//  Inditalk
//
//  Shared radio-style picker for the privacy visibility settings (Last Seen,
//  Profile Photo, About). Writes straight back into DataStore.privacy through
//  the binding handed over by PrivacySettingsView.
//

import SwiftUI

struct VisibilityPickerView: View {
    let title: String
    let footer: String
    @Binding var selection: PrivacySettings.Visibility

    var body: some View {
        List {
            Section {
                ForEach(PrivacySettings.Visibility.allCases) { option in
                    Button {
                        guard option != selection else { return }
                        selection = option
                        Haptics.selection()
                    } label: {
                        HStack {
                            Text(option.label).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                    }
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
                }
                .listRowBackground(Palette.surface)
            } footer: {
                Text(footer)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
