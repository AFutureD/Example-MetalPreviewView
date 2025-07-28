//
//  Extensions.swift
//  Template
//
//  Created by Huanan on 2025/7/28.
//


import UIKit
import simd
import CoreMedia

extension CGAffineTransform {
    func convertToSIMD() -> simd_float3x3 {
        return simd_float3x3(
            SIMD3(Float(self.a),  Float(self.b),  0),
            SIMD3(Float(self.c),  Float(self.d),  0),
            SIMD3(Float(self.tx), Float(self.ty), 1)
        )
    }
}

extension CMVideoDimensions {
    func convertToSize() -> CGSize {
        CGSize(width: Int(self.width), height: Int(self.height))
    }
}

public var timebaseInfo: mach_timebase_info_data_t = {
    var timebaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timebaseInfo) // Initialize timebaseInfo
    return timebaseInfo
}()

public func machTimeToSeconds(_ machTime: UInt64) -> TimeInterval {
    let nanos = Double(machTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
    return nanos / 1e9
}
