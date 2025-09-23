import receive_sharing_intent
import UIKit
import UniformTypeIdentifiers
import MobileCoreServices

private enum ShareConstants {
    static let sharedDirectory = "SharedDownloads"
    static let queueKey = "yibrowser_shared_downloads_queue"
}

private struct PendingShareItem: Codable {
    let relativePath: String
    let displayName: String
    let typeHint: String

    func toDictionary() -> [String: Any] {
        [
            "relativePath": relativePath,
            "displayName": displayName,
            "type": typeHint,
        ]
    }
}

class ShareViewController: RSIShareViewController {
      
    private var hasProcessedShare = false
       private var didCompleteRequest = false
    override func shouldAutoRedirect() -> Bool {
        return false
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
               let itemCount = extensionContext?.inputItems.count ?? 0
               var attachmentCount = 0
               if let items = extensionContext?.inputItems as? [NSExtensionItem] {
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
               guard !hasProcessedShare else {
                   return
               }
               hasProcessedShare = true
               processIncomingItems()
           }

           private func processIncomingItems() {
               guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem],
                     !extensionItems.isEmpty else {
                   NSLog("[ShareExt] No extension items found")
                   completeRequest()
                   return
               }

               guard let groupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
                     !groupId.isEmpty else {
                   NSLog("[ShareExt] Missing AppGroupId in Info.plist")
                   completeRequest()
                   return
               }

               guard let containerURL = FileManager.default
                   .containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
                   NSLog("[ShareExt] Unable to resolve shared container for groupId=%@", groupId)
                   completeRequest()
                   return
               }

               let sharedDirectory = containerURL.appendingPathComponent(
                   ShareConstants.sharedDirectory,
                   isDirectory: true
               )
               do {
                   try FileManager.default.createDirectory(
                       at: sharedDirectory,
                       withIntermediateDirectories: true
                   )
               } catch {
                   NSLog("[ShareExt] Failed to create shared directory: %@", error.localizedDescription)
                   completeRequest()
                   return
               }

               let dispatchGroup = DispatchGroup()
               let resultQueue = DispatchQueue(label: "com.yibrowser.share.results")
               var savedItems: [PendingShareItem] = []

               for item in extensionItems {
                   guard let attachments = item.attachments else { continue }
                   for provider in attachments {
                       guard let typeIdentifier = preferredTypeIdentifier(for: provider) else {
                           NSLog("[ShareExt] Unable to determine type identifier for provider")
                           continue
                       }
                       dispatchGroup.enter()
                       copyProvider(
                           provider,
                           typeIdentifier: typeIdentifier,
                           to: sharedDirectory
                       ) { [weak self] result in
                           defer { dispatchGroup.leave() }
                           guard let self else { return }
                           switch result {
                           case .success(let item):
                               resultQueue.async {
                                   savedItems.append(item)
                               }
                           case .failure(let error):
                               NSLog("[ShareExt] Failed to save provider: %@", error.localizedDescription)
                           }
                       }
                   }
               }

               let timeout = DispatchWorkItem { [weak self] in
                   guard let self else { return }
                   NSLog("[ShareExt] Processing timeout reached; continuing")
                   resultQueue.sync {
                       self.persistAndRedirect(
                           items: savedItems,
                           groupId: groupId
                       )
                   }
               }

               DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)

               dispatchGroup.notify(queue: .main) { [weak self] in
                   timeout.cancel()
                   guard let self else { return }
                   resultQueue.sync {
                       self.persistAndRedirect(
                           items: savedItems,
                           groupId: groupId
                       )
                   }
               }
           }

           private func persistAndRedirect(
               items: [PendingShareItem],
               groupId: String
           ) {
               if didCompleteRequest {
                   NSLog("[ShareExt] persistAndRedirect called after completion; ignoring")
                   return
               }
               didCompleteRequest = true
               if !items.isEmpty {
                   let defaults = UserDefaults(suiteName: groupId)
                   var queue = defaults?.array(forKey: ShareConstants.queueKey) as? [[String: Any]] ?? []
                   queue.append(contentsOf: items.map { $0.toDictionary() })
                   defaults?.set(queue, forKey: ShareConstants.queueKey)
                   defaults?.set(Date().timeIntervalSince1970, forKey: "\(ShareConstants.queueKey)_ts")
                   defaults?.synchronize()
                   NSLog("[ShareExt] Persisted %d item(s) to shared container", items.count)
               } else {
                   NSLog("[ShareExt] No items were saved to shared container")
               }
               openHostApp()
               completeRequest()
           }

           private func completeRequest() {
               extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
           }

           private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
               if #available(iOS 14.0, *) {
                   let candidates: [UTType] = [
                       .movie,
                       .video,
                       .image,
                       .audio,
                       .mpeg4Audio,
                       .pdf,
                       .item,
                       .content,
                       .data,
                   ]
                   for type in candidates {
                       if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                           return type.identifier
                       }
                   }
               } else {
                   let candidates: [String] = [
                       kUTTypeMovie as String,
                       kUTTypeVideo as String,
                       kUTTypeImage as String,
                       kUTTypeAudio as String,
                       kUTTypePDF as String,
                       kUTTypeItem as String,
                       kUTTypeContent as String,
                       kUTTypeData as String,
                   ]
                   for type in candidates {
                       if provider.hasItemConformingToTypeIdentifier(type) {
                           return type
                       }
                   }
               }
               return provider.registeredTypeIdentifiers.first
           }

           private func copyProvider(
               _ provider: NSItemProvider,
               typeIdentifier: String,
               to directory: URL,
               completion: @escaping (Result<PendingShareItem, Error>) -> Void
           ) {
               provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
                   guard let self else { return }
                   if let error {
                       NSLog("[ShareExt] loadFileRepresentation error: %@", error.localizedDescription)
                   }
                   guard let fileURL = url else {
                       self.copyFromInPlace(provider, typeIdentifier: typeIdentifier, to: directory, completion: completion)
                       return
                   }
                   self.copyTempFile(from: fileURL, provider: provider, typeIdentifier: typeIdentifier, to: directory, completion: completion)
               }
           }

           private func copyFromInPlace(
               _ provider: NSItemProvider,
               typeIdentifier: String,
               to directory: URL,
               completion: @escaping (Result<PendingShareItem, Error>) -> Void
           ) {
               provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, _, error in
                   guard let self else { return }
                   if let error {
                       NSLog("[ShareExt] loadInPlaceFileRepresentation error: %@", error.localizedDescription)
                   }
                   guard let url else {
                       completion(.failure(NSError(domain: "ShareExt", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing file URL"])))
                       return
                   }
                   self.copyTempFile(from: url, provider: provider, typeIdentifier: typeIdentifier, to: directory, completion: completion)
               }
           }

           private func copyTempFile(
               from sourceURL: URL,
               provider: NSItemProvider,
               typeIdentifier: String,
               to directory: URL,
               completion: @escaping (Result<PendingShareItem, Error>) -> Void
           ) {
               let sanitizedName = sanitizeFileName(
                   provider.suggestedName ?? sourceURL.lastPathComponent,
                   fallbackExtension: sourceURL.pathExtension.isEmpty ?
                       inferredExtension(for: typeIdentifier) : sourceURL.pathExtension
               )
               let destinationURL = uniqueDestinationURL(
                   for: sanitizedName,
                   in: directory
               )
               do {
                   if sourceURL.startAccessingSecurityScopedResource() {
                       defer { sourceURL.stopAccessingSecurityScopedResource() }
                   }
                   if FileManager.default.fileExists(atPath: destinationURL.path) {
                       try FileManager.default.removeItem(at: destinationURL)
                   }
                   try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                   let relativePath = "\(ShareConstants.sharedDirectory)/\(destinationURL.lastPathComponent)"
                   let item = PendingShareItem(
                       relativePath: relativePath,
                       displayName: destinationURL.lastPathComponent,
                       typeHint: classifyType(typeIdentifier)
                   )
                   completion(.success(item))
               } catch {
                   completion(.failure(error))
               }
           }

           private func sanitizeFileName(_ name: String, fallbackExtension: String?) -> String {
               var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
               if trimmed.isEmpty {
                   trimmed = "shared_\(Int(Date().timeIntervalSince1970))"
               }
               let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
               trimmed = trimmed.components(separatedBy: invalidCharacters).joined(separator: "_")
               let url = URL(fileURLWithPath: trimmed)
               var base = url.deletingPathExtension().lastPathComponent
               if base.isEmpty {
                   base = "shared_\(Int(Date().timeIntervalSince1970))"
               }
               var ext = url.pathExtension
               if ext.isEmpty, let fallback = fallbackExtension, !fallback.isEmpty {
                   ext = fallback
               }
               if ext.isEmpty {
                   return base
               }
               return base + "." + ext
           }

           private func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
               let baseURL = directory.appendingPathComponent(fileName)
               var candidate = baseURL
               var counter = 1
               let fileManager = FileManager.default
               let baseName = baseURL.deletingPathExtension().lastPathComponent
               let ext = baseURL.pathExtension
               while fileManager.fileExists(atPath: candidate.path) {
                   let suffix = "-\(counter)"
                   let newName: String
                   if ext.isEmpty {
                       newName = baseName + suffix
                   } else {
                       newName = baseName + suffix + "." + ext
                   }
                   candidate = directory.appendingPathComponent(newName)
                   counter += 1
               }
               return candidate
           }

           private func inferredExtension(for typeIdentifier: String) -> String? {
               if #available(iOS 14.0, *), let type = UTType(typeIdentifier) {
                   if let preferredExt = type.preferredFilenameExtension {
                       return preferredExt
                   }
               }
               let uti = typeIdentifier as CFString
               if let unmanaged = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassFilenameExtension) {
                   return unmanaged.takeRetainedValue() as String
               }
               return nil
           }

           private func classifyType(_ typeIdentifier: String) -> String {
               if #available(iOS 14.0, *), let type = UTType(typeIdentifier) {
                   if type.conforms(to: .movie) || type.conforms(to: .video) {
                       return "video"
                   }
                   if type.conforms(to: .image) {
                       return "image"
                   }
                   if type.conforms(to: .audio) {
                       return "audio"
                   }
                   if type.conforms(to: .pdf) {
                       return "file"
                   }
               } else {
                   let uti = typeIdentifier as CFString
                   if UTTypeConformsTo(uti, kUTTypeMovie) || UTTypeConformsTo(uti, kUTTypeVideo) {
                       return "video"
                   }
                   if UTTypeConformsTo(uti, kUTTypeImage) {
                       return "image"
                   }
                   if UTTypeConformsTo(uti, kUTTypeAudio) {
                       return "audio"
                   }
               }
               return "file"
           }

           private func openHostApp() {
               let timestamp = Date().timeIntervalSince1970
                            let candidates = hostBundleIdentifierCandidates()
                            guard !candidates.isEmpty else {
                                NSLog("[ShareExt] No bundle identifier candidates available for redirect")
                   return
               }
               attemptOpenHostApp(using: candidates, index: 0, timestamp: timestamp)
                         }

                         private func hostBundleIdentifierCandidates() -> [String] {
                             var ordered: [String] = []
                             var seen = Set<String>()

                             func appendCandidate(_ value: String?) {
                                 guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !raw.isEmpty,
                                       !seen.contains(raw) else {
                                     return
                                 }
                                 seen.insert(raw)
                                 ordered.append(raw)
                             }

                             // Allow an explicit override via Info.plist if provided.
                             appendCandidate(
                                 Bundle.main.object(forInfoDictionaryKey: "HostBundleIdentifier") as? String
                             )

                             guard let extBundleId = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !extBundleId.isEmpty else {
                                 return ordered
                             }

                             // Common naming pattern: host bundle identifier followed by a share suffix.
                             let suffixes = [
                                 ".share",
                                 ".Share",
                                 ".ShareExtension",
                                 ".shareextension",
                                 ".ShareExt",
                                 ".Extension",
                             ]
                             for suffix in suffixes {
                                 if extBundleId.hasSuffix(suffix) {
                                     let trimmed = String(extBundleId.dropLast(suffix.count))
                                     appendCandidate(trimmed)
                                 }
                             }

                             // Fallback: remove the last path component if no known suffix matched.
                             if let lastDot = extBundleId.lastIndex(of: ".") {
                                 let trimmed = String(extBundleId[..<lastDot])
                                 appendCandidate(trimmed)
                             }

                             // Finally include the extension bundle identifier itself as a last resort.
                             appendCandidate(extBundleId)

                             return ordered
                         }

                         private func attemptOpenHostApp(using candidates: [String], index: Int, timestamp: TimeInterval) {
                             guard index < candidates.count else {
                                 NSLog("[ShareExt] Redirect to host app failed for all candidates")
                                 return
                             }

                             let bundleId = candidates[index]
               let scheme = "ShareMedia-\(bundleId)"
                             
                             guard let url = URL(string: "\(scheme)://shared?ts=\(timestamp)") else {
                                               NSLog("[ShareExt] Invalid redirect URL for bundle id %@", bundleId)
                                               attemptOpenHostApp(using: candidates, index: index + 1, timestamp: timestamp)
                   return
               }
                             extensionContext?.open(url, completionHandler: { [weak self] success in
                                                if success {
                                                    NSLog("[ShareExt] Redirect to host app succeeded via bundle id %@", bundleId)
                                                } else {
                                                    NSLog("[ShareExt] Redirect failed for bundle id %@; trying next candidate", bundleId)
                                                    self?.attemptOpenHostApp(using: candidates, index: index + 1, timestamp: timestamp)
                                                }
               })
           }
}
