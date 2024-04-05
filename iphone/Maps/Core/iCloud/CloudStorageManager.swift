enum VoidResult {
  case success
  case failure(Error)
}

typealias VoidResultCompletionHandler = (VoidResult) -> Void

let kTrashDirectoryName = ".Trash"
let kUDDidFinishInitialCloudSynchronization = "kUDDidFinishInitialCloudSynchronization"

@objc @objcMembers final class CloudStorageManger: NSObject {

  private let fileCoordinator = NSFileCoordinator()
  private var localDirectoryMonitor: LocalDirectoryMonitor
  private var cloudDirectoryMonitor: UbiquitousDirectoryMonitor
  private let synchronizationStateManager: SynchronizationStateManager
  private let bookmarksManager = BookmarksManager.shared()
  private let backgroundQueue = DispatchQueue(label: "iCloud.app.organicmaps.backgroundQueue", qos: .background)
  private var isSynchronizationInProcess = false
  private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
  private var localDirectoryUrl: URL { localDirectoryMonitor.directory }
  private var needsToReloadBookmarksOnTheMap = false
  private var semaphore: DispatchSemaphore?

  static let shared = CloudStorageManger()

  // MARK: - Initialization
  init(cloudDirectoryMonitor: iCloudDirectoryMonitor = iCloudDirectoryMonitor.default,
       localDirectoryMonitor: DefaultLocalDirectoryMonitor = DefaultLocalDirectoryMonitor.default,
       synchronizationStateManager: SynchronizationStateManager = DefaultSynchronizationStateManager(isInitialSynchronization: !UserDefaults.standard.bool(forKey: kUDDidFinishInitialCloudSynchronization))) {
    self.cloudDirectoryMonitor = cloudDirectoryMonitor
    self.localDirectoryMonitor = localDirectoryMonitor
    self.synchronizationStateManager = synchronizationStateManager
    super.init()
  }

  @objc func start() {
    subscribeToSettingsNotifications()
    subscribeToApplicationLifecycleNotifications()
    cloudDirectoryMonitor.delegate = self
    localDirectoryMonitor.delegate = self
  }
}

// MARK: - Private
private extension CloudStorageManger {
  // MARK: - App Lifecycle
  func subscribeToApplicationLifecycleNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  func unsubscribeFromApplicationLifecycleNotifications() {
    NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  func subscribeToSettingsNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(didChangeEnabledState), name: NSNotification.iCloudSynchronizationDidChangeEnabledState, object: nil)
  }

  @objc func appWillEnterForeground() {
    cancelBackgroundExecution()
    startSynchronization()
  }

  @objc func appDidEnterBackground() {
    extendBackgroundExecutionIfNeeded { [weak self] in
      guard let self else { return }
      self.pauseSynchronization()
      self.cancelBackgroundExecution()
    }
  }

  @objc func didChangeEnabledState() {
    Settings.iCLoudSynchronizationEnabled() ? startSynchronization() : stopSynchronization()
  }

  // MARK: - Synchronization Lifecycle
  private func startSynchronization() {
    guard Settings.iCLoudSynchronizationEnabled() else { return }
    guard !cloudDirectoryMonitor.isStarted else {
      if cloudDirectoryMonitor.isPaused {
        resumeSynchronization()
      }
      return
    }
    cloudDirectoryMonitor.start { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.processError(error)
      case .success:
        self.localDirectoryMonitor.start { result in
          switch result {
          case .failure(let error):
            self.processError(error)
          case .success:
            LOG(.debug, "Start synchronization")
            self.addToBookmarksManagerObserverList()
            break
          }
        }
      }
    }
  }

  func stopSynchronization() {
    LOG(.debug, "Stop synchronization")
    localDirectoryMonitor.stop()
    cloudDirectoryMonitor.stop()
    synchronizationStateManager.resetState()
    removeFromBookmarksManagerObserverList()
  }

  func pauseSynchronization() {
    removeFromBookmarksManagerObserverList()
    localDirectoryMonitor.pause()
    cloudDirectoryMonitor.pause()
  }

  func resumeSynchronization() {
    addToBookmarksManagerObserverList()
    localDirectoryMonitor.resume()
    cloudDirectoryMonitor.resume()
  }

  // MARK: - Setup BookmarksManager observing
  func addToBookmarksManagerObserverList() {
    bookmarksManager.add(self)
  }

  func removeFromBookmarksManagerObserverList() {
    bookmarksManager.remove(self)
  }

  func areBookmarksManagerNotificationsEnabled() -> Bool {
    bookmarksManager.areNotificationsEnabled()
  }
}

