//
//  PointerHoverStickerMotionEffect.swift
//  FoilTest
//
//  Created by Benjamin Pisano on 03/11/2024.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
public struct PointerHoverStickerMotionEffect: StickerMotionEffect {
    let intensity: Double

    @State private var transform: StickerTransform = .neutral

    @Environment(\.stickerShaderUpdater) private var shaderUpdater

    public func body(content: Content) -> some View {
        content
            .withViewSize { view, size in
                let xRotation: Double = (transform.x / size.width) * intensity
                let yRotation: Double = (transform.y / size.height) * intensity
                view
                    .rotation3DEffect(.radians(xRotation), axis: (0, 1, 0))
                    .rotation3DEffect(.radians(yRotation), axis: (-1, 0, 0))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            transform = .init(
                                x: location.x - size.width / 2,
                                y: location.y - size.height / 2
                            )
                            shaderUpdater.update(with: transform)
                        case .ended:
                            transform = .neutral
                            shaderUpdater.setNeutral()
                        }
                    }
            }
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
public extension StickerMotionEffect where Self == PointerHoverStickerMotionEffect {
    static var pointerHover: Self {
        .pointerHover()
    }
    
    static func pointerHover(intensity: Double = 1) -> Self {
        .init(intensity: intensity)
    }
}
