//
//  AppHaptics.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation

#if os(iOS)
import UIKit
#endif

enum AppHaptics {
    #if os(iOS)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let impactGenerator = UIImpactFeedbackGenerator(style: .light)
    #endif

    static func success() {
        #if os(iOS)
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if os(iOS)
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.warning)
        #endif
    }

    static func selection() {
        #if os(iOS)
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
        #endif
    }

    static func impact() {
        #if os(iOS)
        impactGenerator.prepare()
        impactGenerator.impactOccurred()
        #endif
    }
}
