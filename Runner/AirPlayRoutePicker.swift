import AVKit
import Flutter
import UIKit

final class AirPlayRoutePickerFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        AirPlayRoutePickerView(frame: frame, arguments: args)
    }
}

final class AirPlayRoutePickerView: NSObject, FlutterPlatformView {
    private let picker: AVRoutePickerView

    init(frame: CGRect, arguments args: Any?) {
        picker = AVRoutePickerView(frame: frame)
        super.init()
        picker.translatesAutoresizingMaskIntoConstraints = true
        picker.backgroundColor = .clear
        picker.prioritizesVideoDevices = true
        applyColors(from: args)
    }

    func view() -> UIView {
        picker
    }

    private func applyColors(from args: Any?) {
        guard let dict = args as? [String: Any] else { return }
        if let tintValue = dict["tintColor"] as? NSNumber {
            picker.tintColor = UIColor(argb: tintValue.intValue)
        }
        if #available(iOS 13.0, *), let activeValue = dict["activeTintColor"] as? NSNumber {
            picker.activeTintColor = UIColor(argb: activeValue.intValue)
        }
    }
}

private extension UIColor {
    convenience init(argb: Int) {
        let alpha = CGFloat((argb >> 24) & 0xFF) / 255.0
        let red = CGFloat((argb >> 16) & 0xFF) / 255.0
        let green = CGFloat((argb >> 8) & 0xFF) / 255.0
        let blue = CGFloat(argb & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}//
//  AirPlayRoutePicker.swift
//  Runner
//
//  Created by 詹子逸 on 2025/9/26.
//

