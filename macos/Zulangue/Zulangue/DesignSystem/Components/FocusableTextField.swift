// FocusableTextField.swift
// Zulangue 微交互组件库 — 文本输入框
// 权威:docs/redesign/redesign-plan.md §4.B.2.7
//
// 设计原则覆盖:
//   #1 4 状态视觉反馈(default/focus/error/disabled)✓
//   #2 motion ✓
//   #4 错误叙事(error 文字 + icon)✓
//   #5 focus ring(focus 时清晰可见)✓
//
// 用法:
//   @State var apiKey = ""
//   @State var error: String? = nil
//
//   FocusableTextField(
//       title: "Soniox API Key",
//       placeholder: "sk-...",
//       text: $apiKey,
//       error: error,
//       isSecure: true
//   )

import SwiftUI

struct FocusableTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var error: String? = nil
    var helpText: String? = nil
    var isSecure: Bool = false
    var isEnabled: Bool = true
    var leadingIcon: String? = nil
    var maxLength: Int? = nil

    @FocusState private var isFocused: Bool

    private var hasError: Bool { error != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label
            Text(title)
                .font(.sans11Medium)
                .foregroundColor(hasError ? .error : .textSecondary)

            // Input field
            HStack(spacing: 8) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .iconSizeSmall()
                        .foregroundColor(.textTertiary)
                }

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.sans12)
                .foregroundColor(.textPrimary)
                .focused($isFocused)
                .disabled(!isEnabled)
                .onChange(of: text) { _, newValue in
                    if let maxLength, newValue.count > maxLength {
                        text = String(newValue.prefix(maxLength))
                    }
                }

                // Char count(maxLength 时显示)
                if let maxLength {
                    Text("\(text.count)/\(maxLength)")
                        .font(.monoNum10)
                        .foregroundColor(.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(isEnabled ? Color.bgSurface : Color.bgPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .stroke(currentBorder, lineWidth: 1)
            )
            .focusRing(isFocused, cornerRadius: Radius.sm, intensity: .standard)
            .animation(Motion.microInteraction, value: isFocused)
            .animation(Motion.microInteraction, value: hasError)

            // Error or help text
            if let error {
                HStack(spacing: 4) {
                    Image(systemName: Icon.warning)
                        .iconSizeSmall()
                        .foregroundColor(.error)
                    Text(error)
                        .font(.sans11)
                        .foregroundColor(.error)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let helpText {
                Text(helpText)
                    .font(.sans11)
                    .foregroundColor(.textTertiary)
            }
        }
    }

    private var currentBorder: Color {
        if hasError { return .error }
        if isFocused { return .brandAccent }
        return .borderPanel
    }
}

#if DEBUG
struct FocusableTextField_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State var key1: String = ""
        @State var key3: String = "invalid"
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                FocusableTextField(
                    title: "Soniox API Key",
                    placeholder: "Paste your API key",
                    text: $key1,
                    helpText: "Get one at console.soniox.com",
                    leadingIcon: Icon.lock
                )
                FocusableTextField(
                    title: "Invalid Key",
                    placeholder: "...",
                    text: $key3,
                    error: "API key format is invalid"
                )
            }
            .padding(40)
            .background(Color.bgRoot)
            .frame(width: 400)
        }
    }
    static var previews: some View { PreviewWrapper() }
}
#endif
