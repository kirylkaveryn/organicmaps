enum VoidResult {
  case success
  case failure(Error)
}

typealias VoidResultCompletionHandler = (VoidResult) -> Void

let kKMLTypeIdentifier = "com.google.earth.kml"
let kFileExtensionKML = "kml" // only the *.kml is supported
let kTrashDirectoryName = ".Trash"
let kDocumentsDirectoryName = "Documents"
let kUDDidFinishInitialiCloudSynchronization = "kUDDidFinishInitialiCloudSynchronization"

@objc @objcMembers final class CloudStorageManger: NSObject {

  private let fileCoordinator = NSFileCoordinator()
  private let localDirectoryMonitor: LocalDirectoryMonitor
  private let cloudDirectoryMonitor: CloudDirectoryMonitor
  private let synchronizationStateManager: SynchronizationStateManager
  private let bookmarksManager = BookmarksManager.shared()
  private let backgroundQueue = DispatchQueue(label: "iCloud.app.organicmaps.backgroundQueue", qos: .background)
  private var isSynchronizationInProcess = false {
    didSet {
      LOG(.debug, "isSynchronizationInProcess: \(isSynchronizationInProcess)")
    }
  }
  private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
  private var isInitialSynchronizationFinished: Bool = true
  private var localDirectoryUrl: URL { localDirectoryMonitor.directory }

  // TODO: Sync properies using ubiqitousUD plist
//  {
//    get {
//      UserDefaults.standard.bool(forKey: kUDDidFinishInitialiCloudSynchronization)
//    }
//    set {
//      UserDefaults.standard.set(newValue, forKey: kUDDidFinishInitialiCloudSynchronization)
//    }
//  }
  private var needsToReloadBookmarksOnTheMap = false

  static let shared = CloudStorageManger()

  // MARK: - Initialization
  init(cloudDirectoryMonitor: CloudDirectoryMonitor = CloudDirectoryMonitor.default,
       localDirectoryMonitor: LocalDirectoryMonitor = LocalDirectoryMonitor.default,
       synchronizationStateManager: SynchronizationStateManager = DefaultSynchronizationStateManager()) {
    self.cloudDirectoryMonitor = cloudDirectoryMonitor
    self.localDirectoryMonitor = localDirectoryMonitor
    self.synchronizationStateManager = synchronizationStateManager
    super.init()
  }

  @objc func start() {
    subscribeToApplicationLifecycleNotifications()
    cloudDirectoryMonitor.delegate = self
    localDirectoryMonitor.delegate = self
  }
}

// MARK: - Private
private extension CloudStorageManger {
  func subscribeToApplicationLifecycleNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  @objc func appWillEnterForeground() {
    cancelBackgroundTaskExtension()
    startSynchronization()
  }

  @objc func appDidEnterBackground() {
    extendBackgroundExecutionIfNeeded { [weak self] in
      self?.stopSynchronization()
      self?.cancelBackgroundTaskExtension()
    }
  }

  private func startSynchronization() {
    guard !cloudDirectoryMonitor.isStarted else { return }
    cloudDirectoryMonitor.start { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        // TODO: handle error
        LOG(.debug, "CloudDirectoryMonitor start failed with error: \(error)")
        self.stopSynchronization()
      case .success:
        do {
          try self.localDirectoryMonitor.start()
        } catch {
          // TODO: handle error
          LOG(.debug, "LocalDirectoryMonitor start failed with error: \(error)")
          self.stopSynchronization()
        }
      }
    }
  }

  private func stopSynchronization() {
    localDirectoryMonitor.stop()
    cloudDirectoryMonitor.stop()
    synchronizationStateManager.resetState()
  }
}

// MARK: - iCloudStorageManger + LocalDirectoryMonitorDelegate
extension CloudStorageManger: LocalDirectoryMonitorDelegate {
  func didFinishGathering(contents: LocalContents) {
    LOG(.debug, "LocalDirectoryMonitorDelegate - didFinishGathering")
    let events = synchronizationStateManager.resolveEvent(.didFinishGatheringLocalContents(contents))
    processEvents(events)
  }

  func didUpdate(contents: LocalContents) {
    LOG(.debug, "LocalDirectoryMonitorDelegate - didUpdate")
    let events = synchronizationStateManager.resolveEvent(.didUpdateLocalContents(contents))
    processEvents(events)
  }

