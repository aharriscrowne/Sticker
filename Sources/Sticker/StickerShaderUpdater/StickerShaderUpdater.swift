//
//  StickerShaderUpdater.swift
//  FoilTest
//
//  Created by Benjamin Pisano on 03/11/2024.
//

import SwiftUI
import Observation

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
@Observable
final class StickerShaderUpdater {
    typealias ChangeHandler = (_ motion: StickerMotion) -> Void

    private(set) var motion: StickerMotion = .init()
    
    private let onChange: ChangeHandler

    init(onChange: @escaping @Sendable ChangeHandler) {
        self.onChange = onChange
    }

    @MainActor
    func update(with transform: StickerTransform) {
        motion = .init(
            isActive: true,
            transform: transform
        )
        onChange(motion)
    }

    @MainActor
    func setNeutral() {
        motion = .init(
            isActive: false,
            transform: .neutral
        )
        onChange(motion)
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
extension StickerShaderUpdater: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(motion)
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
extension StickerShaderUpdater: Equatable {
    static func == (lhs: StickerShaderUpdater, rhs: StickerShaderUpdater) -> Bool {
        lhs.motion == rhs.motion
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
extension View {
    func onStickerShaderChange(_ onChange: @escaping @Sendable StickerShaderUpdater.ChangeHandler) -> some View {
        environment(\.stickerShaderUpdater, .init(onChange: onChange))
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
extension EnvironmentValues {
    @Entry var stickerShaderUpdater: StickerShaderUpdater = .init(onChange: { _ in })
}