// MARK: - iCloudStorageManger + LocalDirectoryMonitorDelegate
extension CloudStorageManger: LocalDirectoryMonitorDelegate {
  func didFinishGathering(contents: LocalContents) {
    let events = synchronizationStateManager.resolveEvent(.didFinishGatheringLocalContents(contents))
    processEvents(events)
  }

  func didUpdate(contents: LocalContents) {
    let events = synchronizationStateManager.resolveEvent(.didUpdateLocalContents(contents))
    processEvents(events)
  }

  func didReceiveLocalMonitorError(_ error: Error) {
    processError(error)
  }
}

// MARK: - iCloudStorageManger + CloudDirectoryMonitorDelegate
extension CloudStorageManger: UbiquitousDirectoryMonitorDelegate {
  func didFinishGathering(contents: CloudContents) {
    let events = synchronizationStateManager.resolveEvent(.didFinishGatheringCloudContents(contents))
    processEvents(events)
  }

  func didUpdate(contents: CloudContents) {
    let events = synchronizationStateManager.resolveEvent(.didUpdateCloudContents(contents))
    processEvents(events)
  }

  func didReceiveCloudMonitorError(_ error: Error) {
    processError(error)
  }
}

// MARK: - Handle Events and Errors
private extension CloudStorageManger {
  func processEvents(_ events: [OutgoingEvent]) {
    events.forEach { [weak self] event in
      guard let self else { return }

      LOG(.debug, "Process event: \(event)")
      self.backgroundQueue.async {
        self.executeEvent(event)
      }
    }

    backgroundQueue.async {
      self.reloadBookmarksOnTheMapIfNeeded()
      self.isSynchronizationInProcess = false
      self.cancelBackgroundExecution()
    }
  }

  func executeEvent(_ event: OutgoingEvent) {
    switch event {
    case .createLocalItem(let cloudMetadataItem): writeToLocalContainer(cloudMetadataItem, completion: completionHandler)
    case .updateLocalItem(let cloudMetadataItem): writeToLocalContainer(cloudMetadataItem, completion: completionHandler)
    case .removeLocalItem(let cloudMetadataItem): removeFromTheLocalContainer(cloudMetadataItem, completion: completionHandler)
    case .startDownloading(let cloudMetadataItem): startDownloading(cloudMetadataItem, completion: completionHandler)
    case .createCloudItem(let localMetadataItem): writeToCloudContainer(localMetadataItem, completion: completionHandler)
    case .updateCloudItem(let localMetadataItem): writeToCloudContainer(localMetadataItem, completion: completionHandler)
    case .removeCloudItem(let localMetadataItem): removeFromCloudContainer(localMetadataItem, completion: completionHandler)
    case .resolveVersionsConflict(let cloudMetadataItem): resolveVersionsConflict(cloudMetadataItem, completion: completionHandler)
    case .resolveInitialSynchronizationConflict(let localMetadataItem): resolveInitialSynchronizationConflict(localMetadataItem, completion: completionHandler)
    case .didFinishInitialSynchronization: UserDefaults.standard.set(true, forKey: kUDDidFinishInitialCloudSynchronization)
    case .didReceiveError(let error): processError(error)
    }
  }