  func didReceiveLocalMonitorError(_ error: Error) {
    handleError(error)
  }
}

// MARK: - iCloudStorageManger + CloudDirectoryMonitorDelegate
extension CloudStorageManger: CloudDirectoryMonitorDelegate {
  func didFinishGathering(contents: CloudContents) {
    LOG(.debug, "CloudDirectoryMonitorDelegate - didFinishGathering")
    let events = synchronizationStateManager.resolveEvent(.didFinishGatheringCloudContents(contents))
    processEvents(events)
  }

  func didUpdate(contents: CloudContents) {
    LOG(.debug, "CloudDirectoryMonitorDelegate - didUpdate")
    let events = synchronizationStateManager.resolveEvent(.didUpdateCloudContents(contents))
    processEvents(events)
  }

  func didReceiveCloudMonitorError(_ error: Error) {
    handleError(error)
  }
}

// MARK: - Handle Read/Write Events
private extension CloudStorageManger {
  func processEvents(_ events: [OutgoingEvent]) {
    events.forEach { [weak self] event in
      guard let self else { return }
      LOG(.debug, "Process event: \(event)")

      let completionHandler: VoidResultCompletionHandler = { result in
        switch result {
        case .failure(let error):
          self.handleError(error)
        case .success:
          self.reloadBookmarksOnTheMapIfNeeded()
        }
      }

      self.backgroundQueue.async {
        switch event {
        case .createLocalItem(let cloudMetadataItem): self.writeToLocalContainer(cloudMetadataItem, completion: completionHandler)
        case .updateLocalItem(let cloudMetadataItem): self.writeToLocalContainer(cloudMetadataItem, completion: completionHandler)
        case .removeLocalItem(let cloudMetadataItem): self.removeFromTheLocalContainer(cloudMetadataItem, completion: completionHandler)
        case .startDownloading(let cloudMetadataItem): self.startDownloading(cloudMetadataItem, completion: completionHandler)
        case .resolveVersionsConflict(let cloudMetadataItem): self.resolveVersionsConflict(cloudMetadataItem, completion: completionHandler)
        case .createCloudItem(let localMetadataItem): self.writeToCloudContainer(localMetadataItem, completion: completionHandler)
        case .updateCloudItem(let localMetadataItem): self.writeToCloudContainer(localMetadataItem, completion: completionHandler)
        case .removeCloudItem(let localMetadataItem): self.removeFromCloudContainer(localMetadataItem, completion: completionHandler)
        case .didReceiveError(let error): self.handleError(error)
        }
      }
    }

    backgroundQueue.async {
      self.isSynchronizationInProcess = false
      self.cancelBackgroundTaskExtension()
    }
  }

  func startDownloading(_ cloudMetadataItem: CloudMetadataItem, completion: VoidResultCompletionHandler) {
    do {
      LOG(.debug, "Start downloading file: \(cloudMetadataItem.fileName)...")
      try FileManager.default.startDownloadingUbiquitousItem(at: cloudMetadataItem.fileUrl)
      completion(.success)
    } catch {
      completion(.failure(error))
    }
  }

  func writeToLocalContainer(_ cloudMetadataItem: CloudMetadataItem, completion: VoidResultCompletionHandler) {
    var coordinationError: NSError?
    let targetLocalFileUrl = localDirectoryUrl.appendingPathComponent(cloudMetadataItem.fileName)
    LOG(.debug, "File \(cloudMetadataItem.fileName) is downloaded to the local iCloud container. Start coordinating and writing file...")
    fileCoordinator.coordinate(readingItemAt: cloudMetadataItem.fileUrl, options: .withoutChanges, error: &coordinationError) { url in
      do {
        let cloudFileData = try Data(contentsOf: url)
        try cloudFileData.write(to: targetLocalFileUrl, options: .atomic, lastModificationDate: cloudMetadataItem.lastModificationDate)
        needsToReloadBookmarksOnTheMap = true
        LOG(.debug, "File \(cloudMetadataItem.fileName) is copied to local directory successfully.")
        completion(.success)
      } catch {
        completion(.failure(error))
      }
      return
    }
    if let coordinationError {
      completion(.failure(coordinationError))
    }
  }

