import receive_sharing_intent
import UIKit

class ShareViewController: RSIShareViewController {
      
    // Use this method to return false if you don't want to redirect to host app automatically.
    // Default is true
    override func shouldAutoRedirect() -> Bool {
        NSLog("[ShareExt] shouldAutoRedirect invoked")
        return true
    }
    override func viewDidLoad() {
          super.viewDidLoad()
          let itemCount = self.extensionContext?.inputItems.count ?? 0
          var attachmentCount = 0
          if let items = self.extensionContext?.inputItems as? [NSExtensionItem] {
              attachmentCount = items.compactMap { $0.attachments?.count }.reduce(0, +)
          }
          NSLog("[ShareExt] viewDidLoad items=\(itemCount) attachments=\(attachmentCount)")
          if let groupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String {
              NSLog("[ShareExt] AppGroupId from Info.plist: \(groupId)")
          } else {
              NSLog("[ShareExt] AppGroupId not found in Info.plist")
          }
      }

      override func viewDidAppear(_ animated: Bool) {
          super.viewDidAppear(animated)
          let itemCount = self.extensionContext?.inputItems.count ?? 0
          var attachmentCount = 0
          if let items = self.extensionContext?.inputItems as? [NSExtensionItem] {
              attachmentCount = items.compactMap { $0.attachments?.count }.reduce(0, +)
          }
          NSLog("[ShareExt] viewDidAppear items=\(itemCount) attachments=\(attachmentCount)")
      }
}
