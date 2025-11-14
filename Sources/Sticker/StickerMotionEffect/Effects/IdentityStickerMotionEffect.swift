//
//  IdentityStickerMotionEffect.swift
//  Sticker
//
//  Created by Benjamin Pisano on 03/11/2024.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
public struct IdentityStickerMotionEffect: StickerMotionEffect {
    public func body(content: Content) -> some View {
        content
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
extension StickerMotionEffect where Self == IdentityStickerMotionEffect {
    public static var identity: Self {
        .init()
    }
}