  func removeFromTheLocalContainer(_ cloudMetadataItem: CloudMetadataItem, completion: VoidResultCompletionHandler) {
    let targetLocalFileUrl = localDirectoryUrl.appendingPathComponent(cloudMetadataItem.fileName)

    guard FileManager.default.fileExists(atPath: targetLocalFileUrl.path) else {
      LOG(.debug, "File \(cloudMetadataItem.fileName) is not exist in the local directory.")
      completion(.success)
      return
    }

    do {
      // TODO: trash items locally or hard remove?
      try FileManager.default.removeItem(at: targetLocalFileUrl)
      needsToReloadBookmarksOnTheMap = true
      LOG(.debug, "File \(cloudMetadataItem.fileName) is removed from the local directory successfully.")
      completion(.success)
    } catch {
      LOG(.error, "Failed to remove file \(cloudMetadataItem.fileName) from the local directory.")
      completion(.failure(error))
    }
  }

  func writeToCloudContainer(_ localMetadataItem: LocalMetadataItem, completion: @escaping VoidResultCompletionHandler) {
    cloudDirectoryMonitor.fetchUbiquityDocumentsDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let cloudDirectoryUrl):
        let targetCloudFileUrl = cloudDirectoryUrl.appendingPathComponent(localMetadataItem.fileName)
        var coordinationError: NSError?

        LOG(.debug, "Start coordinating and writing file \(localMetadataItem.fileName)...")
        fileCoordinator.coordinate(writingItemAt: targetCloudFileUrl, options: [], error: &coordinationError) { url in
          do {
            let fileData = try localMetadataItem.fileData()
            try fileData.write(to: url, lastModificationDate: localMetadataItem.lastModificationDate)
            completion(.success)
          } catch {
            completion(.failure(error))
          }
          return
        }
        if let coordinationError {
          completion(.failure(coordinationError))
        }
      }
    }
  }

  func removeFromCloudContainer(_ localMetadataItem: LocalMetadataItem, completion: @escaping VoidResultCompletionHandler) {
    cloudDirectoryMonitor.fetchUbiquityDocumentsDirectoryUrl { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let cloudDirectoryUrl):
        LOG(.debug, "Start trashing file \(localMetadataItem.fileName)...")
        let targetCloudFileUrl = cloudDirectoryUrl.appendingPathComponent(localMetadataItem.fileName)
        do {
          try FileManager.default.trashItem(at: targetCloudFileUrl, resultingItemURL: nil)
          completion(.success)
        } catch {
          completion(.failure(error))
        }
        return
      }
    }
  }

  func handleError(_ error: Error) {
    LOG(.error, "Synchronization error: \(error)")
    if let synchronizationError = error as? SynchronizationError {
      switch synchronizationError {
      case .fileUnavailable:
        // TODO: Handle file unavailable error
        break
      case .fileNotUploadedDueToQuota, .iCloudIsNotAvailable, .containerNotFound:
        stopSynchronization()
        // TODO: should we try to restart sync earlier? Or use some timeout?
      case .ubiquityServerNotAvailable:
        break
      case .internal(let error):
        // TODO: Handle internal error
        break
      }
    } else {
      // TODO: Handle regular errors
    }
  }

  func resolveVersionsConflict(_ cloudMetadataItem: CloudMetadataItem, completion: VoidResultCompletionHandler) {
    LOG(.debug, "Start resolving version conflict for file \(cloudMetadataItem.fileName)...")

    guard let versionsInConflict = NSFileVersion.unresolvedConflictVersionsOfItem(at: cloudMetadataItem.fileUrl),
    let currentVersion = NSFileVersion.currentVersionOfItem(at: cloudMetadataItem.fileUrl) else {
      completion(.success)
      return
    }

    let sortedVersions = versionsInConflict.sorted { version1, version2 in
      guard let date1 = version1.modificationDate, let date2 = version2.modificationDate else {
        return false
      }
      return date1 > date2
    }

    guard let latestVersionInConflict = sortedVersions.first else {
      completion(.success)
      return
    }

    let targetCloudFileCopyUrl = Self.generateNewFileUrl(for: cloudMetadataItem.fileUrl)
    var coordinationError: NSError?
    fileCoordinator.coordinate(writingItemAt: cloudMetadataItem.fileUrl, 
                               options: [],
                               writingItemAt: targetCloudFileCopyUrl,
                               options: .forReplacing,
                               error: &coordinationError) { readingURL, writingURL in
      guard !FileManager.default.fileExists(atPath: targetCloudFileCopyUrl.path) else {
        needsToReloadBookmarksOnTheMap = true
        completion(.success)
        return
      }
      do {
        try FileManager.default.copyItem(at: readingURL, to: writingURL)
        try latestVersionInConflict.replaceItem(at: readingURL)
        try NSFileVersion.removeOtherVersionsOfItem(at: readingURL)
        needsToReloadBookmarksOnTheMap = true
        completion(.success)
      } catch {
        completion(.failure(error))
      }
      return
    }

    if let coordinationError {
      completion(.failure(coordinationError))
    }
  }

  // FIXME: Multiple calls of reload may cause issue on the bookmarks screen
  func reloadBookmarksOnTheMapIfNeeded() {
    if needsToReloadBookmarksOnTheMap {
      needsToReloadBookmarksOnTheMap = false
      DispatchQueue.main.async {
        // TODO: Needs to implement mechanism to reload only current categories, but not all
        // TODO: Lock read/write access to the bookmarksManager
        self.bookmarksManager.loadBookmarks()
      }
    }
  }

  private static func generateNewFileUrl(for fileUrl: URL) -> URL {
    let baseName = fileUrl.deletingPathExtension().lastPathComponent
    let fileExtension = fileUrl.pathExtension

    let regexPattern = "_(\\d+)$"
    let regex = try! NSRegularExpression(pattern: regexPattern)
    let range = NSRange(location: 0, length: baseName.utf16.count)
    let matches = regex.matches(in: baseName, options: [], range: range)

    var finalBaseName = baseName

    if let match = matches.last, let existingNumberRange = Range(match.range(at: 1), in: baseName) {
      let existingNumber = Int(baseName[existingNumberRange])!
      let incrementedNumber = existingNumber + 1
      finalBaseName = baseName.replacingCharacters(in: existingNumberRange, with: "\(incrementedNumber)")
    } else {
      finalBaseName = baseName + "_1"
    }

    let newFileName = finalBaseName + "." + fileExtension
    let newFileUrl = fileUrl.deletingLastPathComponent().appendingPathComponent(newFileName)

    if FileManager.default.fileExists(atPath: newFileUrl.path) {
      return generateNewFileUrl(for: newFileUrl)
    } else {
      return newFileUrl
    }
  }
}

