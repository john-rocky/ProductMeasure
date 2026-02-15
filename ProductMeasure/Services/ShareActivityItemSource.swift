//
//  ShareActivityItemSource.swift
//  ProductMeasure
//

import UIKit
import LinkPresentation

/// Custom UIActivityItemSource that provides app icon metadata for the share sheet.
/// Prevents iOS from showing "あ" or other fallback icons.
final class ShareActivityItemSource: NSObject, UIActivityItemSource {
    private let item: Any
    private let title: String

    init(item: Any, title: String = "Product Measure") {
        self.item = item
        self.title = title
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return item
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return item
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title

        if let appIcon = UIImage(named: "AppIcon") ?? Bundle.main.icon {
            metadata.iconProvider = NSItemProvider(object: appIcon)
        }

        return metadata
    }
}

private extension Bundle {
    var icon: UIImage? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
              let lastIcon = iconFiles.last else {
            return nil
        }
        return UIImage(named: lastIcon)
    }
}
