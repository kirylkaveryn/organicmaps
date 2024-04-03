protocol UbiquitousDirectoryMonitor: DirectoryMonitor {
  var delegate: UbiquitousDirectoryMonitorDelegate? { get set }
  func fetchUbiquityDirectoryUrl(completion: ((Result<URL, SynchronizationError>) -> Void)?)
}

protocol UbiquitousDirectoryMonitorDelegate : AnyObject {
  func didFinishGathering(contents: CloudContents)
  func didUpdate(contents: CloudContents)
  func didReceiveCloudMonitorError(_ error: Error)
}

private let kUDCloudIdentityKey = "com.apple.organicmaps.UbiquityIdentityToken"
private let kDocumentsDirectoryName = "Documents"
private let kFileExtensionKML = "kml" // only the .kml is supported

final class iCloudDirectoryMonitor: NSObject, UbiquitousDirectoryMonitor {

  private static let sharedContainerIdentifier: String = {
    var identifier = "iCloud.app.organicmaps"
    #if DEBUG
    identifier.append(".debug")
    #endif
    return identifier
  }()

  static let `default` = iCloudDirectoryMonitor(cloudContainerIdentifier: iCloudDirectoryMonitor.sharedContainerIdentifier)

  private let metadataQuery = NSMetadataQuery()
  private var containerIdentifier: String
  private var ubiquitousDocumentsDirectory: URL?

  // MARK: - Public properties
  var isStarted: Bool { return metadataQuery.isStarted }
  private(set) var isPaused: Bool = true
  weak var delegate: UbiquitousDirectoryMonitorDelegate?

  init(cloudContainerIdentifier: String = iCloudDirectoryMonitor.sharedContainerIdentifier) {
    self.containerIdentifier = cloudContainerIdentifier
    super.init()

    setupMetadataQuery()
    subscribeToCloudAvailabilityNotifications()
    fetchUbiquityDirectoryUrl()
  }


  // MARK: - Public methods
  func start(completion: VoidResultCompletionHandler? = nil) {
    guard cloudIsAvailable() else {
      completion?(.failure(SynchronizationError.iCloudIsNotAvailable))
      return
    }
    fetchUbiquityDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion?(.failure(error))
      case .success:
        self.startQuery()
        completion?(.success)
      }
    }
  }

  func stop() {
    stopQuery()
  }

  func resume() {
    metadataQuery.enableUpdates()
    isPaused = false
  }

  func pause() {
    metadataQuery.disableUpdates()
    isPaused = true
  }

  func fetchUbiquityDirectoryUrl(completion: ((Result<URL, SynchronizationError>) -> Void)? = nil) {
    if let ubiquitousDocumentsDirectory {
      completion?(.success(ubiquitousDocumentsDirectory))
      return
    }
    DispatchQueue.global().async {
      guard let containerUrl = FileManager.default.url(forUbiquityContainerIdentifier: self.containerIdentifier) else {
        LOG(.error, "Failed to retrieve container's URL for:\(self.containerIdentifier)")
        completion?(.failure(.containerNotFound))
        return
      }
      let documentsContainerUrl = containerUrl.appendingPathComponent(kDocumentsDirectoryName)
      self.ubiquitousDocumentsDirectory = documentsContainerUrl
      completion?(.success(documentsContainerUrl))
    }
  }
}

// MARK: - Private
private extension iCloudDirectoryMonitor {
  func cloudIsAvailable() -> Bool {
    let cloudToken = FileManager.default.ubiquityIdentityToken
    guard let cloudToken else {
      UserDefaults.standard.removeObject(forKey: kUDCloudIdentityKey)
      LOG(.debug, "Cloud is not available. Cloud token is nil.")
      return false
    }
    do {
      let data = try NSKeyedArchiver.archivedData(withRootObject: cloudToken, requiringSecureCoding: true)
      UserDefaults.standard.set(data, forKey: kUDCloudIdentityKey)
      return true
    } catch {
      UserDefaults.standard.removeObject(forKey: kUDCloudIdentityKey)
      LOG(.error, "Failed to archive cloud token: \(error)")
      return false
    }
  }

  func subscribeToCloudAvailabilityNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(cloudAvailabilityChanged(_:)), name: .NSUbiquityIdentityDidChange, object: nil)
  }

  // TODO: - Actually this notification was never called. If user disable the iCloud for the current app during the active state the app will be relaunched. Needs to investigate additional cases when this notification can be sent.
  @objc func cloudAvailabilityChanged(_ notification: Notification) {
    LOG(.debug, "Cloud availability changed to : \(cloudIsAvailable())")
    cloudIsAvailable() ? startQuery() : stopQuery()
  }

  // MARK: - MetadataQuery
  private func setupMetadataQuery() {
    metadataQuery.notificationBatchingInterval = 1
    metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
    metadataQuery.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.\(kFileExtensionKML)")
    metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

    NotificationCenter.default.addObserver(self, selector: #selector(queryDidFinishGathering(_:)), name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(queryDidUpdate(_:)), name: NSNotification.Name.NSMetadataQueryDidUpdate, object: nil)
  }

  func startQuery() {
    guard !metadataQuery.isStarted else { return }
    metadataQuery.start()
    isPaused = false
  }

  func stopQuery() {
    metadataQuery.stop()
    isPaused = true
  }

  @objc func queryDidFinishGathering(_ notification: Notification) {
    guard cloudIsAvailable(), notification.object as? NSMetadataQuery === metadataQuery, let metadataItems = metadataQuery.results as? [NSMetadataItem] else { return }
    pause()
    let newContent = getContents(metadataItems)
    delegate?.didFinishGathering(contents: newContent)
    resume()
  }

  @objc func queryDidUpdate(_ notification: Notification) {
    guard cloudIsAvailable(), notification.object as? NSMetadataQuery === metadataQuery, let metadataItems = metadataQuery.results as? [NSMetadataItem] else { return }
    pause()
    let newContent = getContents(metadataItems, userInfo: notification.userInfo)
    delegate?.didUpdate(contents: newContent)
    resume()
  }

  // There are no ways to retrieve the content of iCloud's .Trash directory on the macOS because it uses different file system and place trashed content in the /Users/<user_name>/.Trash which cannot be observed without access.
  // When we get a new notification and retrieve the metadata from the object the actual list of items in iOS contains both current and deleted files (which is in .Trash/ directory now) but on macOS we only have absence of the file. So there are no way to get list of deleted items on macOS on didFinishGathering state.
  // Due to didUpdate state we can get the list of deleted items on macOS from the userInfo property but cannot get their new url.
  private func getContents(_ metadataItems: [NSMetadataItem], userInfo: [AnyHashable: Any]? = nil) -> CloudContents {
    let trashedCloudMetadataItems: CloudContents
    if let userInfo {
      trashedCloudMetadataItems = getTrashContentsFromUserInfo(userInfo)
    } else {
      trashedCloudMetadataItems = getTrashContentsFromTrashDirectory()
    }
    let cloudMetadataItems = CloudContents(metadataItems.compactMap { item in
      do {
        return try CloudMetadataItem(metadataItem: item)
      } catch {
        delegate?.didReceiveCloudMonitorError(error)
        return nil
      }
    })
    return cloudMetadataItems + trashedCloudMetadataItems
  }

  private func getTrashContentsFromUserInfo(_ userInfo: [AnyHashable: Any]) -> CloudContents {
    guard let removedItems = userInfo[NSMetadataQueryUpdateRemovedItemsKey] as? [NSMetadataItem] else { return [] }
    return CloudContents(removedItems.compactMap { metadataItem in
      do {
        var item = try CloudMetadataItem(metadataItem: metadataItem)
        // on macOS deleted file will not be in the ./Trash directory, but it doesn't mean that it is not removed because it is placed in the NSMetadataQueryUpdateRemovedItems array.
        item.isRemoved = true
        return item
      } catch {
        delegate?.didReceiveCloudMonitorError(error)
        return nil
      }
    })
  }

  private func getTrashContentsFromTrashDirectory() -> CloudContents {
    // There are no ways to retrieve the content of iCloud's .Trash directory on macOS.
    if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
      return []
    }
    // On iOS we can get the list of deleted items from the .Trash directory but only when iCloud is enabled.
    guard let trashDirectoryUrl = ubiquitousDocumentsDirectory?.appendingPathComponent(kTrashDirectoryName),
          let removedItems = try? FileManager.default.contentsOfDirectory(at: trashDirectoryUrl,
                                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                                          options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants]) else {
      return []
    }
    let removedCloudMetadataItems = CloudContents(removedItems.compactMap { url in
      do {
        var item = try CloudMetadataItem(fileUrl: url)
        item.isRemoved = true
        return item
      } catch {
        delegate?.didReceiveCloudMonitorError(error)
        return nil
      }
    })
    return removedCloudMetadataItems
  }
}
