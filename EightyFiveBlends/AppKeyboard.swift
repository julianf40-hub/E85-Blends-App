//
//  AppKeyboard.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

enum AppKeyboard {
    static func dismiss() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

private struct KeyboardDoneToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    AppKeyboard.dismiss()
                }
            }
        }
    }
}

private struct DismissKeyboardOnTapModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture().onEnded {
                AppKeyboard.dismiss()
            }
        )
    }
}

extension View {
    func keyboardDoneToolbar() -> some View {
        modifier(KeyboardDoneToolbarModifier())
    }

    func dismissKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTapModifier())
    }
}