// MARK: - Extend background time execution
private extension CloudStorageManger {
  // Extends background execution time to finish uploading.
  func extendBackgroundExecutionIfNeeded(expirationHandler: (() -> Void)? = nil) {
    guard isSynchronizationInProcess else { return }
    LOG(.debug, "Begin background task execution...")
    backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: nil) { [weak self] in
      guard let self else { return }
      expirationHandler?()
      self.cancelBackgroundTaskExtension()
    }
  }

  func cancelBackgroundTaskExtension() {
    guard backgroundTaskIdentifier != .invalid else { return }
    LOG(.debug, "Cancel background task execution.")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      UIApplication.shared.endBackgroundTask(self.backgroundTaskIdentifier)
      self.backgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    }
  }
}

// MARK: - FileManager + Local Directories
extension FileManager {
  var documentsDirectoryUrl: URL {
    urls(for: .documentDirectory, in: .userDomainMask).first!
  }

  var bookmarksDirectoryUrl: URL {
    documentsDirectoryUrl.appendingPathComponent("bookmarks", isDirectory: true)
  }
}

// MARK: - URL + ResourceValues
fileprivate extension URL {
  mutating func setResourceModificationDate(_ date: Date) throws {
    var resource = try resourceValues(forKeys:[.contentModificationDateKey])
    resource.contentModificationDate = date
    try setResourceValues(resource)
  }
}

fileprivate extension Data {
  func write(to url: URL, options: Data.WritingOptions = .atomic, lastModificationDate: TimeInterval? = nil) throws {
    var url = url
    try write(to: url, options: options)
    if let lastModificationDate {
      try url.setResourceModificationDate(Date(timeIntervalSince1970: lastModificationDate))
    }
  }
}