  func completionHandler(result: VoidResult) {
    switch result {
    case .failure(let error):
      processError(error)
    case .success:
      break
    }
  }

  func processError(_ error: Error) {
    DispatchQueue.main.async {
      LOG(.error, "Synchronization error: \(error)")
      if let synchronizationError = error as? SynchronizationError {
        switch synchronizationError {
        case .fileUnavailable:
          // TODO: Handle file unavailable error
          break
        case .fileNotUploadedDueToQuota, .iCloudIsNotAvailable, .containerNotFound:
          self.stopSynchronization()
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
  }

  func reloadBookmarksOnTheMapIfNeeded() {
    if needsToReloadBookmarksOnTheMap {
      needsToReloadBookmarksOnTheMap = false
      semaphore = DispatchSemaphore(value: 0)
      DispatchQueue.main.async {
        self.bookmarksManager.loadBookmarks()
      }
      semaphore?.wait()
      semaphore = nil
    }
  }

  // MARK: - Read/Write/Downloading/Uploading
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
    let targetLocalFileUrl = cloudMetadataItem.relatedLocalItemUrl(to: localDirectoryUrl)
    LOG(.debug, "File \(cloudMetadataItem.fileName) is downloaded to the local iCloud container. Start coordinating and writing file...")
    fileCoordinator.coordinate(readingItemAt: cloudMetadataItem.fileUrl, writingItemAt: targetLocalFileUrl, error: &coordinationError) { readingUrl, writingUrl in
      do {
        let cloudFileData = try Data(contentsOf: readingUrl)
        try cloudFileData.write(to: writingUrl, options: .atomic, lastModificationDate: cloudMetadataItem.lastModificationDate)
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
    let targetLocalFileUrl = cloudMetadataItem.relatedLocalItemUrl(to: localDirectoryUrl)

    guard FileManager.default.fileExists(atPath: targetLocalFileUrl.path) else {
      LOG(.debug, "File \(cloudMetadataItem.fileName) doesn't exist in the local directory and cannot be removed.")
      completion(.success)
      return
    }

    do {
      try FileManager.default.removeItem(at: targetLocalFileUrl)
      needsToReloadBookmarksOnTheMap = true
      LOG(.debug, "File \(cloudMetadataItem.fileName) was removed from the local directory successfully.")
      completion(.success)
    } catch {
      completion(.failure(error))
    }
  }

  func writeToCloudContainer(_ localMetadataItem: LocalMetadataItem, completion: @escaping VoidResultCompletionHandler) {
    cloudDirectoryMonitor.fetchUbiquityDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let cloudDirectoryUrl):
        let targetCloudFileUrl = localMetadataItem.relatedCloudItemUrl(to: cloudDirectoryUrl)
        var coordinationError: NSError?

        LOG(.debug, "Start coordinating and writing file \(localMetadataItem.fileName)...")
        fileCoordinator.coordinate(readingItemAt: localMetadataItem.fileUrl, writingItemAt: targetCloudFileUrl, error: &coordinationError) { readingUrl, writingUrl in
          do {
            let fileData = try localMetadataItem.fileData()
            try fileData.write(to: writingUrl, lastModificationDate: localMetadataItem.lastModificationDate)
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
    cloudDirectoryMonitor.fetchUbiquityDirectoryUrl { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let cloudDirectoryUrl):
        LOG(.debug, "Start trashing file \(localMetadataItem.fileName)...")
        do {
          let targetCloudFileUrl = localMetadataItem.relatedCloudItemUrl(to: cloudDirectoryUrl)
          try removeDuplicatedFileFromTrashDirectoryIfNeeded(cloudDirectoryUrl: cloudDirectoryUrl, fileName: localMetadataItem.fileName)
          try FileManager.default.trashItem(at: targetCloudFileUrl, resultingItemURL: nil)
          completion(.success)
        } catch {
          completion(.failure(error))
        }
        return
      }
    }

    // Remove duplicated file from iCloud's .Trash directory if needed.
    // It's important to avoid the duplicating of names in the trash because we can't control the name of the trashed item.
    func removeDuplicatedFileFromTrashDirectoryIfNeeded(cloudDirectoryUrl: URL, fileName: String) throws {
      // There are no ways to retrieve the content of iCloud's .Trash directory on macOS.
      if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
        return
      }
      let trashDirectoryUrl = cloudDirectoryUrl.appendingPathComponent(kTrashDirectoryName, isDirectory: true)
      let fileInTrashDirectoryUrl = trashDirectoryUrl.appendingPathComponent(fileName)
      let trashDirectoryContent = try FileManager.default.contentsOfDirectory(at: trashDirectoryUrl,
                                                                              includingPropertiesForKeys: [],
                                                                              options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants])
      if trashDirectoryContent.contains(fileInTrashDirectoryUrl) {
        try FileManager.default.removeItem(at: fileInTrashDirectoryUrl)
      }
    }
  }

  // MARK: - Resolve conflicts
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
    fileCoordinator.coordinate(writingItemAt: currentVersion.url,
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
        // TODO: Check if current can be newer than latest
        //        if currentVersion.modificationDate! < latestVersionInConflict.modificationDate! {
        try FileManager.default.copyItem(at: readingURL, to: writingURL)
        try latestVersionInConflict.replaceItem(at: readingURL)
        //        } else {
        //
        //        }
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

  func resolveInitialSynchronizationConflict(_ localMetadataItem: LocalMetadataItem, completion: VoidResultCompletionHandler) {
    LOG(.debug, "Start resolving initial sync conflict for file \(localMetadataItem.fileName) by copying with a new name...")
    do {
      try FileManager.default.copyItem(at: localMetadataItem.fileUrl, to: Self.generateNewFileUrl(for: localMetadataItem.fileUrl, addDeviceName: true))
      completion(.success)
    } catch {
      completion(.failure(error))
    }
    return
  }

  static func generateNewFileUrl(for fileUrl: URL, addDeviceName: Bool = false) -> URL {
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
    let deviceName = addDeviceName ? "_\(UIDevice.current.name)" : ""
    let newFileName = finalBaseName + deviceName + "." + fileExtension
    let newFileUrl = fileUrl.deletingLastPathComponent().appendingPathComponent(newFileName)

    if FileManager.default.fileExists(atPath: newFileUrl.path) {
      return generateNewFileUrl(for: newFileUrl)
    } else {
      return newFileUrl
    }
  }
}

// MARK: - BookmarksObserver
extension CloudStorageManger: BookmarksObserver {
  func onBookmarksLoadFinished() {
    semaphore?.signal()
  }
}

// MARK: - Extend background time execution
private extension CloudStorageManger {
  // Extends background execution time to finish uploading.
  func extendBackgroundExecutionIfNeeded(expirationHandler: (() -> Void)? = nil) {
    guard isSynchronizationInProcess else {
      expirationHandler?()
      return
    }
    LOG(.debug, "Begin background task execution...")
    backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: nil) { [weak self] in
      guard let self else { return }
      expirationHandler?()
      self.cancelBackgroundExecution()
    }
  }

  func cancelBackgroundExecution() {
    guard backgroundTaskIdentifier != .invalid else { return }
    LOG(.debug, "Cancel background task execution.")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      UIApplication.shared.endBackgroundTask(self.backgroundTaskIdentifier)
      self.backgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    }
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

// MARK: - Notification + iCloudSynchronizationDidChangeEnabledState
extension Notification.Name {
  static let iCloudSynchronizationDidChangeEnabledStateNotification = Notification.Name("iCloudSynchronizationDidChangeEnabledStateNotification")
}

@objc extension NSNotification {
  public static let iCloudSynchronizationDidChangeEnabledState = Notification.Name.iCloudSynchronizationDidChangeEnabledStateNotification
}
