//
//  StickerMotionEffect.swift
//  FoilTest
//
//  Created by Benjamin Pisano on 03/11/2024.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
public protocol StickerMotionEffect: ViewModifier { }

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
extension View {
    func applyTransform(for effect: some StickerMotionEffect) -> AnyView {
        AnyView(modifier(effect))
    }

    public func stickerMotionEffect(_ effect: some StickerMotionEffect) -> some View {
        environment(\.stickerMotionEffect, effect)
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
public extension EnvironmentValues {
    @Entry var stickerMotionEffect: any StickerMotionEffect = IdentityStickerMotionEffect()
}
